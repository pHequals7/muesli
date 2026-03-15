# Context Handover — About Page and Settings UI Redesign

**Session Date:** 2026-03-15
**Repository:** muesli
**Branch:** `main`

---

## Task

1. **Add About page** as a sidebar tab with: version display, "Donate" button (https://buymeacoffee.com/phequals7), "View on GitHub" button (https://github.com/pHequals7/muesli), app data directory path with "Open" button, acknowledgements section (MLX, mlx-whisper by Apple).

2. **Redesign Settings page** for consistent design language — uniform button styles, aligned dropdowns, proper geometric proportions matching MuesliTheme.

## Reference Design

Handy's About page (screenshots in conversation) shows the pattern:
- Section headers (ABOUT, ACKNOWLEDGEMENTS) in uppercase secondary text
- Each row: label on left, action/value on right, inside a card
- "Donate" button: accent-colored, prominent
- "View on GitHub": outlined button style
- App Data / Log Directory: monospace path text + "Open" button
- Version: right-aligned `v0.2.0` text

## Implementation

### 1. Add `.about` to DashboardTab

**File:** `AppState.swift` — add `case about` to enum

### 2. Add About row to SidebarView

**File:** `SidebarView.swift` — add `info.circle` icon, "About" label, at the very bottom (below Settings)

### 3. Route in DashboardRootView

**File:** `DashboardRootView.swift` — add `case .about: AboutView(controller: controller)`

### 4. Create AboutView.swift

**File:** `native/MuesliNative/Sources/MuesliNativeApp/AboutView.swift`

```
About

ABOUT
┌──────────────────────────────────────────────────┐
│ Version                                  v0.2.0  │
├──────────────────────────────────────────────────┤
│ Support Development              [Donate]        │
├──────────────────────────────────────────────────┤
│ Source Code                  [View on GitHub]    │
├──────────────────────────────────────────────────┤
│ App Data Directory                               │
│ ~/Library/Application Support/Muesli    [Open]   │
├──────────────────────────────────────────────────┤
│ Database                                         │
│ ~/Library/Application Support/Muesli/m… [Open]   │
└──────────────────────────────────────────────────┘

ACKNOWLEDGEMENTS
┌──────────────────────────────────────────────────┐
│ MLX by Apple                                     │
│ On-device ML framework for Apple Silicon         │
├──────────────────────────────────────────────────┤
│ mlx-whisper by Apple                             │
│ Speech-to-text engine powering transcription     │
└──────────────────────────────────────────────────┘
```

- "Donate" button: use recording color (red/pink) background, opens URL
- "View on GitHub": outlined button, opens URL
- "Open" buttons: open Finder to the directory
- Version: read from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
- Use `NSWorkspace.shared.open(url)` for URLs, `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:)` for directories

### 5. Settings UI consistency pass

**File:** `SettingsView.swift`

- Ensure all toggles, pickers, text fields have consistent padding/sizing
- SecureField (API key) and model picker should be same width (240px — already set)
- Section cards should all use same corner radius and border
- Consider grouping: General, Transcription, Meetings (with API key/model nested), Data

## URLs

- Donate: `https://buymeacoffee.com/phequals7`
- GitHub: `https://github.com/pHequals7/muesli`
- App data: `~/Library/Application Support/Muesli/`
- Database: `~/Library/Application Support/Muesli/muesli.db`

## Files

| File | Action |
|---|---|
| `AboutView.swift` | **Create** |
| `AppState.swift` | Modify — add `.about` case |
| `SidebarView.swift` | Modify — add About row |
| `DashboardRootView.swift` | Modify — route `.about` |
| `SettingsView.swift` | Modify — consistency pass |
