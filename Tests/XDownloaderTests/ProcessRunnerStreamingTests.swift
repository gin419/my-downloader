import Foundation
import XCTest

@testable import XDownloader

@MainActor
final class ProcessRunnerStreamingTests: XCTestCase {
    func testStreamsStdoutStderrAndTrailingPartialLine() async {
        var lines: [String] = []
        var registered = false
        var unregistered = false

        let result = await ProcessRunner.runStreaming(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'stdout\\n'; printf 'stderr-tail' >&2"],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in registered = true },
            unregister: { unregistered = true },
            onLine: { lines.append($0) })

        XCTAssertEqual(result.code, 0)
        XCTAssertFalse(result.wasSignal)
        XCTAssertTrue(registered)
        XCTAssertTrue(unregistered)
        XCTAssertEqual(Set(lines), Set(["stdout", "stderr-tail"]))
    }

    func testRegisteredProcessCanBeCancelled() async {
        var process: Process?
        let cancel = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            process?.terminate()
        }

        let result = await ProcessRunner.runStreaming(
            executablePath: "/bin/sleep",
            arguments: ["5"],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { process = $0 },
            unregister: { process = nil },
            onLine: { _ in })
        _ = await cancel.value

        // terminate() is SIGTERM: the death must be reported AS a signal —
        // code 15 read as an exit code would invent a tool-chosen status
        // (and a SIGINT death would read as argparse's exit 2).
        XCTAssertTrue(result.wasSignal)
        XCTAssertEqual(result.code, 15)
        XCTAssertNil(process)
    }

    func testDeliversAllQueuedLinesBeforeReturning() async {
        var lines: [String] = []
        let result = await ProcessRunner.runStreaming(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                #"i=0; while [ $i -lt 1000 ]; do echo line-$i; i=$((i+1)); done"#,
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in },
            unregister: {},
            onLine: { lines.append($0) })

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(lines.count, 1000)
        XCTAssertEqual(Set(lines).count, 1000)
        XCTAssertTrue(lines.contains("line-999"))
    }

    func testCancelledTaskDoesNotLaunchProcess() async {
        var registered = false
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            return await ProcessRunner.runStreaming(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                environment: ["PATH": "/usr/bin:/bin"],
                register: { _ in registered = true },
                unregister: {},
                onLine: { _ in })
        }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result.code, 15)
        XCTAssertTrue(result.wasSignal, "pre-launch cancellation is morally a SIGTERM, not a tool exit")
        XCTAssertFalse(registered)
    }

    func testLaunchFailureUnregistersAndEmitsDiagnostic() async {
        var lines: [String] = []
        var registered = false
        var unregistered = false
        let result = await ProcessRunner.runStreaming(
            executablePath: "/definitely/missing/gallery-dl",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in registered = true },
            unregister: { unregistered = true },
            onLine: { lines.append($0) })

        XCTAssertEqual(result.code, -1)
        XCTAssertFalse(result.wasSignal)
        XCTAssertTrue(registered)
        XCTAssertTrue(unregistered)
        XCTAssertTrue(lines.contains { $0.hasPrefix("[process][error]") })
    }
}

/// `ProcessRunner.run` (the DownloadItem-coupled variant the downloads use).
@MainActor
final class ProcessRunnerRunTests: XCTestCase {

    /// A short-lived process's final ERROR line must reach lineParser before
    /// run() returns, every time — the caller composes its generic
    /// exit-code message right after the await, and the pre-fix
    /// readabilityHandler teardown could race the last pipe delivery and
    /// drop the one line that named the real cause. Repeated iterations
    /// because the race was timing-dependent.
    func testFinalErrorLineAlwaysReachesParserBeforeReturn() async {
        for iteration in 0..<30 {
            let item = DownloadItem(url: "https://x.com/a/status/1")
            var lines: [String] = []
            let result = await ProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "echo 'ERROR: the real cause' >&2; exit 3"],
                item: item,
                register: { _ in },
                unregister: {},
                lineParser: { line, _ in lines.append(line) })

            XCTAssertEqual(result.code, 3, "iteration \(iteration)")
            XCTAssertFalse(result.wasSignal, "iteration \(iteration)")
            XCTAssertTrue(
                lines.contains("ERROR: the real cause"),
                "iteration \(iteration): final line lost — got \(lines)")
        }
    }

    func testSignalDeathIsReportedAsSignalNotExitCode() async {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        let result = await ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "kill -TERM $$"],
            item: item,
            register: { _ in },
            unregister: {},
            lineParser: { _, _ in })

        XCTAssertTrue(result.wasSignal)
        XCTAssertEqual(result.code, 15)
        XCTAssertFalse(result.isSuccess)
    }
}
