import threading
import rumps
from audio.mic_capture import MicCapture
from transcribe import engine
from dictation.hotkey import HoldToRecord
from dictation.paste import paste_text
from meeting.session import MeetingSession
from cal_monitor.monitor import CalendarMonitor
from storage.local_db import init_db, get_recent_meetings
from ui.floating_indicator import FloatingIndicator

MENU_TITLE_IDLE = "M"
MENU_TITLE_RECORDING = "M*"
MENU_TITLE_TRANSCRIBING = "M~"
MENU_TITLE_MEETING = "MM"


class MuesliApp(rumps.App):
    def __init__(self):
        super().__init__(
            "Muesli",
            title=MENU_TITLE_IDLE,
            quit_button=None,
        )
        # Dictation
        self.mic = MicCapture()
        self.hotkey = HoldToRecord(
            on_prepare=self._on_dictation_prepare,
            on_start=self._on_dictation_start,
            on_stop=self._on_dictation_stop,
            on_cancel=self._on_dictation_cancel,
        )
        self._transcribing = False
        self._indicator = FloatingIndicator()

        # Meeting
        self._meeting: MeetingSession | None = None
        self._calendar = CalendarMonitor(on_meeting_soon=self._on_meeting_soon)

        # Menu
        self.menu = [
            rumps.MenuItem("Dictation: Hold Left Cmd", callback=None),
            None,
            rumps.MenuItem("Start Meeting Recording", callback=self._toggle_meeting),
            None,
            rumps.MenuItem("Recent Meetings", callback=None),
            None,
            rumps.MenuItem("Status: Idle"),
            None,
            rumps.MenuItem("Quit", callback=self._on_quit),
        ]

        # Init DB
        init_db()

        # Pre-load whisper model in background
        threading.Thread(target=engine.preload, daemon=True).start()

    # ---------- Status ----------

    def _set_status(self, text: str, menu_title: str = MENU_TITLE_IDLE, overlay_state: str = "idle"):
        self.title = menu_title
        for item in self.menu.values():
            if hasattr(item, "title") and item.title.startswith("Status:"):
                item.title = f"Status: {text}"
        self._indicator.set_state(overlay_state)

    # ---------- Dictation ----------

    def _on_dictation_prepare(self):
        if self._meeting and self._meeting.is_recording:
            return
        self.mic.prepare()

    def _on_dictation_start(self):
        if self._meeting and self._meeting.is_recording:
            return  # don't dictate during meeting recording
        self.mic.start()
        self._set_status("Recording...", MENU_TITLE_RECORDING, "listening")
        print("[muesli] Dictation started")

    def _on_dictation_stop(self):
        if self._meeting and self._meeting.is_recording:
            return
        audio = self.mic.stop()
        duration = len(audio) / MicCapture.SAMPLE_RATE if len(audio) > 0 else 0
        print(f"[muesli] Dictation stopped ({duration:.1f}s)")

        if duration < 0.3:
            self._set_status("Idle")
            return

        self._set_status("Transcribing...", MENU_TITLE_TRANSCRIBING, "transcribing")
        self._transcribing = True

        def do_transcribe():
            try:
                text = engine.transcribe(audio)
                print(f"[muesli] Transcribed: {text}")
                if text:
                    paste_text(text)
            except Exception as e:
                print(f"[muesli] Transcription error: {e}")
            finally:
                self._transcribing = False
                self._set_status("Idle")

        threading.Thread(target=do_transcribe, daemon=True).start()

    def _on_dictation_cancel(self):
        if self._meeting and self._meeting.is_recording:
            return
        self.mic.cancel()

    # ---------- Meeting ----------

    def _toggle_meeting(self, sender):
        if self._meeting and self._meeting.is_recording:
            self._stop_meeting()
        else:
            self._start_meeting()

    def _start_meeting(self, title: str = "Meeting"):
        self._meeting = MeetingSession(title=title)
        self._meeting.start()
        self._set_status(f"Meeting: {title}", MENU_TITLE_MEETING, "meeting")
        # Update menu item text
        for item in self.menu.values():
            if hasattr(item, "title") and "Meeting Recording" in item.title:
                item.title = "Stop Meeting Recording"

    def _stop_meeting(self):
        if not self._meeting:
            return
        self._set_status("Processing meeting...", MENU_TITLE_TRANSCRIBING, "processing")

        def process():
            try:
                result = self._meeting.stop()
                print(f"[muesli] Meeting saved: #{result['id']}")
                self._update_recent_meetings()
            except Exception as e:
                print(f"[muesli] Meeting processing error: {e}")
            finally:
                self._meeting = None
                self._set_status("Idle")
                for item in self.menu.values():
                    if hasattr(item, "title") and "Meeting Recording" in item.title:
                        item.title = "Start Meeting Recording"

        threading.Thread(target=process, daemon=True).start()

    def _on_meeting_soon(self, event_info):
        """Called by CalendarMonitor when a meeting is about to start."""
        title = event_info["title"]
        print(f"[muesli] Meeting soon: {title}")
        # For now just log it — could add a notification or auto-start

    def _update_recent_meetings(self):
        """Update the Recent Meetings submenu."""
        try:
            meetings = get_recent_meetings(limit=5)
            recent_menu = self.menu.get("Recent Meetings")
            if recent_menu:
                recent_menu.clear()
                if not meetings:
                    recent_menu.add(rumps.MenuItem("No meetings yet"))
                else:
                    for m in meetings:
                        label = f"{m['start_time'][:10]} - {m['title']} ({m['duration_seconds']:.0f}s)"
                        recent_menu.add(rumps.MenuItem(label))
        except Exception as e:
            print(f"[muesli] Error updating recent meetings: {e}")

    # ---------- Lifecycle ----------

    def _on_quit(self, _):
        if self._meeting and self._meeting.is_recording:
            self._meeting.stop()
        self.hotkey.stop()
        self._calendar.stop()
        self._indicator.close()
        rumps.quit_application()

    def run(self, **kwargs):
        self.hotkey.start()
        self._calendar.start()
        self._update_recent_meetings()
        print("[muesli] Hotkey listener started (Hold Left Cmd)")
        print("[muesli] Calendar monitor started")
        print("[muesli] Hold to dictate, or use menu to start meeting recording")
        super().run(**kwargs)
