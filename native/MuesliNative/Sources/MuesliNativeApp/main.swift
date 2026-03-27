import AppKit
import MuesliCore

@main
@MainActor
enum MuesliMain {
    static func main() {
        if CommandLine.arguments.contains("--profile") {
            Profiler.shared.isEnabled = true
            Profiler.shared.begin("app.lifetime", category: "startup")
            fputs("[profiler] profiling enabled — profile written to ~/Library/Application Support/Muesli/profiles/ on quit\n", stderr)
        }
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
