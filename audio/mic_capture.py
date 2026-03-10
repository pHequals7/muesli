import threading
import numpy as np
import sounddevice as sd


class MicCapture:
    """Captures audio from the microphone on demand for dictation or meetings."""

    SAMPLE_RATE = 16000
    CHANNELS = 1
    DTYPE = "float32"
    BLOCK_SIZE = 1024

    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._recording = False
        self._stream = None

    def _open_stream(self):
        if self._stream is not None:
            return
        self._stream = sd.InputStream(
            samplerate=self.SAMPLE_RATE,
            channels=self.CHANNELS,
            dtype=self.DTYPE,
            blocksize=self.BLOCK_SIZE,
            callback=self._callback,
        )
        self._stream.start()

    def _close_stream(self):
        if self._stream is None:
            return
        self._stream.stop()
        self._stream.close()
        self._stream = None

    def _callback(self, indata, frames, time_info, status):
        if status:
            print(f"[mic] {status}")
        with self._lock:
            if self._recording:
                self._chunks.append(indata.copy())

    def prepare(self):
        with self._lock:
            self._open_stream()

    def start(self):
        with self._lock:
            self._open_stream()
            self._chunks.clear()
            self._recording = True

    def stop(self) -> np.ndarray:
        with self._lock:
            self._recording = False
            if not self._chunks:
                self._close_stream()
                return np.array([], dtype=np.float32)
            audio = np.concatenate(self._chunks, axis=0).flatten()
            self._chunks.clear()
            self._close_stream()
            return audio

    def cancel(self):
        with self._lock:
            self._recording = False
            self._chunks.clear()
            self._close_stream()

    @property
    def is_recording(self) -> bool:
        return self._recording

    @property
    def is_prepared(self) -> bool:
        return self._stream is not None
