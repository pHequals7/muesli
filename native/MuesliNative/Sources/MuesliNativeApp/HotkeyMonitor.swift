import AppKit
import ApplicationServices
import Foundation
import MuesliCore

final class HotkeyMonitor {
    var onPrepare: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleStart: (() -> Void)?
    var onToggleStop: (() -> Void)?
    var targetKeyCode: UInt16 = 55
    var doubleTapEnabled: Bool = true

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var prepareWorkItem: DispatchWorkItem?
    private var startWorkItem: DispatchWorkItem?
    private var targetKeyDown = false
    private var otherKeyPressed = false
    private var prepared = false
    private var active = false

    // Double-tap detection
    private var lastTapUpTime: Date?
    private var lastTapWasShort = false
    private var toggleActive = false

    private let prepareDelay: TimeInterval
    private let startDelay: TimeInterval
    private let doubleTapWindow: TimeInterval

    init(
        prepareDelay: TimeInterval = 0.15,
        startDelay: TimeInterval = 0.25,
        doubleTapWindow: TimeInterval = 0.35
    ) {
        self.prepareDelay = prepareDelay
        self.startDelay = startDelay
        self.doubleTapWindow = doubleTapWindow
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let hasListenAccess = CGPreflightListenEventAccess()
        fputs("[hotkey] listen event access: \(hasListenAccess)\n", stderr)
        if !hasListenAccess {
            let requested = CGRequestListenEventAccess()
            fputs("[hotkey] requested listen event access: \(requested)\n", stderr)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }

        if globalMonitor != nil || localMonitor != nil {
            fputs("[hotkey] event monitors started\n", stderr)
        } else {
            fputs("[hotkey] failed to start event monitors\n", stderr)
        }
    }

    func stop() {
        cancelTimers()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        targetKeyDown = false
        otherKeyPressed = false
        prepared = false
        active = false
        toggleActive = false
    }

    func configure(keyCode: UInt16) {
        targetKeyCode = keyCode
        if isRunning {
            restart()
        }
    }

    func restart() {
        stop()
        start()
    }

    /// Call externally to stop toggle mode (e.g., from floating indicator click)
    func stopToggleMode() {
        if toggleActive {
            toggleActive = false
            fputs("[hotkey] toggle stopped externally\n", stderr)
            onToggleStop?()
        }
    }

    /// Cancel toggle mode without triggering onToggleStop (discard path)
    func cancelToggleMode() {
        if toggleActive {
            toggleActive = false
            fputs("[hotkey] toggle cancelled externally\n", stderr)
        }
    }

    var isRunning: Bool {
        globalMonitor != nil || localMonitor != nil
    }

    var isToggleRecording: Bool {
        toggleActive
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
        case .keyDown:
            handleKeyDown(keyCode: event.keyCode)
        default:
            break
        }
    }

    func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == targetKeyCode {
            let isDown = isModifierDown(keyCode: targetKeyCode, flags: flags)
            if isDown {
                if !targetKeyDown {
                    targetKeyDown = true
                    otherKeyPressed = false
                    prepared = false

                    // If in toggle mode, stop it on next key press
                    if toggleActive {
                        fputs("[hotkey] toggle stop via keypress\n", stderr)
                        toggleActive = false
                        cancelTimers()
                        onToggleStop?()
                        return
                    }

                    // Check for double-tap
                    if doubleTapEnabled,
                       lastTapWasShort,
                       let lastUp = lastTapUpTime,
                       Date().timeIntervalSince(lastUp) < doubleTapWindow {
                        // Double-tap detected!
                        fputs("[hotkey] double-tap → toggle start\n", stderr)
                        lastTapWasShort = false
                        lastTapUpTime = nil
                        toggleActive = true
                        cancelTimers()
                        onToggleStart?()
                        return
                    }

                    fputs("[hotkey] target key \(targetKeyCode) down\n", stderr)
                    scheduleTimers()
                }
            } else {
                fputs("[hotkey] target key \(targetKeyCode) up\n", stderr)
                let wasDown = targetKeyDown
                targetKeyDown = false
                cancelTimers()

                if toggleActive {
                    // Don't stop toggle on key-up — only on next key-down
                    return
                }

                // Track tap timing for double-tap detection
                if wasDown && !active && !prepared && !otherKeyPressed {
                    // This was a short tap (released before prepareDelay)
                    lastTapWasShort = true
                    lastTapUpTime = Date()
                } else {
                    lastTapWasShort = false
                }

                if active {
                    active = false
                    onStop?()
                } else if prepared {
                    prepared = false
                    onCancel?()
                }
            }
        } else if targetKeyDown && !toggleActive {
            fputs("[hotkey] canceled by other modifier key \(keyCode)\n", stderr)
            otherKeyPressed = true
            lastTapWasShort = false
            cancelTimers()
            if active {
                active = false
                onStop?()
            } else if prepared {
                prepared = false
                onCancel?()
            }
        }
    }

    private func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 55, 54: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63:     return flags.contains(.function)
        default:     return false
        }
    }

    func handleKeyDown(keyCode: UInt16) {
        // Escape cancels any active recording
        if keyCode == 53 {
            if toggleActive {
                fputs("[hotkey] escape → cancel toggle\n", stderr)
                toggleActive = false
                cancelTimers()
                onCancel?()
                return
            }
            if active {
                fputs("[hotkey] escape → cancel hold\n", stderr)
                active = false
                targetKeyDown = false
                cancelTimers()
                onCancel?()
            }
            return
        }

        if targetKeyDown && !toggleActive {
            if keyCode != targetKeyCode {
                fputs("[hotkey] canceled by other key\n", stderr)
                otherKeyPressed = true
                lastTapWasShort = false
                cancelTimers()
                if active {
                    active = false
                    onStop?()
                } else if prepared {
                    prepared = false
                    onCancel?()
                }
            }
        }
    }

    private func scheduleTimers() {
        let prepare = DispatchWorkItem { [weak self] in
            guard let self, self.targetKeyDown, !self.otherKeyPressed, !self.prepared else { return }
            self.prepared = true
            self.lastTapWasShort = false // Held long enough — not a tap
            fputs("[hotkey] prepared\n", stderr)
            self.onPrepare?()
        }
        let start = DispatchWorkItem { [weak self] in
            guard let self, self.targetKeyDown, !self.otherKeyPressed, !self.active else { return }
            self.active = true
            fputs("[hotkey] start\n", stderr)
            self.onStart?()
        }
        prepareWorkItem = prepare
        startWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + prepareDelay, execute: prepare)
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: start)
    }

    private func cancelTimers() {
        prepareWorkItem?.cancel()
        startWorkItem?.cancel()
        prepareWorkItem = nil
        startWorkItem = nil
    }

    func setHoldRecordingActiveForTests() {
        targetKeyDown = true
        active = true
    }
}
