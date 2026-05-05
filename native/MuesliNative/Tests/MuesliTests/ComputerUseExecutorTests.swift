import Testing
@testable import MuesliNativeApp

@Suite("Computer Use executor")
struct ComputerUseExecutorTests {
    @Test("maps common app aliases to bundle identifiers")
    @MainActor
    func commonAppAliases() {
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "Google Chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "VS Code") == "com.microsoft.VSCode")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "tail scale") == "io.tailscale.ipn.macsys")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "Tailscale") == "io.tailscale.ipn.macsys")
    }

    @Test("maps spoken key names to virtual key codes")
    @MainActor
    func spokenKeyNames() {
        #expect(ComputerUseExecutor.keyCode(for: "l") == 37)
        #expect(ComputerUseExecutor.keyCode(for: "enter") == 36)
        #expect(ComputerUseExecutor.keyCode(for: "left arrow") == 123)
    }
}
