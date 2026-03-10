import threading
from pynput import keyboard


class HoldToRecord:
    """Hold left Cmd to record. If another key is pressed while Cmd is held,
    it's treated as a shortcut (Cmd+C etc.) and recording is not triggered."""

    PREPARE_DELAY = 0.15
    HOLD_DELAY = 0.25

    def __init__(self, on_start, on_stop, on_prepare=None, on_cancel=None):
        self._on_start = on_start
        self._on_stop = on_stop
        self._on_prepare = on_prepare
        self._on_cancel = on_cancel
        self._cmd_held = False
        self._other_key_pressed = False
        self._prepared = False
        self._active = False
        self._prepare_timer: threading.Timer | None = None
        self._start_timer: threading.Timer | None = None
        self._listener: keyboard.Listener | None = None

    def _on_press(self, key):
        if key == keyboard.Key.cmd or key == keyboard.Key.cmd_l:
            if not self._cmd_held:
                self._cmd_held = True
                self._other_key_pressed = False
                self._prepared = False
                self._prepare_timer = threading.Timer(self.PREPARE_DELAY, self._maybe_prepare)
                self._prepare_timer.daemon = True
                self._prepare_timer.start()
                self._start_timer = threading.Timer(self.HOLD_DELAY, self._maybe_start)
                self._start_timer.daemon = True
                self._start_timer.start()
        elif self._cmd_held:
            # Another key pressed while Cmd held → it's a shortcut, cancel
            self._other_key_pressed = True
            self._cancel_timers()
            if self._prepared and not self._active and self._on_cancel:
                threading.Thread(target=self._on_cancel, daemon=True).start()
            self._prepared = False
            # If already recording (rare edge case), stop it
            if self._active:
                self._active = False
                threading.Thread(target=self._on_stop, daemon=True).start()

    def _maybe_prepare(self):
        if self._cmd_held and not self._other_key_pressed and not self._prepared:
            self._prepared = True
            if self._on_prepare:
                threading.Thread(target=self._on_prepare, daemon=True).start()

    def _maybe_start(self):
        if self._cmd_held and not self._other_key_pressed and not self._active:
            self._active = True
            threading.Thread(target=self._on_start, daemon=True).start()

    def _cancel_timers(self):
        if self._prepare_timer:
            self._prepare_timer.cancel()
            self._prepare_timer = None
        if self._start_timer:
            self._start_timer.cancel()
            self._start_timer = None

    def _on_release(self, key):
        if key == keyboard.Key.cmd or key == keyboard.Key.cmd_l:
            self._cmd_held = False
            self._cancel_timers()
            if self._active:
                self._active = False
                threading.Thread(target=self._on_stop, daemon=True).start()
            elif self._prepared and self._on_cancel:
                threading.Thread(target=self._on_cancel, daemon=True).start()
            self._prepared = False

    def start(self):
        self._listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._listener.daemon = True
        self._listener.start()

    def stop(self):
        if self._listener:
            self._listener.stop()
            self._listener = None

    @property
    def is_active(self) -> bool:
        return self._active

    @property
    def is_prepared(self) -> bool:
        return self._prepared
