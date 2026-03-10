import time
import threading
from unittest.mock import MagicMock, patch
from pynput import keyboard
from dictation.hotkey import HoldToRecord


class TestHoldToRecord:
    def test_cmd_hold_triggers_start(self):
        on_start = MagicMock()
        on_stop = MagicMock()
        on_prepare = MagicMock()
        htr = HoldToRecord(on_start, on_stop, on_prepare=on_prepare)

        # Simulate Cmd press
        htr._on_press(keyboard.Key.cmd)
        # Wait for hold delay
        time.sleep(0.3)
        assert on_prepare.called
        assert on_start.called

    def test_cmd_quick_release_no_trigger(self):
        on_start = MagicMock()
        on_stop = MagicMock()
        on_prepare = MagicMock()
        on_cancel = MagicMock()
        htr = HoldToRecord(on_start, on_stop, on_prepare=on_prepare, on_cancel=on_cancel)

        # Simulate quick Cmd press + release (faster than HOLD_DELAY)
        htr._on_press(keyboard.Key.cmd)
        time.sleep(0.05)
        htr._on_release(keyboard.Key.cmd)
        time.sleep(0.2)
        assert not on_start.called
        assert not on_prepare.called
        assert not on_cancel.called

    def test_cmd_plus_other_key_cancels(self):
        on_start = MagicMock()
        on_stop = MagicMock()
        on_prepare = MagicMock()
        on_cancel = MagicMock()
        htr = HoldToRecord(on_start, on_stop, on_prepare=on_prepare, on_cancel=on_cancel)

        # Simulate Cmd+C (shortcut — should NOT trigger recording)
        htr._on_press(keyboard.Key.cmd)
        time.sleep(0.18)
        htr._on_press(keyboard.KeyCode.from_char("c"))
        time.sleep(0.2)
        assert not on_start.called
        assert on_prepare.called
        assert on_cancel.called

    def test_release_triggers_stop(self):
        on_start = MagicMock()
        on_stop = MagicMock()
        htr = HoldToRecord(on_start, on_stop)

        htr._on_press(keyboard.Key.cmd)
        time.sleep(0.3)  # wait for hold delay
        assert on_start.called
        # Now release
        htr._on_release(keyboard.Key.cmd)
        time.sleep(0.1)
        assert on_stop.called

    def test_release_after_prepare_before_start_cancels(self):
        on_start = MagicMock()
        on_stop = MagicMock()
        on_prepare = MagicMock()
        on_cancel = MagicMock()
        htr = HoldToRecord(on_start, on_stop, on_prepare=on_prepare, on_cancel=on_cancel)

        htr._on_press(keyboard.Key.cmd)
        time.sleep(0.18)
        htr._on_release(keyboard.Key.cmd)
        time.sleep(0.12)
        assert on_prepare.called
        assert on_cancel.called
        assert not on_start.called
        assert not on_stop.called

    def test_is_active_reflects_state(self):
        htr = HoldToRecord(lambda: None, lambda: None)
        assert htr.is_active is False

        htr._on_press(keyboard.Key.cmd)
        time.sleep(0.3)
        assert htr.is_active is True

        htr._on_release(keyboard.Key.cmd)
        time.sleep(0.1)
        assert htr.is_active is False
