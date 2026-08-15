import XCTest

@testable import XDownloader

/// The install sheet's footer primary button adapts to the problem mix — pins
/// the three labels from the approved mockup, and that a healthy toolbox
/// offers no primary action at all.
final class InstallSheetLabelTests: XCTestCase {

    func testOnlyMissingToolsOffersInstall() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 2, outdatedCount: 0),
            "Install Missing Tools")
    }

    func testOnlyOutdatedToolsOffersUpdate() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 0, outdatedCount: 1),
            "Update Outdated Tools")
    }

    func testMixedProblemsOfferTheCombinedFlow() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 1, outdatedCount: 1),
            "Install Missing + Update Outdated")
    }

    func testHealthyToolboxHasNoPrimaryAction() {
        XCTAssertNil(InstallSheetModel.primaryActionLabel(missingCount: 0, outdatedCount: 0))
    }
}
