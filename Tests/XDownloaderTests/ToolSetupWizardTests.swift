import XCTest

@testable import XDownloader

/// Choice + confirm gate: no installer is invoked until Confirm and start;
/// cancel on confirm does nothing.
@MainActor
final class ToolSetupWizardTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private final class Calls {
        var count = 0
        var lastPlan: ToolSetupPlan?
    }

    private func monitor(calls: Calls, brewPath: String? = nil) -> ToolHealthMonitor {
        ToolHealthMonitor(
            pathResolver: { $0.id == "deno" ? nil : "/opt/homebrew/bin/\($0.id)" },
            versionLineProvider: { path, _ in
                if path.hasSuffix("yt-dlp") { return "2024.11.04" }
                if path.hasSuffix("gallery-dl") { return "1.32.9" }
                if path.hasSuffix("ffmpeg") { return "ffmpeg version 9.0.1" }
                return nil
            },
            brewOutdatedProvider: { _ in [] },
            now: { self.date(2026, 8, 16) },
            brewPathProvider: { brewPath },
            executePlan: { plan, _ in
                calls.count += 1
                calls.lastPlan = plan
                return ToolRepairResult(processExitCode: 0, rolledBack: false, failureMessage: nil)
            })
    }

    func testChoiceAndConfirmDoNotInvokeInstaller() async {
        let calls = Calls()
        let monitor = monitor(calls: calls, brewPath: nil)
        await monitor.performProbe()
        XCTAssertEqual(monitor.health(for: "deno")?.status, .missing)

        monitor.beginChoice()
        XCTAssertEqual(calls.count, 0)
        if case .choose(let draft) = monitor.setupStep {
            XCTAssertTrue(draft.hasActionableSelection)
        } else {
            XCTFail("expected choose step, got \(monitor.setupStep)")
        }

        monitor.reviewPlan()
        XCTAssertEqual(calls.count, 0)
        guard case .confirm = monitor.setupStep else {
            return XCTFail("expected confirm step")
        }

        monitor.cancelSetup()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(monitor.setupStep, .health)
        XCTAssertEqual(monitor.repairState, .idle)
    }

    func testCancelOnConfirmReturnsToChoiceAndStartsNothing() async {
        let calls = Calls()
        let monitor = monitor(calls: calls, brewPath: nil)
        await monitor.performProbe()
        monitor.beginChoice()
        monitor.reviewPlan()
        monitor.backToChoice()
        XCTAssertEqual(calls.count, 0)
        guard case .choose = monitor.setupStep else {
            return XCTFail("cancel on confirm must return to choice")
        }
        monitor.cancelSetup()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(monitor.setupStep, .health)
    }

    func testConfirmAndStartInvokesInstallerOnceWithFrozenPlan() async {
        let calls = Calls()
        let monitor = monitor(calls: calls, brewPath: nil)
        await monitor.performProbe()
        monitor.beginChoice()
        monitor.reviewPlan()
        monitor.confirmAndStart()
        await monitor.awaitRepairSettled()

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.lastPlan?.items.map(\.toolID), ["deno"])
        XCTAssertEqual(calls.lastPlan?.items.first?.installer, .standalone)
        if case .result = monitor.setupStep {
            // expected
        } else {
            XCTFail("expected result step, got \(monitor.setupStep)")
        }
    }

    func testConfirmAndStartFromChoiceIsANoOp() async {
        let calls = Calls()
        let monitor = monitor(calls: calls, brewPath: nil)
        await monitor.performProbe()
        monitor.beginChoice()
        monitor.confirmAndStart()
        await monitor.awaitRepairSettled()
        XCTAssertEqual(calls.count, 0)
    }

    func testStartRepairWithoutPlanNeverInstalls() async {
        let calls = Calls()
        let monitor = monitor(calls: calls, brewPath: "/opt/homebrew/bin/brew")
        await monitor.performProbe()
        monitor.plantRepairOutcomeForTesting(.success, judgedAgainst: monitor.problems)
        monitor.startRepair()
        await monitor.awaitRepairSettled()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(monitor.repairState, .idle)
    }
}
