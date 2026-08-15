import XCTest

@testable import XDownloader

/// Pins the approved mockup's banner states A–D with their exact copy, and
/// the problem-set signature that keys the session dismissal (✕ hides one
/// signature; a changed problem set brings the banner back).
final class RequirementsBannerModelTests: XCTestCase {

    private func missing(_ id: String) -> ToolHealth {
        ToolHealth(id: id, name: id, brewPackage: id, docsURL: "", path: nil, status: .missing)
    }

    private func outdated(_ id: String, _ installed: String, _ detail: String?) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "",
            path: "/opt/homebrew/bin/\(id)",
            status: .outdated(installed: installed, detail: detail))
    }

    private func broken(_ id: String) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "",
            path: "/opt/homebrew/bin/\(id)",
            status: .broken(detail: "can't run"))
    }

    // MARK: - State A: no problems → hidden

    func testStateANoProblemsHidesBanner() {
        XCTAssertNil(RequirementsBannerModel.make(problems: []))
    }

    // MARK: - State B: missing only (red stripe)

    func testStateBSingleMissingTool() {
        let model = RequirementsBannerModel.make(problems: [missing("gallery-dl")])
        XCTAssertEqual(model?.headline, "Missing: gallery-dl")
        XCTAssertEqual(model?.subtitle, "X, Instagram and Reddit downloads need it.")
        XCTAssertEqual(model?.buttonTitle, "Set Up…")
        XCTAssertEqual(model?.severity, .missing)
    }

    func testStateBMultipleMissingToolsJoinWithCommas() {
        let model = RequirementsBannerModel.make(problems: [missing("yt-dlp"), missing("gallery-dl")])
        XCTAssertEqual(model?.headline, "Missing: yt-dlp, gallery-dl")
        XCTAssertEqual(model?.subtitle, "YouTube, X, Instagram and Reddit downloads need them.")
        XCTAssertEqual(model?.buttonTitle, "Set Up…")
    }

    func testStateBMissingDenoNamesYouTube() {
        // deno is yt-dlp's JS runtime for YouTube — the sub-copy must say
        // which downloads are on the line.
        let model = RequirementsBannerModel.make(problems: [missing("deno")])
        XCTAssertEqual(model?.headline, "Missing: deno")
        XCTAssertEqual(model?.subtitle, "YouTube downloads need it.")
    }

    // MARK: - State C: outdated only (amber stripe)

    func testStateCOutdatedYtDlpWithDerivableAge() {
        let model = RequirementsBannerModel.make(
            problems: [outdated("yt-dlp", "2024.11.04", "21 months old")])
        XCTAssertEqual(model?.headline, "yt-dlp is outdated (2024.11.04 · 21 months old)")
        XCTAssertEqual(model?.subtitle, "YouTube and X downloads likely fail until it's updated.")
        XCTAssertEqual(model?.buttonTitle, "Update…")
        XCTAssertEqual(model?.severity, .outdated)
    }

    func testStateCVersionAloneWhenAgeNotDerivable() {
        let model = RequirementsBannerModel.make(problems: [outdated("ffmpeg", "9.0.1", nil)])
        XCTAssertEqual(model?.headline, "ffmpeg is outdated (9.0.1)")
        XCTAssertEqual(model?.severity, .outdated)
    }

    func testStateCMultipleOutdatedTools() {
        let model = RequirementsBannerModel.make(
            problems: [
                outdated("yt-dlp", "2024.11.04", "21 months old"),
                outdated("ffmpeg", "9.0.1", nil),
            ])
        XCTAssertEqual(model?.headline, "Outdated: yt-dlp (2024.11.04), ffmpeg (9.0.1)")
        XCTAssertEqual(model?.subtitle, "YouTube and X downloads likely fail until they're updated.")
        XCTAssertEqual(model?.buttonTitle, "Update…")
    }

    // MARK: - Broken (red family: missing ∪ broken)

    func testBrokenSingleToolIsRedWithReinstallCopy() {
        let model = RequirementsBannerModel.make(problems: [broken("yt-dlp")])
        XCTAssertEqual(model?.headline, "yt-dlp is broken (can't run) — reinstall it.")
        XCTAssertEqual(model?.subtitle, "YouTube and X downloads need it.")
        XCTAssertEqual(model?.buttonTitle, "Set Up…")
        XCTAssertEqual(model?.severity, .missing)
    }

    func testBrokenMultipleTools() {
        let model = RequirementsBannerModel.make(problems: [broken("yt-dlp"), broken("ffmpeg")])
        XCTAssertEqual(model?.headline, "Broken: yt-dlp, ffmpeg — reinstall them.")
        XCTAssertEqual(model?.subtitle, "YouTube and X downloads need them.")
        XCTAssertEqual(model?.severity, .missing)
    }

    func testMixedMissingAndBrokenJoinsSegments() {
        let model = RequirementsBannerModel.make(problems: [missing("deno"), broken("yt-dlp")])
        XCTAssertEqual(model?.headline, "Missing: deno · Broken: yt-dlp")
        XCTAssertEqual(model?.subtitle, "Downloads will fail or degrade until both are fixed.")
        XCTAssertEqual(model?.severity, .missing)
    }

    // MARK: - State D: mixed (red wins)

    func testStateDMixedRedWins() {
        let model = RequirementsBannerModel.make(
            problems: [missing("deno"), outdated("yt-dlp", "2024.11.04", "21 months old")])
        // Outdated entries show the version only in the mixed headline — the
        // age would crowd out the missing half.
        XCTAssertEqual(model?.headline, "Missing: deno · Outdated: yt-dlp (2024.11.04)")
        XCTAssertEqual(model?.subtitle, "Downloads will fail or degrade until both are fixed.")
        XCTAssertEqual(model?.buttonTitle, "Set Up…")
        XCTAssertEqual(model?.severity, .missing)
    }

    // MARK: - Dismissal signature

    func testSignatureMatchesSpecExample() {
        XCTAssertEqual(
            RequirementsBannerModel.signature(for: [missing("deno"), outdated("yt-dlp", "2024.11.04", nil)]),
            "missing:deno|outdated:yt-dlp")
    }

    func testSignatureIsOrderInsensitive() {
        let forward = RequirementsBannerModel.signature(for: [missing("deno"), outdated("yt-dlp", "2024.11.04", nil)])
        let reversed = RequirementsBannerModel.signature(for: [outdated("yt-dlp", "2024.11.04", nil), missing("deno")])
        XCTAssertEqual(forward, reversed)
    }

    func testSignatureChangesWhenProblemSetChanges() {
        let denoOnly = RequirementsBannerModel.signature(for: [missing("deno")])
        let denoAndYtDlp = RequirementsBannerModel.signature(for: [missing("deno"), missing("yt-dlp")])
        XCTAssertNotEqual(denoOnly, denoAndYtDlp)
    }

    func testSignatureChangesWhenAToolChangesKind() {
        // yt-dlp going missing → outdated is a NEW problem set: a banner
        // dismissed for the missing state must reappear.
        let asMissing = RequirementsBannerModel.signature(for: [missing("yt-dlp")])
        let asOutdated = RequirementsBannerModel.signature(for: [outdated("yt-dlp", "2024.11.04", nil)])
        XCTAssertNotEqual(asMissing, asOutdated)
    }

    func testModelCarriesItsOwnSignature() {
        let problems = [missing("deno"), outdated("yt-dlp", "2024.11.04", nil)]
        let model = RequirementsBannerModel.make(problems: problems)
        XCTAssertEqual(model?.signature, RequirementsBannerModel.signature(for: problems))
    }

    func testSignatureIncludesBroken() {
        XCTAssertEqual(RequirementsBannerModel.signature(for: [broken("yt-dlp")]), "broken:yt-dlp")
    }

    // MARK: - Dismissal visibility (session-scoped, held by the manager)

    func testDismissedSignatureHidesTheBanner() {
        let problems = [missing("deno")]
        let signature = RequirementsBannerModel.signature(for: problems)
        XCTAssertNil(
            RequirementsBannerModel.visibleModel(problems: problems, dismissedSignature: signature))
    }

    func testChangedProblemSetResurrectsADismissedBanner() {
        let dismissed = RequirementsBannerModel.signature(for: [missing("deno")])
        let grown = [missing("deno"), outdated("yt-dlp", "2024.11.04", nil)]
        XCTAssertNotNil(
            RequirementsBannerModel.visibleModel(problems: grown, dismissedSignature: dismissed))
    }

    func testNoDismissalShowsTheBanner() {
        XCTAssertNotNil(
            RequirementsBannerModel.visibleModel(problems: [missing("deno")], dismissedSignature: nil))
    }
}
