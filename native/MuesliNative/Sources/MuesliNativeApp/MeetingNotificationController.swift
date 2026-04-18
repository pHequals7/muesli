import AppKit
import QuartzCore
import Foundation
import MuesliCore

@MainActor
final class MeetingNotificationController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var progressLayer: CALayer?
    private var onStartRecording: (() -> Void)?
    private var onJoinAndRecord: (() -> Void)?
    private var onJoinOnly: (() -> Void)?
    private var onDismiss: (() -> Void)?

    private static let dismissDuration: TimeInterval = 15

    func show(
        title: String,
        subtitle: String,
        actionLabel: String = "Start Recording",
        meetingURL: URL? = nil,
        dismissAfter: TimeInterval? = nil,
        onStartRecording: @escaping () -> Void,
        onJoinAndRecord: (() -> Void)? = nil,
        onJoinOnly: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        close()
        // Assign onClose AFTER close() so the previous panel's teardown
        // doesn't immediately fire the new callback.
        self.onClose = onClose

        let duration = dismissAfter ?? Self.dismissDuration
        self.onStartRecording = onStartRecording
        self.onJoinAndRecord = onJoinAndRecord
        self.onJoinOnly = onJoinOnly
        self.onDismiss = onDismiss

        let hasJoinButton = meetingURL != nil && onJoinAndRecord != nil
        let platform = meetingURL.flatMap { MeetingPlatform.detect(from: $0) }

        // Use the screen with the mouse cursor so the notification appears where the user is looking
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        let width: CGFloat = 360
        let height: CGFloat = 70
        let margin: CGFloat = 16

        let x = screen.visibleFrame.maxX - width - margin
        let y = screen.visibleFrame.maxY - height - margin

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 1) // Above everything including full-screen
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let contentView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97).cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        // Countdown progress bar at bottom
        let progressBar = CALayer()
        progressBar.frame = CGRect(x: 0, y: 0, width: width, height: 3)
        progressBar.backgroundColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.8).cgColor
        contentView.layer?.addSublayer(progressBar)
        self.progressLayer = progressBar

        // Animate progress bar shrinking from full width to 0
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = width
        shrink.toValue = 0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        progressBar.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressBar.position = CGPoint(x: 0, y: 1.5)
        progressBar.add(shrink, forKey: "countdown")

        // Platform icon + text layout
        let textX: CGFloat
        if let platform, let icon = platform.loadIcon() {
            let iconSize: CGFloat = 28
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.frame = NSRect(x: 14, y: (height - iconSize) / 2 + 2, width: iconSize, height: iconSize)
            contentView.addSubview(iconView)
            textX = 14 + iconSize + 8
        } else {
            textX = 14
        }

        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: textX, y: 40, width: 180, height: 18)
        contentView.addSubview(titleLabel)

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.frame = NSRect(x: textX, y: 20, width: 180, height: 16)
        contentView.addSubview(subtitleLabel)

        if hasJoinButton {
            // Split button: "Join & Record" (main) + chevron dropdown with "Join Only"
            let buttonWidth: CGFloat = 110
            let chevronWidth: CGFloat = 24
            let totalWidth = buttonWidth + chevronWidth
            let buttonX = width - totalWidth - 10
            let textMaxX = buttonX - 8
            let greenColor = NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0)
            let greenDarker = NSColor(red: 0.15, green: 0.58, blue: 0.42, alpha: 1.0)

            // Clamp text labels so they don't overlap the button
            titleLabel.frame.size.width = textMaxX - textX
            subtitleLabel.frame.size.width = textMaxX - textX

            // Main "Join & Record" button
            let joinButton = NSButton(title: "Join & Record", target: self, action: #selector(handleJoinAndRecord))
            joinButton.font = .systemFont(ofSize: 11, weight: .medium)
            joinButton.frame = NSRect(x: buttonX, y: 20, width: buttonWidth, height: 28)
            joinButton.wantsLayer = true
            joinButton.layer?.backgroundColor = greenColor.cgColor
            joinButton.layer?.cornerRadius = 6
            joinButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            joinButton.isBordered = false
            joinButton.contentTintColor = .white
            contentView.addSubview(joinButton)

            // Chevron dropdown button
            let chevronButton = NSButton(title: "▾", target: self, action: #selector(handleChevronClick(_:)))
            chevronButton.font = .systemFont(ofSize: 9, weight: .medium)
            chevronButton.frame = NSRect(x: buttonX + buttonWidth, y: 20, width: chevronWidth, height: 28)
            chevronButton.wantsLayer = true
            chevronButton.layer?.backgroundColor = greenDarker.cgColor
            chevronButton.layer?.cornerRadius = 6
            chevronButton.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            chevronButton.isBordered = false
            chevronButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            contentView.addSubview(chevronButton)
        } else {
            // Single "Start Recording" button
            let startButton = NSButton(title: actionLabel, target: self, action: #selector(handleStartRecording))
            startButton.font = .systemFont(ofSize: 12, weight: .medium)
            startButton.frame = NSRect(x: width - 140, y: 20, width: 120, height: 30)
            startButton.wantsLayer = true
            startButton.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            startButton.layer?.cornerRadius = 6
            startButton.isBordered = false
            startButton.contentTintColor = .white
            contentView.addSubview(startButton)
        }

        // Dismiss button (×)
        let dismissButton = NSButton(title: "×", target: self, action: #selector(handleDismiss))
        dismissButton.font = .systemFont(ofSize: 14, weight: .medium)
        dismissButton.frame = NSRect(x: width - 22, y: height - 20, width: 14, height: 14)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        contentView.addSubview(dismissButton)

        panel.contentView = contentView
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Fade in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Auto-dismiss
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.animateOut {
                    self?.close()
                }
            }
        }
    }

    var onClose: (() -> Void)?

    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        progressLayer?.removeAllAnimations()
        progressLayer = nil
        panel?.close()
        panel = nil
        onStartRecording = nil
        onJoinAndRecord = nil
        onJoinOnly = nil
        onDismiss = nil
        onClose?()
        onClose = nil
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let panel else { completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    @objc private func handleStartRecording() {
        let action = onStartRecording
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleJoinAndRecord() {
        let action = onJoinAndRecord
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleJoinOnly() {
        let action = onJoinOnly
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleChevronClick(_ sender: NSButton) {
        let menu = NSMenu()
        let joinOnlyItem = NSMenuItem(title: "Join Only", action: #selector(handleJoinOnly), keyEquivalent: "")
        joinOnlyItem.target = self
        menu.addItem(joinOnlyItem)

        let recordOnlyItem = NSMenuItem(title: "Record Only", action: #selector(handleStartRecording), keyEquivalent: "")
        recordOnlyItem.target = self
        menu.addItem(recordOnlyItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func handleDismiss() {
        let action = onDismiss
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }
}

// MARK: - Meeting Platform Detection

enum MeetingPlatform {
    case zoom
    case googleMeet
    case teams
    case webex
    case facetime

    static func detect(from url: URL) -> MeetingPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("zoom.us") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        if host.hasSuffix("teams.microsoft.com") { return .teams }
        if host.hasSuffix("webex.com") { return .webex }
        if host == "facetime.apple.com" { return .facetime }
        return nil
    }

    func loadIcon() -> NSImage? {
        switch self {
        case .zoom:
            if let url = Bundle.main.url(forResource: "zoom-app", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Zoom")
        case .googleMeet:
            if let url = Bundle.main.url(forResource: "google-meet", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Google Meet")
        case .teams:
            return NSImage(systemSymbolName: "person.3.fill", accessibilityDescription: "Teams")
        case .webex:
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Webex")
        case .facetime:
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "FaceTime")
        }
    }
}
