import AppKit
import QuartzCore
import Foundation
import MuesliCore

@MainActor
private final class HoverIndicatorView: NSView {
    weak var owner: FloatingIndicatorController?
    private var trackingAreaRef: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.scheduleHoverExit()
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        owner?.collapseForDrag()
        // Recalculate drag origin after collapse (frame changed)
        dragOrigin = NSPoint(x: (window?.frame.width ?? 0) / 2, y: (window?.frame.height ?? 0) / 2)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        didDrag = true
        let current = event.locationInWindow
        let frame = window.frame
        let newOrigin = NSPoint(
            x: frame.origin.x + (current.x - (dragOrigin?.x ?? current.x)),
            y: frame.origin.y + (current.y - (dragOrigin?.y ?? current.y))
        )
        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            owner?.isDragging = false
            owner?.savePosition()
        } else if event.modifierFlags.contains(.option) {
            owner?.handleOptionClick()
        } else {
            let clickX = convert(event.locationInWindow, from: nil).x
            owner?.handleClick(atX: clickX)
        }
        dragOrigin = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.handleOptionClick()
    }
}

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private var contentView: HoverIndicatorView?
    private var iconLabel: NSTextField?
    private var textLabel: NSTextField?
    private var state: DictationState = .idle
    private var isHovered = false
    private var hoverExitWorkItem: DispatchWorkItem?
    private let configStore: ConfigStore
    private var barLayers: [CALayer] = []
    private var amplitudeTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    private var isMeetingRecording = false
    fileprivate var isDragging = false
    var powerProvider: (() -> Float)?
    var onStopMeeting: (() -> Void)?
    var onDiscardMeeting: (() -> Void)?
    var onCancelToggleDictation: (() -> Void)?
    var isToggleDictation = false
    private var stopLayer: CALayer?
    private var transcribingTitle = "Transcribing"
    var hotkeyLabel: String = "Left Cmd"

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    var onStopToggleDictation: (() -> Void)?

    func handleClick(atX x: CGFloat? = nil) {
        if state == .recording, let x {
            if x < 30 {
                if isMeetingRecording {
                    onDiscardMeeting?()
                } else {
                    onCancelToggleDictation?()
                }
            } else {
                if isMeetingRecording {
                    onStopMeeting?()
                } else {
                    onStopToggleDictation?()
                }
            }
        } else if state == .recording {
            if isMeetingRecording {
                onStopMeeting?()
            } else {
                onStopToggleDictation?()
            }
        }
    }

    func handleOptionClick() {
        if !isMeetingRecording, state == .recording {
            onCancelToggleDictation?()
        }
    }

    func collapseForDrag() {
        isDragging = true
        hoverExitWorkItem?.cancel()
        guard state == .idle, let panel, let contentView, let iconLabel, let textLabel else { return }
        isHovered = false

        let config = configStore.load()
        let style = styleForState(.idle)
        let targetFrame = frameForState(.idle, config: config)

        // Instant resize — no animation
        panel.setFrame(targetFrame, display: true)
        contentView.frame = NSRect(origin: .zero, size: targetFrame.size)
        contentView.layer?.cornerRadius = targetFrame.height / 2
        contentView.layer?.backgroundColor = style.background.cgColor
        contentView.layer?.borderColor = style.border.cgColor
        panel.alphaValue = style.alpha

        iconLabel.stringValue = style.icon
        iconLabel.textColor = style.iconColor
        textLabel.isHidden = true
        textLabel.alphaValue = 0
        layoutLabels(iconLabel: iconLabel, textLabel: textLabel, in: targetFrame.size, hasTitle: false, animated: false)
    }

    func savePosition() {
        guard let frame = panel?.frame else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var config = configStore.load()
        config.indicatorOrigin = CGPointCodable(x: center.x, y: center.y)
        configStore.save(config)
    }

    func setToggleDictation(_ active: Bool, config: AppConfig) {
        isToggleDictation = active
        if active {
            setState(.recording, config: config)
        } else {
            removeStopLayer()
            setState(.idle, config: config)
        }
    }

    func setMeetingRecording(_ recording: Bool, config: AppConfig) {
        isMeetingRecording = recording
        if recording {
            setState(.recording, config: config)
        } else {
            setState(.idle, config: config)
        }
    }

    func setTranscribingTitle(_ title: String, config: AppConfig) {
        transcribingTitle = title
        guard state == .transcribing else { return }
        setState(.transcribing, config: config)
    }

    func setState(_ state: DictationState, config: AppConfig) {
        let previousState = self.state
        let previousHover = isHovered
        self.state = state
        if state != .transcribing {
            transcribingTitle = "Transcribing"
        }
        if state != .idle {
            isHovered = false
        }
        if !config.showFloatingIndicator && state == .idle {
            close()
            return
        }
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        if previousState == .recording && state != .recording {
            stopWaveformAnimation()
        }

        let style = styleForState(state)
        let targetFrame = frameForState(state, config: config)

        let duration = transitionDuration(
            from: previousState,
            to: state,
            wasHovered: previousHover,
            isHovered: isHovered
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = style.alpha

            contentView.animator().frame = NSRect(origin: .zero, size: targetFrame.size)
            contentView.layer?.cornerRadius = targetFrame.height / 2
            contentView.layer?.backgroundColor = style.background.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = style.border.cgColor

            if state == .recording {
                // All recordings: X on left, waveform in middle, stop on right.
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.stringValue = "\u{2715}"  // ✕
                iconLabel.textColor = .white.withAlphaComponent(0.45)
                iconLabel.font = NSFont.systemFont(ofSize: 7, weight: .semibold)
                let xSize: CGFloat = 10
                iconLabel.frame = NSRect(
                    x: 7,
                    y: floor((targetFrame.height - xSize) / 2) - 1,
                    width: xSize,
                    height: xSize
                )

                textLabel.animator().alphaValue = 0
                textLabel.isHidden = true
            } else {
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
                iconLabel.stringValue = style.icon
                iconLabel.textColor = style.iconColor
                textLabel.stringValue = style.title
                textLabel.textColor = style.textColor
                textLabel.animator().alphaValue = style.title.isEmpty ? 0 : 1
                textLabel.isHidden = style.title.isEmpty
                layoutLabels(
                    iconLabel: iconLabel,
                    textLabel: textLabel,
                    in: targetFrame.size,
                    hasTitle: !style.title.isEmpty,
                    animated: true
                )
            }
        }

        if state == .recording {
            startWaveformAnimation(in: targetFrame.size, xOffset: 24, rightPadding: 24)
            addStopLayer(in: targetFrame.size)
        }

        panel.orderFrontRegardless()
    }

    func ensureVisible(config: AppConfig) {
        setState(state, config: config)
    }

    /// Flash a brief warning message on the indicator pill, then snap back to idle.
    func showWarning(_ message: String, icon: String = "⚡", duration: TimeInterval = 2.5) {
        guard state == .idle else { return }
        let config = configStore.load()
        if panel == nil { createPanel(config: config) }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        let warningSize = NSSize(width: 260, height: 36)
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let x = min(max(center.x - warningSize.width / 2, screen.minX), screen.maxX - warningSize.width)
        let y = min(max(center.y - warningSize.height / 2, screen.minY), screen.maxY - warningSize.height)
        let targetFrame = NSRect(x: x, y: y, width: warningSize.width, height: warningSize.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
            contentView.animator().frame = NSRect(origin: .zero, size: warningSize)
            contentView.layer?.cornerRadius = warningSize.height / 2
            contentView.layer?.backgroundColor = NSColor.colorWith(hex: 0xD99A11, alpha: 0.92).cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.24).cgColor

            iconLabel.isHidden = false
            iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            iconLabel.stringValue = icon
            iconLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            iconLabel.animator().alphaValue = 1

            textLabel.stringValue = message
            textLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            textLabel.isHidden = false
            textLabel.animator().alphaValue = 1
            layoutLabels(iconLabel: iconLabel, textLabel: textLabel, in: warningSize, hasTitle: true, animated: true)
        }
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.setState(.idle, config: self.configStore.load())
        }
    }

    func setHovered(_ hovered: Bool) {
        guard state == .idle, !isDragging, isHovered != hovered else { return }
        hoverExitWorkItem?.cancel()
        isHovered = hovered
        let config = configStore.load()
        setState(.idle, config: config)
    }

    func scheduleHoverExit() {
        guard state == .idle, isHovered else { return }
        hoverExitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pointerIsInsidePanel() else { return }
            self.setHovered(false)
        }
        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func closeIfIdle() {
        if state == .idle { close() }
    }

    func close() {
        stopWaveformAnimation()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        panel?.close()
        panel = nil
        contentView = nil
        iconLabel = nil
        textLabel = nil
    }

    // MARK: - Stop Layer (toggle dictation)

    private func addStopLayer(in size: NSSize) {
        removeStopLayer()
        guard let contentView else { return }

        let sq: CGFloat = 6
        let stop = CALayer()
        stop.frame = CGRect(
            x: size.width - sq - 8,
            y: floor((size.height - sq) / 2),
            width: sq,
            height: sq
        )
        stop.cornerRadius = 1
        stop.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor

        contentView.layer?.addSublayer(stop)
        stopLayer = stop
    }

    private func removeStopLayer() {
        stopLayer?.removeFromSuperlayer()
        stopLayer = nil
    }

    // MARK: - Waveform Animation

    private static let barCount = 5
    private static let barWidth: CGFloat = 3.0
    private static let barSpacing: CGFloat = 4.0
    private static let barMinHeight: CGFloat = 5.0
    private static let barMaxHeight: CGFloat = 26.0
    private static let barMultipliers5: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]
    private func startWaveformAnimation(in size: NSSize, xOffset: CGFloat = 0, rightPadding: CGFloat = 0, barCount: Int? = nil) {
        let savedProvider = powerProvider
        stopWaveformAnimation()
        powerProvider = savedProvider
        guard let contentView else { return }

        let count = barCount ?? Self.barCount
        let multipliers = Self.barMultipliers5
        let totalWidth = CGFloat(count) * Self.barWidth + CGFloat(count - 1) * Self.barSpacing
        let availableWidth = size.width - xOffset - rightPadding
        let startX = xOffset + (availableWidth - totalWidth) / 2

        for i in 0..<count {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (Self.barWidth + Self.barSpacing)
            let height = Self.barMinHeight * multipliers[i]
            bar.frame = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: size.height / 2)

            contentView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        smoothedAmplitude = 0
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBarAmplitudes()
            }
        }
    }

    private func stopWaveformAnimation() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        for bar in barLayers {
            bar.removeAllAnimations()
            bar.removeFromSuperlayer()
        }
        barLayers.removeAll()
        smoothedAmplitude = 0
        powerProvider = nil
        removeStopLayer()
    }

    private func updateBarAmplitudes() {
        let dB = CGFloat(powerProvider?() ?? -160)
        let normalized = max(0, min(1, (dB + 50) / 42))
        smoothedAmplitude = smoothedAmplitude * 0.35 + normalized * 0.65

        let pillHeight = panel?.frame.height ?? 32
        let multipliers = Self.barMultipliers5
        for (i, bar) in barLayers.enumerated() {
            let multiplier = multipliers[i]
            let baseline = Self.barMinHeight + (1 - multiplier) * 2
            let height = baseline + smoothedAmplitude * (Self.barMaxHeight - baseline) * multiplier
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(x: bar.position.x, y: pillHeight / 2)
            CATransaction.commit()
        }
    }

    private func createPanel(config: AppConfig) {
        let panel = NSPanel(
            contentRect: frameForState(.idle, config: config),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let contentView = HoverIndicatorView(frame: NSRect(origin: .zero, size: panel.frame.size))
        contentView.owner = self
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = panel.frame.height / 2
        contentView.layer?.masksToBounds = false

        let iconLabel = NSTextField(labelWithString: "")
        iconLabel.alignment = .center
        iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(iconLabel)

        let textLabel = NSTextField(labelWithString: "")
        textLabel.alignment = .left
        textLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        contentView.addSubview(textLabel)

        panel.contentView = contentView

        self.panel = panel
        self.contentView = contentView
        self.iconLabel = iconLabel
        self.textLabel = textLabel
    }

    private func frameForState(_ state: DictationState, config: AppConfig) -> NSRect {
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 64, height: 28)
        }
        let size: NSSize
        switch state {
        case .idle:
            size = isHovered ? NSSize(width: 220, height: 36) : NSSize(width: 44, height: 28)
        case .preparing: size = NSSize(width: 44, height: 28)
        case .recording: size = NSSize(width: 76, height: 22)
        case .transcribing: size = NSSize(width: 120, height: 32)
        }

        // Use the pill's current on-screen center if it exists, so state
        // transitions resize around the current position rather than jumping.
        // Saved config is only used for initial panel creation.
        let center: CGPoint
        if let currentFrame = panel?.frame, currentFrame.width > 0 {
            center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        } else if let saved = config.indicatorOrigin {
            center = CGPoint(x: saved.x, y: saved.y)
        } else {
            let defaultSize = NSSize(width: 44, height: 28)
            center = CGPoint(
                x: screen.maxX - defaultSize.width / 2 - 8,
                y: screen.minY + (screen.height * 0.56)
            )
        }

        let x = min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func styleForState(_ state: DictationState) -> (background: NSColor, border: NSColor, icon: String, title: String, iconColor: NSColor, textColor: NSColor, alpha: CGFloat) {
        switch state {
        case .idle:
            return (
                .colorWith(hex: 0x000000, alpha: isHovered ? 0.96 : 0.66),
                .colorWith(hex: 0xFFFFFF, alpha: 0.18),
                "🎤",
                isHovered ? "Hold \(hotkeyLabel) to dictate" : "",
                .colorWith(hex: 0xFFFFFF, alpha: 0.92),
                .colorWith(hex: 0xFFFFFF, alpha: 0.92),
                isHovered ? 1.0 : 0.82
            )
        case .preparing:
            return (
                .colorWith(hex: 0x3B4757, alpha: 0.94),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                "🎤",
                "",
                .white,
                .white,
                1.0
            )
        case .recording:
            return (
                .colorWith(hex: 0xD32F2F, alpha: 0.72),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                isMeetingRecording ? "⏹" : "🎤",
                isMeetingRecording ? "" : "Listening",
                .white,
                .white,
                1.0
            )
        case .transcribing:
            return (
                .colorWith(hex: 0xD99A11, alpha: 0.72),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                "✍️",
                transcribingTitle,
                .colorWith(hex: 0x1A140D, alpha: 0.95),
                .black,
                1.0
            )
        }
    }

    private func transitionDuration(from oldState: DictationState, to newState: DictationState, wasHovered: Bool, isHovered: Bool) -> TimeInterval {
        if oldState == .idle, newState == .idle, wasHovered != isHovered {
            return isHovered ? 0.24 : 0.2
        }
        if oldState == .idle || newState == .idle {
            return 0.18
        }
        return 0.16
    }

    private func layoutLabels(iconLabel: NSTextField, textLabel: NSTextField, in size: NSSize, hasTitle: Bool, animated: Bool) {
        if !hasTitle {
            let iconSize = iconLabel.attributedStringValue.size()
            let iconWidth = max(26, ceil(iconSize.width) + 4)
            let iconHeight = max(18, ceil(iconSize.height))
            let iconFrame = NSRect(
                x: (size.width - iconWidth) / 2,
                y: (size.height - iconHeight) / 2,
                width: iconWidth,
                height: iconHeight
            )
            if animated {
                iconLabel.animator().frame = iconFrame
                textLabel.animator().alphaValue = 0
                textLabel.animator().frame = .zero
            } else {
                iconLabel.frame = iconFrame
                textLabel.alphaValue = 0
                textLabel.frame = .zero
            }
            return
        }

        let iconSize = iconLabel.attributedStringValue.size()
        let textSize = textLabel.attributedStringValue.size()
        let gap: CGFloat = 4

        let iconWidth = max(24, ceil(iconSize.width) + 2)
        let iconHeight = max(18, ceil(iconSize.height))
        let textWidth = ceil(textSize.width) + 2
        let textHeight = max(16, ceil(textSize.height))

        let totalWidth = iconWidth + gap + textWidth
        let originX = max((size.width - totalWidth) / 2, 12)

        let iconFrame = NSRect(
            x: originX,
            y: (size.height - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        let textFrame = NSRect(
            x: originX + iconWidth + gap,
            y: (size.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        if animated {
            iconLabel.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            iconLabel.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    private func pointerIsInsidePanel() -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }
}

private extension NSColor {
    static func colorWith(hex: Int, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
