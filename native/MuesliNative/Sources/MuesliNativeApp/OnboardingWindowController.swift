import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let controller: MuesliController
    private var window: NSWindow?

    init(controller: MuesliController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Muesli"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)

        let rootView = OnboardingView(controller: controller)
        window.contentView = NSHostingView(rootView: rootView)
        self.window = window
    }
}
