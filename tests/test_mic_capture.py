import time
import numpy as np
import pytest
from unittest.mock import patch, MagicMock
from audio.mic_capture import MicCapture


class TestMicCapture:
    def test_init_does_not_start_stream(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mic = MicCapture()
            assert mic.is_prepared is False
            mock_sd.InputStream.assert_not_called()

    def test_prepare_opens_stream(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_stream = MagicMock()
            mock_sd.InputStream.return_value = mock_stream
            mic = MicCapture()
            mic.prepare()
            mock_sd.InputStream.assert_called_once()
            mock_stream.start.assert_called_once()
            assert mic.is_prepared is True

    def test_start_clears_chunks_and_sets_recording(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_sd.InputStream.return_value = MagicMock()
            mic = MicCapture()
            mic.start()
            assert mic.is_recording is True

    def test_stop_returns_empty_when_no_audio(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_stream = MagicMock()
            mock_sd.InputStream.return_value = mock_stream
            mic = MicCapture()
            mic.start()
            audio = mic.stop()
            assert isinstance(audio, np.ndarray)
            assert audio.size == 0
            assert mic.is_recording is False
            assert mic.is_prepared is False
            mock_stream.stop.assert_called_once()
            mock_stream.close.assert_called_once()

    def test_callback_stores_chunks_when_recording(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_sd.InputStream.return_value = MagicMock()
            mic = MicCapture()
            mic.start()
            # Simulate audio callback
            fake_audio = np.random.randn(1024, 1).astype(np.float32)
            mic._callback(fake_audio, 1024, None, None)
            mic._callback(fake_audio, 1024, None, None)
            audio = mic.stop()
            assert audio.size == 2048

    def test_callback_ignores_when_not_recording(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_sd.InputStream.return_value = MagicMock()
            mic = MicCapture()
            # Not recording — callback should discard
            fake_audio = np.random.randn(1024, 1).astype(np.float32)
            mic._callback(fake_audio, 1024, None, None)
            mic.start()
            audio = mic.stop()
            assert audio.size == 0

    def test_stop_flattens_to_1d(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_sd.InputStream.return_value = MagicMock()
            mic = MicCapture()
            mic.start()
            fake_audio = np.ones((512, 1), dtype=np.float32)
            mic._callback(fake_audio, 512, None, None)
            audio = mic.stop()
            assert audio.ndim == 1
            assert audio.shape == (512,)

    def test_cancel_closes_prepared_stream(self):
        with patch("audio.mic_capture.sd") as mock_sd:
            mock_stream = MagicMock()
            mock_sd.InputStream.return_value = mock_stream
            mic = MicCapture()
            mic.prepare()
            mic.cancel()
            assert mic.is_prepared is False
            assert mic.is_recording is False
            mock_stream.stop.assert_called_once()
            mock_stream.close.assert_called_once()
