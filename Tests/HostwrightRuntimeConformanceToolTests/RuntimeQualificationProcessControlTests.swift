import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationProcessControlTests: XCTestCase {
    func testPartialEffectControllerFailsOnlyOnceAfterBeingArmed() throws {
        let controller = RuntimeQualificationPartialEffectFaultController()

        XCTAssertNoThrow(try controller.failAfterRuntimeMutation())
        XCTAssertFalse(controller.didActivate)

        controller.arm()
        XCTAssertThrowsError(try controller.failAfterRuntimeMutation()) { error in
            XCTAssertEqual(
                error as? RuntimeQualificationInjectedPartialEffect,
                .afterRuntimeMutation
            )
        }
        XCTAssertTrue(controller.didActivate)
        XCTAssertNoThrow(try controller.failAfterRuntimeMutation())
    }

    func testHelperUsesProductionTimeoutAndBoundedInjectedDeadline() async throws {
        XCTAssertEqual(RuntimeQualificationHelperTiming.normalRequestTimeoutMilliseconds, 30_000)

        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-helper-test-\(UUID().uuidString).sock")
        let controller = RuntimeQualificationHelperFaultController(
            registry: RuntimeQualificationHelperProcessRegistry(),
            socketURL: socketURL
        )
        controller.arm(.timedOut(deadlineMilliseconds: 25))
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await controller.transport().exchange(
                frame: Data([0, 0, 0, 1, 0]),
                socketURL: socketURL,
                deadlineUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) + 30_000,
                expectedProcessID: nil
            )
            XCTFail("Expected the injected timeout.")
        } catch ContainerizationHelperClientError.timedOut {
            let elapsedMilliseconds = Int64(
                (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            )
            XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 25)
            XCTAssertLessThan(elapsedMilliseconds, 1_000)
        }

        let evidence = controller.evidence()
        XCTAssertTrue(evidence.activated)
        XCTAssertTrue(evidence.deadlineEnforced)
        XCTAssertFalse(evidence.terminated)
    }

    func testFinalShutdownRequiresSocketPathToBeAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-helper-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("helper.sock")
        let registry = RuntimeQualificationHelperProcessRegistry()

        XCTAssertTrue(
            registry.waitUntilStoppedAndSocketRemoved(
                socketURL: socketURL,
                timeoutMilliseconds: 20
            )
        )

        try Data("occupied".utf8).write(to: socketURL)
        XCTAssertFalse(
            registry.waitUntilStoppedAndSocketRemoved(
                socketURL: socketURL,
                timeoutMilliseconds: 20
            )
        )
    }

    func testCrashProbeTerminatesTheObservedDescendantTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-crash-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.c")
        let fixture = directory.appendingPathComponent("fixture")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        try Data(
            """
            #include <fcntl.h>
            #include <signal.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <sys/stat.h>
            #include <sys/types.h>
            #include <unistd.h>

            int main(int argc, char **argv) {
                if (argc != 4) return 64;
                pid_t child = fork();
                if (child < 0) return 65;
                if (child == 0) {
                    for (;;) pause();
                }
                int fd = open(argv[3], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
                if (fd < 0) return 66;
                dprintf(fd, "%d\\n", child);
                if (fsync(fd) != 0 || close(fd) != 0) return 67;
                for (;;) pause();
            }
            """.utf8
        ).write(to: source)
        let compilation = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: "/usr/bin/clang",
                arguments: [source.path, "-o", fixture.path],
                timeoutMilliseconds: 30_000,
                maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                maximumStandardErrorBytes: 1 * 1_024 * 1_024
            )
        )
        XCTAssertEqual(
            compilation.exitStatus,
            0,
            String(decoding: compilation.standardError, as: UTF8.self)
        )
        XCTAssertEqual(chmod(fixture.path, 0o700), 0)

        let crashed = try await RuntimeQualificationSubprocessProbe.crashed(
            executable: fixture.path,
            resourceIdentifier: childPIDFile.path
        )
        XCTAssertTrue(crashed)
        let childPID = pid_t(
            try XCTUnwrap(
                Int32(
                    String(contentsOf: childPIDFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        )
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        errno = 0
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
