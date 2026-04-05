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
    private var barAmplitudes: [CGFloat] = []
    private var animationTime: CGFloat = 0
    private var amplitudeTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    private var blobBaseSize: CGSize = .zero
    private var isMeetingRecording = false
    private var glassView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var micIconView: NSImageView?
    private var wandIconView: NSImageView?
    private var specularLayer: CAGradientLayer?
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
        applyGlassState(.idle, frameSize: targetFrame.size)
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

        // Immediately snap glass elements off when leaving idle so the SF Symbol
        // mic doesn't linger/fade during the recording/transcribing transition.
        if state != .idle {
            micIconView?.isHidden = true
            glassView?.isHidden = true
            tintLayer?.isHidden = true
            specularLayer?.isHidden = true
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

            // Apply glass state last so it can override iconLabel visibility set above.
            applyGlassState(state, frameSize: targetFrame.size)
        }

        // Manage SF Symbol effects — stop everything first, then start for the new state.
        micIconView?.removeAllSymbolEffects(animated: false)
        wandIconView?.removeAllSymbolEffects(animated: false)

        switch state {
        case .recording:
            micIconView?.addSymbolEffect(
                .variableColor.iterative.dimInactiveLayers.reversing,
                options: .repeating, animated: true
            )
            addStopLayer(in: targetFrame.size)
        case .transcribing:
            if #available(macOS 15, *) {
                wandIconView?.addSymbolEffect(
                    .wiggle.backward.byLayer,
                    options: .repeating, animated: true
                )
            }
        default:
            break
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

        // Warning uses its own solid amber background — hide glass layers.
        glassView?.isHidden = true
        tintLayer?.isHidden = true
        specularLayer?.isHidden = true
        micIconView?.isHidden = true

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
        glassView = nil
        tintLayer = nil
        micIconView = nil
        wandIconView = nil
        specularLayer = nil
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

    // MARK: - EQ Waveform Animation

    // 3-bar EQ geometry — all values in points.
    // Bottom pad + max height must leave ≥4pt top margin inside the pill.
    private static let eqBarCount = 3
    private static let eqBarWidth: CGFloat = 4
    private static let eqBarGap: CGFloat = 6
    private static let eqBarBottomPad: CGFloat = 5
    private static let eqBarMaxHeight: CGFloat = 22   // 5 + 22 = 27 → 7pt below 34pt pill top
    private static let eqBarMinHeight: CGFloat = 5
    // Middle bar slightly taller for classic EQ pyramid silhouette.
    private static let eqBarMultipliers: [CGFloat] = [0.72, 1.0, 0.78]
    // Staggered phase offsets give each bar an independent idle rhythm.
    private static let eqIdlePhases: [CGFloat] = [0, .pi * 0.75, .pi * 1.45]

    private func startWaveformAnimation(in size: NSSize, xOffset: CGFloat = 0, rightPadding: CGFloat = 0, barCount: Int? = nil) {
        stopWaveformAnimation()
        blobBaseSize = size
        // SF Symbol animation handles the recording visual — just ensure pill cornerRadius.
        contentView?.layer?.cornerRadius = size.height / 2
    }

    private func stopWaveformAnimation() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        for bar in barLayers {
            bar.removeAllAnimations()
            bar.removeFromSuperlayer()
        }
        barLayers.removeAll()
        barAmplitudes.removeAll()
        smoothedAmplitude = 0
        animationTime = 0
        blobBaseSize = .zero
        powerProvider = nil
        contentView?.layer?.transform = CATransform3DIdentity
        removeStopLayer()
    }

    private func updateEQBars() {
        guard !barLayers.isEmpty else { return }

        animationTime += 1.0 / 30.0

        let dB = CGFloat(powerProvider?() ?? -160)
        let normalized = max(0, min(1, (dB + 50) / 42))
        smoothedAmplitude = smoothedAmplitude * 0.15 + normalized * 0.85

        let isReactive = smoothedAmplitude > 0.04
        let maxH = FloatingIndicatorController.eqBarMaxHeight
        let minH = FloatingIndicatorController.eqBarMinHeight
        let maxH = FloatingIndicatorController.eqBarMaxHeight
        let minH = FloatingIndicatorController.eqBarMinHeight

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for i in 0..<barLayers.count {
            let targetH: CGFloat
            if isReactive {
                let jitter = CGFloat.random(in: -0.06...0.06)
                let h = minH + (maxH - minH) * (smoothedAmplitude * FloatingIndicatorController.eqBarMultipliers[i] + jitter)
                targetH = max(minH, min(maxH, h))
            } else {
                // Idle pulse: slow sine wave with staggered phase per bar.
                let phase = animationTime * 2 * .pi * 0.6 + FloatingIndicatorController.eqIdlePhases[i]
                targetH = 8 + 4 * sin(phase)
            }

            // Smooth each bar independently.
            barAmplitudes[i] = barAmplitudes[i] * 0.2 + targetH * 0.8

            var f = barLayers[i].frame
            f.size.height = barAmplitudes[i]
            f.origin.y = (blobBaseSize.height - barAmplitudes[i]) / 2
            barLayers[i].frame = f
        }

        CATransaction.commit()
    }

    private func applyGlassState(_ state: DictationState, frameSize: NSSize) {
        let isIdle = (state == .idle)
        let radius = frameSize.height / 2
        let themeHex = configStore.load().recordingColorHex

        // Glass shown for every state — recording and transcribing are
        // dark frosted glass just like the idle pill.
        glassView?.isHidden = false
        glassView?.layer?.cornerRadius = radius

        // Tint alpha varies by state and hover.
        let tintAlpha: CGFloat
        switch state {
        case .idle:       tintAlpha = isHovered ? 0.72 : 0.44
        case .preparing:  tintAlpha = 0.62
        case .recording:  tintAlpha = 0.62
        case .transcribing: tintAlpha = 0.62
        }
        tintLayer?.isHidden = false
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: themeHex, alpha: tintAlpha).cgColor
        tintLayer?.frame = CGRect(origin: .zero, size: frameSize)
        tintLayer?.cornerRadius = radius

        // Specular only on the compact non-hovered idle pill.
        let showSpecular = isIdle && !isHovered
        specularLayer?.isHidden = !showSpecular
        if showSpecular {
            specularLayer?.frame = CGRect(
                x: 0,
                y: frameSize.height * 0.45,
                width: frameSize.width,
                height: frameSize.height * 0.55
            )
            specularLayer?.cornerRadius = radius
        }

        let iconSize = NSSize(width: 18, height: 18)

        switch state {
        case .idle:
            // Mic symbol centred (or left-aligned when hovered beside text).
            wandIconView?.isHidden = true
            iconLabel?.isHidden = true
            micIconView?.isHidden = false
            if let mic = micIconView {
                if isHovered {
                    mic.frame = NSRect(x: 12, y: (frameSize.height - iconSize.height) / 2,
                                      width: iconSize.width, height: iconSize.height)
                } else {
                    mic.frame = NSRect(x: (frameSize.width - iconSize.width) / 2,
                                       y: (frameSize.height - iconSize.height) / 2,
                                       width: iconSize.width, height: iconSize.height)
                }
            }

        case .recording:
            // Animated mic symbol centred between ✕ (left) and stop (right).
            wandIconView?.isHidden = true
            iconLabel?.isHidden = false   // keeps the ✕ cancel label
            micIconView?.isHidden = false
            if let mic = micIconView {
                // Centre in the region between the ✕ right-edge (~17pt) and stop left-edge (~74pt).
                let midX = (17 + 74) / 2.0
                mic.frame = NSRect(x: midX - iconSize.width / 2,
                                   y: (frameSize.height - iconSize.height) / 2,
                                   width: iconSize.width, height: iconSize.height)
            }

        case .transcribing:
            // Animated wand beside "Transcribing" label, the pair centred in the pill.
            micIconView?.isHidden = true
            iconLabel?.isHidden = true
            wandIconView?.isHidden = false
            if let wand = wandIconView {
                let gap: CGFloat = 6
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                ]
                let textW = ceil(("Transcribing" as NSString).size(withAttributes: attrs).width) + 2
                let totalW = iconSize.width + gap + textW
                let startX = (frameSize.width - totalW) / 2
                wand.frame = NSRect(x: startX, y: (frameSize.height - iconSize.height) / 2,
                                    width: iconSize.width, height: iconSize.height)
                // Reposition text label to sit right of the wand.
                let textH: CGFloat = 14
                textLabel?.frame = NSRect(x: startX + iconSize.width + gap,
                                          y: (frameSize.height - textH) / 2,
                                          width: textW, height: textH)
                textLabel?.isHidden = false
                textLabel?.alphaValue = 1
            }

        case .preparing:
            wandIconView?.isHidden = true
            micIconView?.isHidden = true
            iconLabel?.isHidden = false
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
        textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        contentView.addSubview(textLabel)

        panel.contentView = contentView

        self.panel = panel
        self.contentView = contentView
        self.iconLabel = iconLabel
        self.textLabel = textLabel

        setupGlassLayer(in: contentView, iconLabel: iconLabel)
    }

    private func setupGlassLayer(in contentView: HoverIndicatorView, iconLabel: NSTextField) {
        // masksToBounds clips both the glass blur and the tint layer to the pill shape.
        // The panel's compositor-level shadow is unaffected.
        contentView.layer?.masksToBounds = true

        // NSVisualEffectView — frosted blur behind the pill.
        let vev = NSVisualEffectView(frame: contentView.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        // Force dark appearance so the glass always looks dark regardless of
        // what's behind the pill (light windows, bright desktops, etc.).
        vev.appearance = NSAppearance(named: .darkAqua)
        vev.isHidden = true
        contentView.addSubview(vev, positioned: .below, relativeTo: iconLabel)
        glassView = vev

        // Dark Catppuccin Mocha tint over the blur — gives the pill a defined
        // dark glass presence rather than showing everything underneath.
        let tint = CALayer()
        tint.backgroundColor = NSColor.colorWith(hex: 0x1e1e2e, alpha: 0.44).cgColor
        tint.isHidden = true
        contentView.layer?.addSublayer(tint)
        tintLayer = tint

        // waveform.badge.microphone — idle (static) and recording (animated).
        let symConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let micImage = NSImage(systemSymbolName: "waveform.badge.microphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(symConfig)
        let micView = NSImageView(image: micImage ?? NSImage())
        micView.contentTintColor = .white
        micView.imageScaling = .scaleProportionallyDown
        micView.isHidden = true
        contentView.addSubview(micView)
        micIconView = micView

        // wand.and.sparkles — transcribing (animated).
        let wandConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let wandImage = NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(wandConfig)
        let wandView = NSImageView(image: wandImage ?? NSImage())
        wandView.contentTintColor = .white
        wandView.imageScaling = .scaleProportionallyDown
        wandView.isHidden = true
        contentView.addSubview(wandView)
        wandIconView = wandView

        // Specular highlight — white-to-clear gradient on the upper half for glass depth.
        let specular = CAGradientLayer()
        specular.colors = [
            NSColor.white.withAlphaComponent(0.28).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        specular.startPoint = CGPoint(x: 0.5, y: 1.0)
        specular.endPoint   = CGPoint(x: 0.5, y: 0.4)
        specular.isHidden = true
        contentView.layer?.addSublayer(specular)
        specularLayer = specular
    }

    static func defaultIndicatorCenter(in visibleFrame: NSRect, idleSize: NSSize = NSSize(width: 44, height: 28)) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - idleSize.width / 2 - 8,
            y: visibleFrame.midY
        )
    }

    static func isUsableIndicatorCenter(
        _ center: CGPoint,
        in visibleFrame: NSRect,
        size: NSSize
    ) -> Bool {
        let allowedRect = visibleFrame.insetBy(dx: size.width / 2, dy: size.height / 2)
        return allowedRect.contains(center)
    }

    private func frameForState(_ state: DictationState, config: AppConfig) -> NSRect {
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 64, height: 28)
        }
        let size: NSSize
        switch state {
        case .idle:
            size = isHovered ? NSSize(width: 192, height: 32) : NSSize(width: 48, height: 30)
        case .preparing: size = NSSize(width: 48, height: 30)
        case .recording: size = NSSize(width: 90, height: 34)
        case .transcribing: size = NSSize(width: 120, height: 32)
        }

        // Use the pill's current on-screen center if it exists, so state
        // transitions resize around the current position rather than jumping.
        // Saved config is only used for initial panel creation.
        let center: CGPoint
        if let currentFrame = panel?.frame, currentFrame.width > 0 {
            center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        } else if let saved = config.indicatorOrigin,
                  Self.isUsableIndicatorCenter(CGPoint(x: saved.x, y: saved.y), in: screen, size: size) {
            center = CGPoint(x: saved.x, y: saved.y)
        } else {
            center = Self.defaultIndicatorCenter(in: screen)
        }

        let x = min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func styleForState(_ state: DictationState) -> (background: NSColor, border: NSColor, icon: String, title: String, iconColor: NSColor, textColor: NSColor, alpha: CGFloat) {
        switch state {
        case .idle:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: isHovered ? 0.14 : 0.22),
                "",
                isHovered ? "Hold \(hotkeyLabel) to dictate" : "",
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                isHovered ? 1.0 : 0.85
            )
        case .preparing:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                "", "", .white, .white, 1.0
            )
        case .recording:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                isMeetingRecording ? "⏹" : "",
                isMeetingRecording ? "" : "Listening",
                .white, .white, 1.0
            )
        case .transcribing:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                "",
                transcribingTitle,
                .white,
                .colorWith(hex: 0xFFFFFF, alpha: 0.82),
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

    static func colorWith(hexString: String, alpha: CGFloat = 1.0) -> NSColor {
        var h = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            return .colorWith(hex: 0x1e1e2e, alpha: alpha)
        }
        return .colorWith(hex: Int(value), alpha: alpha)
    }
}
