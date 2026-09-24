import XCTest
@testable import PhotoApp

/// `EnhanceModel.summary(_:)`/`describe(_:)` are pure string formatting,
/// pulled out of `runEnhance`'s own file-I/O flow specifically so this
/// slice is directly testable — matching `PasteSettingsModelSummaryTests`'
/// own precedent (the surrounding I/O stays untested by this codebase's
/// established convention for `@MainActor`/file-I/O-driven types).
final class EnhanceModelSummaryTests: XCTestCase {
    func testSummaryForMetalFXNamesTheFileAndTheMethod() {
        let outcome = EnhanceOutcome(
            url: URL(fileURLWithPath: "/tmp/IMG_0001-Enhanced-SR.jpg"),
            method: .metalFX,
            fallbackReason: nil
        )

        XCTAssertEqual(
            EnhanceModel.summary(outcome),
            "Created “IMG_0001-Enhanced-SR.jpg” (2x, MetalFX)."
        )
    }

    func testSummaryForLanczosNamesTheFileAndExplainsWhyMetalFXWasNotUsed() {
        let outcome = EnhanceOutcome(
            url: URL(fileURLWithPath: "/tmp/IMG_0001-Enhanced-SR.jpg"),
            method: .lanczos,
            fallbackReason: .noMetalDevice
        )

        XCTAssertEqual(
            EnhanceModel.summary(outcome),
            "Created “IMG_0001-Enhanced-SR.jpg” (2x, Lanczos — MetalFX unavailable: no Metal device)."
        )
    }

    func testSummaryForLanczosWithNoReasonOmitsTheColonClause() {
        // Defensive case: `upscale`'s own contract always pairs `.lanczos`
        // with a non-nil `fallbackReason` when MetalFX wasn't used, but
        // `EnhanceOutcome` doesn't enforce that at the type level — this
        // pins that `summary` degrades gracefully (no dangling "unavailable:
        // " with nothing after it) rather than trusting the pairing blindly.
        let outcome = EnhanceOutcome(
            url: URL(fileURLWithPath: "/tmp/IMG_0001-Enhanced-SR.jpg"),
            method: .lanczos,
            fallbackReason: nil
        )

        XCTAssertEqual(
            EnhanceModel.summary(outcome),
            "Created “IMG_0001-Enhanced-SR.jpg” (2x, Lanczos — MetalFX unavailable)."
        )
    }

    func testDescribeEncodeFailedPassesThroughItsOwnMessage() {
        XCTAssertEqual(
            EnhanceModel.describe(.encodeFailed("disk full")),
            "disk full"
        )
    }

    /// Reviewer-caught: an earlier version of this test only asserted
    /// non-empty and "not equal to the raw case name" — that survives
    /// swapping two return strings between cases, or even collapsing
    /// every case to one shared constant phrase. Asserting the EXACT
    /// string per case, as every other test in this file already does,
    /// closes both gaps.
    func testDescribeEachReasonHasItsOwnExactPhrase() {
        XCTAssertEqual(EnhanceModel.describe(.noMetalDevice), "no Metal device")
        XCTAssertEqual(EnhanceModel.describe(.deviceUnsupported), "device unsupported")
        XCTAssertEqual(EnhanceModel.describe(.exceedsMaxTextureSize), "photo too large")
        XCTAssertEqual(EnhanceModel.describe(.scalerConstructionFailed), "couldn't start")
        XCTAssertEqual(EnhanceModel.describe(.textureAllocationFailed), "out of memory")
    }
}
