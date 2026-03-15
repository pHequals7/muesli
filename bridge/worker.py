#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from transcribe.backends import (
    DEFAULT_QWEN_MODEL,
    DEFAULT_WHISPER_MODEL,
    create_backend,
)


class WorkerError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class SpeechWorker:
    def __init__(self):
        self._backend = None
        self._backend_name = None
        self._backend_model = None

    def _resolve_backend(self, backend: str | None, model: str | None) -> tuple[str, str]:
        backend_name = backend or "whisper"
        if backend_name == "whisper":
            return backend_name, model or DEFAULT_WHISPER_MODEL
        if backend_name == "qwen":
            return backend_name, model or DEFAULT_QWEN_MODEL
        raise WorkerError("UNSUPPORTED_BACKEND", f"Unsupported backend: {backend_name}")

    def _ensure_loaded(self, backend: str | None, model: str | None):
        backend_name, model_repo = self._resolve_backend(backend, model)
        if (
            self._backend is None
            or self._backend_name != backend_name
            or self._backend_model != model_repo
        ):
            print(f"[worker] loading {backend_name} {model_repo}", file=sys.stderr, flush=True)
            self._backend = create_backend(backend_name, model_repo)
            self._backend.load()
            self._backend_name = backend_name
            self._backend_model = model_repo
            print("[worker] backend ready", file=sys.stderr, flush=True)

    def _load_audio(self, wav_path: str) -> np.ndarray:
        path = Path(wav_path).expanduser()
        if not path.exists():
            raise WorkerError("FILE_NOT_FOUND", f"WAV path does not exist: {path}")

        with wave.open(str(path), "rb") as wav_file:
            channels = wav_file.getnchannels()
            sample_rate = wav_file.getframerate()
            sample_width = wav_file.getsampwidth()
            frames = wav_file.readframes(wav_file.getnframes())

        if sample_rate != 16000:
            raise WorkerError("UNSUPPORTED_SAMPLE_RATE", f"Expected 16kHz WAV, got {sample_rate}Hz")
        if sample_width != 2:
            raise WorkerError("UNSUPPORTED_SAMPLE_WIDTH", f"Expected 16-bit WAV, got {sample_width * 8}-bit")

        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32767.0
        if channels > 1:
            audio = audio.reshape(-1, channels).mean(axis=1)
        return audio

    def ping(self, _params: dict) -> dict:
        return {"status": "ok"}

    def preload_backend(self, params: dict) -> dict:
        self._ensure_loaded(params.get("backend"), params.get("model"))
        return {
            "backend": self._backend_name,
            "model": self._backend_model,
        }

    def _apply_custom_words(self, text: str, custom_words: list[dict]) -> str:
        if not custom_words or not text:
            return text

        try:
            from jellyfish import metaphone, jaro_winkler_similarity
        except ImportError:
            return text

        words = text.split()
        result = []

        for word in words:
            # Strip trailing punctuation for matching
            stripped = word.rstrip(".,!?;:")
            trailing = word[len(stripped):]
            word_lower = stripped.lower()

            best_match = None
            best_score = 0.0

            for entry in custom_words:
                target = entry.get("word", "")
                replacement = entry.get("replacement") or target
                target_lower = target.lower()

                # Exact match (case-insensitive)
                if word_lower == target_lower:
                    best_match = replacement
                    break

                # Stage 1: Phonetic pre-filter
                try:
                    if metaphone(word_lower) == metaphone(target_lower):
                        best_match = replacement
                        break
                except Exception:
                    pass

                # Stage 2: Jaro-Winkler similarity
                try:
                    score = jaro_winkler_similarity(word_lower, target_lower)
                    if score > 0.85 and score > best_score:
                        best_score = score
                        best_match = replacement
                except Exception:
                    pass

            if best_match:
                result.append(best_match + trailing)
            else:
                result.append(word)

        return " ".join(result)

    def transcribe_file(self, params: dict) -> dict:
        wav_path = params.get("wav_path")
        if not wav_path:
            raise WorkerError("INVALID_PARAMS", "wav_path is required")
        self._ensure_loaded(params.get("backend"), params.get("model"))
        audio = self._load_audio(wav_path)
        text = self._backend.transcribe(audio).strip()
        custom_words = params.get("custom_words", [])
        text = self._apply_custom_words(text, custom_words)
        return {
            "text": text,
            "backend": self._backend_name,
            "model": self._backend_model,
        }

    def transcribe_meeting_chunk(self, params: dict) -> dict:
        """Transcribe a meeting audio chunk with silence detection.

        Skips transcription if the chunk is mostly silence (prevents
        Whisper hallucinations on quiet segments). Uses RMS energy threshold.
        """
        wav_path = params.get("wav_path")
        if not wav_path:
            raise WorkerError("INVALID_PARAMS", "wav_path is required")
        self._ensure_loaded(params.get("backend"), params.get("model"))
        audio = self._load_audio(wav_path)

        # Energy-based silence detection: skip if RMS below threshold
        rms = float(np.sqrt(np.mean(audio ** 2)))
        silence_threshold = 0.005  # ~-46 dB, tuned for typical mic noise floor
        if rms < silence_threshold:
            print(f"[worker] chunk silent (rms={rms:.6f}), skipping", file=sys.stderr, flush=True)
            return {
                "text": "",
                "is_silent": True,
                "backend": self._backend_name,
                "model": self._backend_model,
            }

        text = self._backend.transcribe(audio).strip()
        custom_words = params.get("custom_words", [])
        text = self._apply_custom_words(text, custom_words)
        return {
            "text": text,
            "is_silent": False,
            "backend": self._backend_name,
            "model": self._backend_model,
        }

    def download_model(self, params: dict) -> dict:
        """Download model with file-level progress reporting."""
        backend_name, model_repo = self._resolve_backend(params.get("backend"), params.get("model"))
        request_id = params.get("_request_id")

        try:
            from huggingface_hub import hf_hub_download, model_info, try_to_load_from_cache
        except ImportError:
            # No huggingface_hub, fall back to regular load (will download without progress)
            self._ensure_loaded(params.get("backend"), params.get("model"))
            return {"backend": self._backend_name, "model": self._backend_model, "already_cached": True}

        try:
            info = model_info(model_repo)
        except Exception:
            # Offline or API error, fall back to regular load
            self._ensure_loaded(params.get("backend"), params.get("model"))
            return {"backend": self._backend_name, "model": self._backend_model, "already_cached": True}

        files = [f for f in info.siblings if f.size and f.size > 0]
        total_size = sum(f.size for f in files)

        # Check if fully cached
        all_cached = all(
            try_to_load_from_cache(model_repo, f.rfilename) is not None
            for f in files
        )
        if all_cached:
            self._ensure_loaded(params.get("backend"), params.get("model"))
            return {"backend": self._backend_name, "model": self._backend_model, "already_cached": True}

        # Download files one by one with progress
        downloaded_size = 0
        for f in files:
            cached = try_to_load_from_cache(model_repo, f.rfilename)
            if cached is not None:
                downloaded_size += f.size
                continue

            if request_id and total_size > 0:
                _write_progress(request_id, downloaded_size / total_size, f.rfilename)

            hf_hub_download(model_repo, f.rfilename)
            downloaded_size += f.size

            if request_id and total_size > 0:
                _write_progress(request_id, downloaded_size / total_size)

        # Load the backend after download
        if request_id:
            _write_progress(request_id, 1.0, "Loading model...")

        self._ensure_loaded(params.get("backend"), params.get("model"))
        return {"backend": self._backend_name, "model": self._backend_model, "already_cached": False}

    def shutdown(self, _params: dict) -> dict:
        self._backend = None
        self._backend_name = None
        self._backend_model = None
        return {"status": "shutting_down"}


def _write_response(payload: dict):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _write_progress(request_id: str, fraction: float, status: str | None = None):
    msg: dict = {"id": request_id, "progress": fraction}
    if status:
        msg["status"] = status
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def _handle_message(worker: SpeechWorker, message: dict) -> tuple[dict, bool]:
    request_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}

    if not request_id:
        raise WorkerError("INVALID_REQUEST", "id is required")
    if not method:
        raise WorkerError("INVALID_REQUEST", "method is required")

    if not hasattr(worker, method):
        raise WorkerError("UNKNOWN_METHOD", f"Unknown method: {method}")

    # Inject request ID so methods can send progress updates
    params["_request_id"] = request_id

    handler = getattr(worker, method)
    result = handler(params)
    should_exit = method == "shutdown"
    return {
        "id": request_id,
        "ok": True,
        "result": result,
    }, should_exit


def main():
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    worker = SpeechWorker()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
            response, should_exit = _handle_message(worker, message)
            _write_response(response)
            if should_exit:
                return
        except WorkerError as exc:
            _write_response(
                {
                    "id": message.get("id") if isinstance(locals().get("message"), dict) else None,
                    "ok": False,
                    "error": {
                        "code": exc.code,
                        "message": exc.message,
                    },
                }
            )
        except Exception as exc:  # pragma: no cover - defensive wrapper
            _write_response(
                {
                    "id": message.get("id") if isinstance(locals().get("message"), dict) else None,
                    "ok": False,
                    "error": {
                        "code": "INTERNAL_ERROR",
                        "message": str(exc),
                    },
                }
            )


if __name__ == "__main__":
    main()
