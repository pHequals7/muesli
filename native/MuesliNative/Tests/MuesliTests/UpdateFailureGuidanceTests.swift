import Foundation
import Sparkle
import Testing
@testable import MuesliNativeApp

@Suite("Update failure guidance")
struct UpdateFailureGuidanceTests {
    @Test("classifies Sparkle no-update errors as up to date")
    func classifiesNoUpdateErrorCode() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 1001)

        #expect(UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("classifies Sparkle no-update reason as up to date")
    func classifiesNoUpdateReason() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1002,
            userInfo: [SPUNoUpdateFoundReasonKey: 1]
        )

        #expect(UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("does not classify localized text alone as up to date")
    func rejectsLocalizedTextWithoutSparkleSignal() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "You’re up to date!"]
        )

        #expect(!UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("does not classify unrelated Sparkle errors as up to date")
    func rejectsUnrelatedSparkleErrors() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )

        #expect(!UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test(
        "shows fallback for Sparkle installation failures",
        arguments: [4000, 4001, 4002, 4003, 4004, 4005, 4009, 4010, 4012, 4013]
    )
    func showsFallbackForInstallationFailures(code: Int) {
        let error = NSError(domain: SUSparkleErrorDomain, code: code)

        #expect(UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test(
        "does not show fallback for non-install Sparkle errors",
        arguments: [1001, 3001, 3002, 4006, 4007, 4008, 4011]
    )
    func hidesFallbackForNonInstallSparkleErrors(code: Int) {
        let error = NSError(domain: SUSparkleErrorDomain, code: code)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test("does not show fallback for unrelated errors")
    func hidesFallbackForUnrelatedErrors() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }
}
