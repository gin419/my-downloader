import Foundation
import XCTest

@testable import XDownloader

@MainActor
final class ProcessRunnerStreamingTests: XCTestCase {
    func testStreamsStdoutStderrAndTrailingPartialLine() async {
        var lines: [String] = []
        var registered = false
        var unregistered = false

        let exitCode = await ProcessRunner.runStreaming(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'stdout\\n'; printf 'stderr-tail' >&2"],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in registered = true },
            unregister: { unregistered = true },
            onLine: { lines.append($0) })

        XCTAssertEqual(exitCode, 0)
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

        let exitCode = await ProcessRunner.runStreaming(
            executablePath: "/bin/sleep",
            arguments: ["5"],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { process = $0 },
            unregister: { process = nil },
            onLine: { _ in })
        _ = await cancel.value

        XCTAssertNotEqual(exitCode, 0)
        XCTAssertNil(process)
    }

    func testDeliversAllQueuedLinesBeforeReturning() async {
        var lines: [String] = []
        let exitCode = await ProcessRunner.runStreaming(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                #"i=0; while [ $i -lt 1000 ]; do echo line-$i; i=$((i+1)); done"#,
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in },
            unregister: {},
            onLine: { lines.append($0) })

        XCTAssertEqual(exitCode, 0)
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

        let exitCode = await task.value
        XCTAssertEqual(exitCode, 15)
        XCTAssertFalse(registered)
    }

    func testLaunchFailureUnregistersAndEmitsDiagnostic() async {
        var lines: [String] = []
        var registered = false
        var unregistered = false
        let exitCode = await ProcessRunner.runStreaming(
            executablePath: "/definitely/missing/gallery-dl",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in registered = true },
            unregister: { unregistered = true },
            onLine: { lines.append($0) })

        XCTAssertEqual(exitCode, -1)
        XCTAssertTrue(registered)
        XCTAssertTrue(unregistered)
        XCTAssertTrue(lines.contains { $0.hasPrefix("[process][error]") })
    }
}
