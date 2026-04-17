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
    private var onDismiss: (() -> Void)?

    private static let dismissDuration: TimeInterval = 15

    func show(
        title: String,
        subtitle: String,
        actionLabel: String = "Start Recording",
        dismissAfter: TimeInterval? = nil,
        onStartRecording: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        close()

        let duration = dismissAfter ?? Self.dismissDuration
        self.onStartRecording = onStartRecording
        self.onDismiss = onDismiss

        guard let screen = NSScreen.main else { return }
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
        panel.level = .floating
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

        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 14, y: 40, width: 180, height: 18)
        contentView.addSubview(titleLabel)

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.frame = NSRect(x: 14, y: 20, width: 180, height: 16)
        contentView.addSubview(subtitleLabel)

        // Start Recording button
        let startButton = NSButton(title: actionLabel, target: self, action: #selector(handleStartRecording))
        startButton.font = .systemFont(ofSize: 12, weight: .medium)
        startButton.frame = NSRect(x: width - 140, y: 20, width: 120, height: 30)
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
        startButton.layer?.cornerRadius = 6
        startButton.isBordered = false
        startButton.contentTintColor = .white
        contentView.addSubview(startButton)

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

    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        progressLayer?.removeAllAnimations()
        progressLayer = nil
        panel?.close()
        panel = nil
        onStartRecording = nil
        onDismiss = nil
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

    @objc private func handleDismiss() {
        let action = onDismiss
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }
}
