import Foundation
import Sparkle
import Testing
@testable import MuesliNativeApp

@Suite("Update failure guidance")
struct UpdateFailureGuidanceTests {
    @Test("shows fallback for Sparkle installation failures")
    func showsFallbackForInstallationFailures() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 4005)

        #expect(UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test("does not show fallback for no update")
    func hidesFallbackForNoUpdate() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 1001)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test("does not show fallback for unrelated errors")
    func hidesFallbackForUnrelatedErrors() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }
}
