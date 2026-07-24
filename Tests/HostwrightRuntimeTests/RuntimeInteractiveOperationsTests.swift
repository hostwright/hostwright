import Darwin
import Foundation
import XCTest
@testable import HostwrightRuntime

final class RuntimeInteractiveOperationsTests: XCTestCase {
    func testCapabilityContractFailsBeforeProcessExecution() async throws {
        let runner = RecordingInteractiveProcessRunner(
            output: Data(#"{"id":"fixture"}"#.utf8)
        )
        let executor = AppleContainerInteractiveExecutor(
            executableResolver: InteractiveExecutableResolver(),
            processRunner: runner
        )

        do {
            _ = try await executor.execute(
                .inspect(resourceIdentifier: managedIdentifier),
                capabilitySnapshot: snapshot(providerID: .appleContainerization),
                timeoutMilliseconds: 1_000
            ) { _ in }
            XCTFail("Expected provider capability refusal.")
        } catch {
            guard case .capabilityUnavailable(let operation, _) =
                    error as? RuntimeInteractiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .inspect)
        }
        XCTAssertEqual(runner.runCount, 0)
    }

    func testProviderContractsAdvertiseOnlyRestartSafeOperations() {
        let apple = RuntimeInteractiveCapabilityContract(snapshot: snapshot())
        XCTAssertFalse(apple.availableOperations.contains(.attach))
        XCTAssertFalse(apple.availableOperations.contains(.logsFollow))
        XCTAssertTrue(
            apple.unavailableReasons[.attach]?.contains("cannot reattach") == true
        )
        XCTAssertTrue(
            apple.unavailableReasons[.logsFollow]?.contains("stable cursor") == true
        )

        let helper = RuntimeInteractiveCapabilityContract(
            snapshot: helperSnapshot()
        )
        XCTAssertEqual(
            helper.availableOperations,
            [.inspect, .stats, .logsFollow]
        )
        XCTAssertTrue(
            helper.unavailableReasons[.attach]?.contains("does not expose") == true
        )
    }

    func testAppleContainerInvocationUsesExactStructuredCommands() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("copy".utf8).write(to: root.appendingPathComponent("input.bin"))

        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .exec(
                    resourceIdentifier: managedIdentifier,
                    arguments: ["/usr/bin/printf", "--", "hello"],
                    interactive: true,
                    tty: true,
                    workingDirectory: "/work"
                )
            ).arguments,
            [
                "exec",
                "--interactive",
                "--tty",
                "--workdir",
                "/work",
                managedIdentifier,
                "/usr/bin/printf",
                "--",
                "hello"
            ]
        )
        XCTAssertThrowsError(
            try AppleContainerInteractiveInvocation(
                operation: .attach(
                    resourceIdentifier: managedIdentifier,
                    interactive: true,
                    tty: true
                )
            )
        ) { error in
            guard case .capabilityUnavailable(let operation, let reason) =
                    error as? RuntimeInteractiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .attach)
            XCTAssertTrue(reason.contains("outside the Hostwright saga"))
        }
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .inspect(resourceIdentifier: managedIdentifier)
            ).arguments,
            ["inspect", managedIdentifier]
        )
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .stats(resourceIdentifier: managedIdentifier)
            ).arguments,
            ["stats", managedIdentifier, "--no-stream", "--format", "json"]
        )
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .logsFollow(resourceIdentifier: managedIdentifier, tail: 50_000)
            ).arguments,
            ["logs", "--follow", "-n", "10000", managedIdentifier]
        )
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .copyIn(
                    resourceIdentifier: managedIdentifier,
                    hostRoot: root.path,
                    sourceRelativePath: "input.bin",
                    containerDestinationPath: "/tmp/input.bin"
                )
            ).arguments,
            [
                "copy",
                "provider-input",
                "\(managedIdentifier):/tmp/input.bin"
            ]
        )
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .copyOut(
                    resourceIdentifier: managedIdentifier,
                    containerSourcePath: "/tmp/output.bin",
                    hostRoot: root.path,
                    destinationRelativePath: "output.bin"
                )
            ).arguments,
            [
                "copy",
                "\(managedIdentifier):/tmp/output.bin",
                "."
            ]
        )
        XCTAssertEqual(
            try AppleContainerInteractiveInvocation(
                operation: .export(
                    resourceIdentifier: managedIdentifier,
                    hostRoot: root.path,
                    destinationRelativePath: "rootfs.tar"
                )
            ).arguments,
            [
                "export",
                "--output",
                "provider-output.tar",
                managedIdentifier
            ]
        )
    }

    func testInvalidIdentifiersArgumentsAndContainerTraversalFailBeforeLaunch() {
        XCTAssertThrowsError(
            try AppleContainerInteractiveInvocation(
                operation: .inspect(resourceIdentifier: "name")
            )
        )
        XCTAssertThrowsError(
            try AppleContainerInteractiveInvocation(
                operation: .exec(
                    resourceIdentifier: managedIdentifier,
                    arguments: [],
                    interactive: false,
                    tty: false,
                    workingDirectory: nil
                )
            )
        )
        XCTAssertThrowsError(try RuntimeContainerPathPolicy.validate("/work/../secret"))
        XCTAssertThrowsError(try RuntimeContainerPathPolicy.validate("relative"))
        XCTAssertNoThrow(try RuntimeContainerPathPolicy.validate("/work/output.bin"))
    }

    func testBinaryNDJSONFramesRoundTripAndEnforceChunkLimit() throws {
        let binary = Data((0..<(RuntimeStreamEnvelope.maximumChunkBytes + 17))
            .map { UInt8(truncatingIfNeeded: $0) })
        let frames = try RuntimeStreamEnvelope.chunks(
            binary,
            stream: .standardOutput,
            startingAt: 8
        )

        XCTAssertEqual(frames.map(\.sequence), [8, 9])
        XCTAssertEqual(frames.reduce(into: Data()) { $0.append($1.payload) }, binary)
        for frame in frames {
            let line = try frame.ndjsonLine()
            XCTAssertEqual(try RuntimeStreamEnvelope.decodeNDJSONLine(line), frame)
            XCTAssertLessThanOrEqual(frame.payload.count, 64 * 1_024)
            XCTAssertLessThanOrEqual(line.count, 8 * 1_024 * 1_024)
        }
        XCTAssertThrowsError(
            try RuntimeStreamEnvelope(
                sequence: 0,
                stream: .standardOutput,
                payload: Data(repeating: 0, count: 64 * 1_024 + 1)
            )
        )

        var unknownField = try frames[0].ndjsonLine()
        unknownField.removeLast()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unknownField) as? [String: Any]
        )
        object["unexpected"] = true
        XCTAssertThrowsError(
            try RuntimeStreamEnvelope.decodeNDJSONLine(
                try JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testStreamQueueAppliesOneMiBBackpressureUntilConsumerDrains() throws {
        let queue = RuntimeStreamBackpressureQueue()
        let envelope = try RuntimeStreamEnvelope(
            sequence: 1,
            stream: .standardOutput,
            payload: Data(repeating: 0x61, count: 64 * 1_024)
        )
        let frameSize = try envelope.ndjsonLine().count
        let capacity = RuntimeStreamBackpressureQueue.maximumQueuedBytes / frameSize
        for _ in 0..<capacity {
            try queue.enqueue(envelope)
        }

        let producerCompleted = DispatchSemaphore(value: 0)
        let producerError = LockedError()
        DispatchQueue.global().async {
            do {
                try queue.enqueue(envelope)
            } catch {
                producerError.set(error)
            }
            producerCompleted.signal()
        }
        XCTAssertEqual(
            producerCompleted.wait(timeout: .now() + 0.1),
            .timedOut
        )
        XCTAssertNotNil(try queue.dequeue())
        XCTAssertEqual(producerCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertNil(producerError.value)
        XCTAssertLessThanOrEqual(
            queue.bufferedByteCount,
            RuntimeStreamBackpressureQueue.maximumQueuedBytes
        )
        queue.close()
    }

    func testInputBackpressureTTYResizeAndSignalAllowlist() {
        let control = RuntimeInteractiveProcessControl()
        let chunk = Data(repeating: 0x42, count: 64 * 1_024)
        for _ in 0..<16 {
            XCTAssertTrue(control.sendInput(chunk))
        }
        XCTAssertFalse(control.sendInput(chunk))
        control.consumeInput(chunk.count)
        XCTAssertTrue(control.sendInput(chunk))

        XCTAssertTrue(control.resizeTTY(columns: 160, rows: 50))
        XCTAssertFalse(control.resizeTTY(columns: 0, rows: 50))
        XCTAssertTrue(control.forward(signal: SIGINT))
        XCTAssertFalse(control.forward(signal: SIGKILL))
    }

    func testDescriptorConfinementRejectsTraversalAndSymlinkSwap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )
        let file = nested.appendingPathComponent("data.bin")
        try Data("safe".utf8).write(to: file)

        let confined = try RuntimeConfinedHostPath(
            root: root.path,
            relativePath: "nested/data.bin",
            intent: .readExisting
        )
        XCTAssertNoThrow(try confined.revalidate())
        XCTAssertThrowsError(
            try RuntimeConfinedHostPath(
                root: root.path,
                relativePath: "../outside",
                intent: .writeFile
            )
        )

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        XCTAssertThrowsError(try confined.revalidate())
        XCTAssertThrowsError(
            try RuntimeConfinedHostPath(
                root: root.path,
                relativePath: "nested/data.bin",
                intent: .readExisting
            )
        )

        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try confined.revalidate())
    }

    func testPinnedFileStagingCrossesChildProcessBoundaryForCopyInAndExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.bin")
        try Data("safe-original".utf8).write(to: source)
        let copyInvocation = try AppleContainerInteractiveInvocation(
            operation: .copyIn(
                resourceIdentifier: managedIdentifier,
                hostRoot: root.path,
                sourceRelativePath: "input.bin",
                containerDestinationPath: "/tmp/input.bin"
            )
        )
        let copyDirectory = try XCTUnwrap(
            copyInvocation.workingDirectoryDescriptor
        )
        XCTAssertEqual(copyInvocation.arguments[1], "provider-input")
        XCTAssertTrue(copyInvocation.inheritedDescriptors.isEmpty)

        try FileManager.default.removeItem(at: source)
        try Data("unsafe-replacement".utf8).write(to: source)
        let copied = LockedData()
        let copyResult = try await POSIXRuntimeInteractiveProcessRunner().run(
            RuntimeInteractiveProcessRequest(
                executablePath: "/usr/bin/python3",
                arguments: [
                    "-c",
                    """
                    import subprocess, sys
                    subprocess.run(["/bin/cat", sys.argv[1]], check=True)
                    """,
                    copyInvocation.arguments[1]
                ],
                workingDirectoryDescriptor: copyDirectory,
                interactive: false,
                tty: false,
                timeoutMilliseconds: 2_000
            ),
            control: RuntimeInteractiveProcessControl()
        ) { chunk in
            if chunk.stream == .standardOutput {
                copied.append(chunk.data)
            }
        }

        XCTAssertEqual(copyResult.exitStatus, 0)
        XCTAssertEqual(copied.value, Data("safe-original".utf8))

        let archive = tar(entries: [
            ("payload.txt", UInt8(ascii: "0"), "", Data("exported".utf8))
        ])
        let exportInvocation = try AppleContainerInteractiveInvocation(
            operation: .export(
                resourceIdentifier: managedIdentifier,
                hostRoot: root.path,
                destinationRelativePath: "rootfs.tar"
            )
        )
        let exportDirectory = try XCTUnwrap(
            exportInvocation.workingDirectoryDescriptor
        )
        var absentMetadata = stat()
        XCTAssertEqual(
            fstatat(
                exportDirectory,
                "provider-output.tar",
                &absentMetadata,
                AT_SYMLINK_NOFOLLOW
            ),
            -1
        )
        XCTAssertEqual(errno, ENOENT)
        XCTAssertTrue(exportInvocation.inheritedDescriptors.isEmpty)

        let exportResult = try await POSIXRuntimeInteractiveProcessRunner().run(
            RuntimeInteractiveProcessRequest(
                executablePath: "/usr/bin/python3",
                arguments: [
                    "-c",
                    """
                    import subprocess, sys
                    subprocess.run([
                        sys.executable,
                        "-c",
                        "import base64,sys; open(sys.argv[1], 'xb').write(base64.b64decode(sys.argv[2]))",
                        sys.argv[1],
                        sys.argv[2],
                    ], check=True)
                    """,
                    exportInvocation.arguments[2],
                    archive.base64EncodedString()
                ],
                workingDirectoryDescriptor: exportDirectory,
                interactive: false,
                tty: false,
                timeoutMilliseconds: 2_000
            ),
            control: RuntimeInteractiveProcessControl()
        ) { _ in }

        XCTAssertEqual(exportResult.exitStatus, 0)
        let exportedPath = try XCTUnwrap(exportInvocation.exportedArchivePath)
        try exportedPath.validateArchiveOutput()
        try exportedPath.finalizeOutput()
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("rootfs.tar")),
            archive
        )
    }

    func testExportNormalizesGuestRootLinksWithoutChangingOtherTarBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try RuntimeConfinedHostPath(
            root: root.path,
            relativePath: "rootfs.tar",
            intent: .writeFile
        )
        let stage = try XCTUnwrap(destination.workingDirectoryDescriptor)
        let unicodeCertificate =
            "ca-cert-NetLock_Arany_=Class_Gold=_Fo\u{030b}tanu\u{0301}si\u{0301}tva\u{0301}ny.pem"
        let longCertificateTarget =
            "usr/share/ca-certificates/mozilla/\(unicodeCertificate.dropFirst(8).dropLast(4)).crt"
        let absoluteLongCertificateTarget = "/\(longCertificateTarget)"
        let effectiveCertificateLink = "etc/ssl/certs/\(unicodeCertificate)"
        let appleRootFSArchive = tar(entries: [
            ("bin/", UInt8(ascii: "5"), "", Data()),
            ("bin/busybox", UInt8(ascii: "0"), "", Data("binary".utf8)),
            ("bin/arch", UInt8(ascii: "2"), "/bin/busybox", Data()),
            ("usr/", UInt8(ascii: "5"), "", Data()),
            ("usr/bin/", UInt8(ascii: "5"), "", Data()),
            ("usr/bin/tool", UInt8(ascii: "2"), "/bin/busybox", Data()),
            ("usr/bin/busybox-hard", UInt8(ascii: "1"), "/bin/busybox", Data()),
            (
                "etc/ssl/certs/PaxHeader/relative",
                UInt8(ascii: "x"),
                "",
                pax(records: [("linkpath", unicodeCertificate)])
            ),
            (
                "etc/ssl/certs/relative-placeholder",
                UInt8(ascii: "2"),
                "placeholder",
                Data()
            ),
            (
                "etc/ssl/certs/PaxHeader/absolute",
                UInt8(ascii: "x"),
                "",
                pax(records: [
                    ("path", effectiveCertificateLink),
                    ("linkpath", absoluteLongCertificateTarget)
                ])
            ),
            (
                "etc/ssl/certs/absolute-placeholder",
                UInt8(ascii: "2"),
                "placeholder",
                Data()
            ),
            (
                "usr/share/ca-certificates/PaxHeader/file",
                UInt8(ascii: "x"),
                "",
                pax(records: [("path", longCertificateTarget)])
            ),
            (
                "usr/share/ca-certificates/file-placeholder",
                UInt8(ascii: "0"),
                "",
                Data("certificate".utf8)
            )
        ])
        let output = openat(
            stage,
            "provider-output.tar",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(output, 0)
        let written = appleRootFSArchive.withUnsafeBytes {
            Darwin.write(output, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, appleRootFSArchive.count)
        close(output)

        try destination.validateArchiveOutput()
        try destination.finalizeOutput()

        let normalized = try Data(
            contentsOf: root.appendingPathComponent("rootfs.tar")
        )
        XCTAssertEqual(
            normalized,
            tar(entries: [
                ("bin/", UInt8(ascii: "5"), "", Data()),
                ("bin/busybox", UInt8(ascii: "0"), "", Data("binary".utf8)),
                ("bin/arch", UInt8(ascii: "2"), "busybox", Data()),
                ("usr/", UInt8(ascii: "5"), "", Data()),
                ("usr/bin/", UInt8(ascii: "5"), "", Data()),
                ("usr/bin/tool", UInt8(ascii: "2"), "../../bin/busybox", Data()),
                ("usr/bin/busybox-hard", UInt8(ascii: "1"), "bin/busybox", Data()),
                (
                    "etc/ssl/certs/PaxHeader/relative",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("linkpath", unicodeCertificate)])
                ),
                (
                    "etc/ssl/certs/relative-placeholder",
                    UInt8(ascii: "2"),
                    "placeholder",
                    Data()
                ),
                (
                    "etc/ssl/certs/PaxHeader/absolute",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [
                        ("path", effectiveCertificateLink),
                        ("linkpath", "../../../\(longCertificateTarget)")
                    ])
                ),
                (
                    "etc/ssl/certs/absolute-placeholder",
                    UInt8(ascii: "2"),
                    "../../../\(longCertificateTarget)",
                    Data()
                ),
                (
                    "usr/share/ca-certificates/PaxHeader/file",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("path", longCertificateTarget)])
                ),
                (
                    "usr/share/ca-certificates/file-placeholder",
                    UInt8(ascii: "0"),
                    "",
                    Data("certificate".utf8)
                )
            ])
        )
        XCTAssertNoThrow(try RuntimeTarArchivePolicy.validate(normalized))
    }

    func testExportSynthesizesPAXWhenSafeRelativeLinkExceedsUstarField() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try RuntimeConfinedHostPath(
            root: root.path,
            relativePath: "long-link.tar",
            intent: .writeFile
        )
        let stage = try XCTUnwrap(destination.workingDirectoryDescriptor)
        let entryPath =
            "etc/ssl/certs/ca-cert-Autoridad_de_Certificacion_Firmaprofesional_CIF_A62634068.pem"
        let absoluteTarget =
            "/usr/share/ca-certificates/mozilla/Autoridad_de_Certificacion_Firmaprofesional_CIF_A62634068.crt"
        let normalizedTarget =
            "../../../usr/share/ca-certificates/mozilla/Autoridad_de_Certificacion_Firmaprofesional_CIF_A62634068.crt"
        XCTAssertLessThanOrEqual(absoluteTarget.utf8.count, 100)
        XCTAssertGreaterThan(normalizedTarget.utf8.count, 100)
        let appleArchive = tar(entries: [
            ("etc/ssl/certs/", UInt8(ascii: "5"), "", Data()),
            (entryPath, UInt8(ascii: "2"), absoluteTarget, Data())
        ])
        let output = openat(
            stage,
            "provider-output.tar",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(output, 0)
        let written = appleArchive.withUnsafeBytes {
            Darwin.write(output, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, appleArchive.count)
        close(output)

        try destination.validateArchiveOutput()
        try destination.finalizeOutput()

        let normalized = try Data(
            contentsOf: root.appendingPathComponent("long-link.tar")
        )
        XCTAssertEqual(normalized.count, appleArchive.count + 1_024)
        XCTAssertNoThrow(try RuntimeTarArchivePolicy.validate(normalized))
        XCTAssertEqual(normalized[512 + 156], UInt8(ascii: "x"))
        XCTAssertNotNil(
            Data(normalized[1_024..<1_536]).range(
                of: Data("linkpath=\(normalizedTarget)\n".utf8)
            )
        )
        XCTAssertEqual(normalized[1_536 + 156], UInt8(ascii: "2"))
        let fallbackLink = normalized[(1_536 + 157)..<(1_536 + 257)]
            .prefix { $0 != 0 }
        XCTAssertEqual(String(decoding: fallbackLink, as: UTF8.self), ".")
    }

    func testCopyOutputValidatesPinnedTreeBeforeExclusivePromotion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try RuntimeConfinedHostPath(
            root: root.path,
            relativePath: "output.bin",
            intent: .writeDestination
        )
        let stage = try XCTUnwrap(destination.workingDirectoryDescriptor)
        let output = openat(
            stage,
            "provider-output.bin",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(output, 0)
        let payload = Data("verified-copy".utf8)
        let written = payload.withUnsafeBytes {
            Darwin.write(output, $0.baseAddress, payload.count)
        }
        XCTAssertEqual(written, payload.count)
        close(output)

        try destination.validateCopyOutput()
        try destination.finalizeOutput()
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("output.bin")),
            payload
        )

        let unsafe = try RuntimeConfinedHostPath(
            root: root.path,
            relativePath: "unsafe.bin",
            intent: .writeDestination
        )
        let unsafeStage = try XCTUnwrap(unsafe.workingDirectoryDescriptor)
        XCTAssertEqual(
            symlinkat("/etc/passwd", unsafeStage, "provider-output.bin"),
            0
        )
        XCTAssertThrowsError(try unsafe.validateCopyOutput())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("unsafe.bin").path
            )
        )
    }

    func testTarSafetyRejectsTraversalEscapingLinksAndSpecialEntries() throws {
        let safeArchive = tar(entries: [
            ("dir/", UInt8(ascii: "5"), "", Data()),
            ("dir/file", UInt8(ascii: "0"), "", Data("ok".utf8)),
            ("dir/link", UInt8(ascii: "2"), "../file", Data())
        ])
        XCTAssertNoThrow(try RuntimeTarArchivePolicy.validate(safeArchive))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("safe.tar")
        try safeArchive.write(to: archiveURL)
        XCTAssertNoThrow(try RuntimeTarArchivePolicy.validate(fileAt: archiveURL.path))
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("../escape", UInt8(ascii: "0"), "", Data())])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("file/", UInt8(ascii: "0"), "", Data())])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("dir//", UInt8(ascii: "5"), "", Data())])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("dir/./", UInt8(ascii: "5"), "", Data())])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [
                    ("dir/link", UInt8(ascii: "2"), "../../escape", Data())
                ])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [
                    ("dir/hardlink", UInt8(ascii: "1"), "../escape", Data())
                ])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("device", UInt8(ascii: "3"), "", Data())])
            )
        )
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(
                tar(entries: [("fifo", UInt8(ascii: "6"), "", Data())])
            )
        )
    }

    func testExportNormalizationRejectsMalformedOrEscapingGuestRootLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafeLinks = [
            "/../../etc/passwd",
            "//etc/passwd",
            "/bin/../etc/passwd"
        ]
        for (index, target) in unsafeLinks.enumerated() {
            let archiveURL = root.appendingPathComponent("unsafe-\(index).tar")
            try tar(entries: [
                ("usr/bin/link", UInt8(ascii: "2"), target, Data())
            ]).write(to: archiveURL)
            let descriptor = open(
                archiveURL.path,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertThrowsError(
                try RuntimeTarArchivePolicy.normalizeExportedArchive(
                    fileDescriptor: descriptor
                ),
                "Expected rejection for \(target)"
            )
            close(descriptor)
        }
    }

    func testPAXExtendedHeadersRejectMalformedUnsafeAndUnsupportedRecords() throws {
        var invalidUTF8 = Data("9 path=".utf8)
        invalidUTF8.append(0xff)
        invalidUTF8.append(0x0a)
        let rejectedArchives = [
            tar(entries: [
                ("PaxHeader/malformed", UInt8(ascii: "x"), "", Data("99 path=x\n".utf8)),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/duplicate",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("path", "safe"), ("path", "other")])
                ),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/unknown",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("SCHILY.xattr.security", "unsafe")])
                ),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                ("PaxHeader/utf8", UInt8(ascii: "x"), "", invalidUTF8),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/traversal",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("path", "../escape")])
                ),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/non-link",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("linkpath", "target")])
                ),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/oversized",
                    UInt8(ascii: "x"),
                    "",
                    Data(repeating: 0x61, count: 64 * 1_024 + 1)
                ),
                ("file", UInt8(ascii: "0"), "", Data())
            ]),
            tar(entries: [
                (
                    "PaxHeader/orphan",
                    UInt8(ascii: "x"),
                    "",
                    pax(records: [("path", "safe")])
                )
            ]),
            tar(entries: [
                ("GlobalPax", UInt8(ascii: "g"), "", Data("safe".utf8))
            ]),
            tar(entries: [
                ("LongName", UInt8(ascii: "L"), "", Data("safe".utf8))
            ])
        ]
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, archive) in rejectedArchives.enumerated() {
            XCTAssertThrowsError(
                try RuntimeTarArchivePolicy.validate(archive),
                "Expected in-memory PAX rejection for fixture \(index)"
            )
            let archiveURL = root.appendingPathComponent("pax-\(index).tar")
            try archive.write(to: archiveURL)
            XCTAssertThrowsError(
                try RuntimeTarArchivePolicy.validate(fileAt: archiveURL.path),
                "Expected file PAX rejection for fixture \(index)"
            )
        }
    }

    func testTarSafetyRejectsInvalidChecksumsAndTerminators() throws {
        let safeArchive = tar(entries: [
            ("dir/file", UInt8(ascii: "0"), "", Data("ok".utf8))
        ])
        var corruptedHeader = safeArchive
        corruptedHeader[0] ^= 0x01
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(corruptedHeader)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeInteractiveError,
                .unsafeArchive("The tar header checksum does not match.")
            )
        }

        var missingChecksum = safeArchive
        missingChecksum.replaceSubrange(148..<156, with: repeatElement(0, count: 8))
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(missingChecksum)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeInteractiveError,
                .unsafeArchive("The tar header has an invalid checksum.")
            )
        }

        let singleTerminator = Data(safeArchive.dropLast(512))
        XCTAssertThrowsError(try RuntimeTarArchivePolicy.validate(singleTerminator))

        var dataAfterTerminator = safeArchive
        dataAfterTerminator[dataAfterTerminator.count - 1] = 0x01
        XCTAssertThrowsError(try RuntimeTarArchivePolicy.validate(dataAfterTerminator))

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("corrupt.tar")
        try corruptedHeader.write(to: archiveURL)
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(fileAt: archiveURL.path)
        )
        try dataAfterTerminator.write(to: archiveURL)
        XCTAssertThrowsError(
            try RuntimeTarArchivePolicy.validate(fileAt: archiveURL.path)
        )
    }

    func testInspectEmitsNormalizedHostwrightEnvelopeFromProductionAppleJSON() async throws {
        let evidence = try productionStructuredEvidence()
        let runner = RecordingInteractiveProcessRunner(output: Data())
        let executor = AppleContainerInteractiveExecutor(
            executableResolver: InteractiveExecutableResolver(),
            processRunner: runner,
            structuredReader: FixedInteractiveStructuredReader(
                inventoryValue: evidence.inventory,
                usageValue: evidence.usage
            )
        )
        let frames = LockedFrames()

        let result = try await executor.execute(
            .inspect(resourceIdentifier: productionManagedIdentifier),
            capabilitySnapshot: snapshot(),
            timeoutMilliseconds: 1_000
        ) { frame in
            frames.append(frame)
        }

        XCTAssertEqual(result.operation, .inspect)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(runner.runCount, 0)
        let data = frames.payload(for: .standardOutput)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "capabilitySHA256",
                "container",
                "inventorySHA256",
                "providerID",
                "schemaVersion"
            ]
        )
        XCTAssertEqual(object["providerID"] as? String, "apple-container-cli")
        XCTAssertEqual(
            object["capabilitySHA256"] as? String,
            snapshot().canonicalSHA256
        )
        XCTAssertEqual(
            object["inventorySHA256"] as? String,
            evidence.inventory.semanticSHA256
        )
        let container = try XCTUnwrap(object["container"] as? [String: Any])
        XCTAssertEqual(
            container["runtimeID"] as? String,
            productionManagedIdentifier
        )
        XCTAssertEqual(container["lifecycle"] as? String, "running")
        XCTAssertNil(container["configuration"])
        XCTAssertFalse(data.contains(Data("fixture-secret".utf8)))
        XCTAssertTrue(data.contains(Data("[REDACTED]".utf8)))
        XCTAssertTrue(frames.values.suffix(2).allSatisfy(\.endOfStream))
    }

    func testStatsEmitsNormalizedHostwrightEnvelopeFromProductionAppleJSON() async throws {
        let evidence = try productionStructuredEvidence()
        let runner = RecordingInteractiveProcessRunner(output: Data())
        let executor = AppleContainerInteractiveExecutor(
            executableResolver: InteractiveExecutableResolver(),
            processRunner: runner,
            structuredReader: FixedInteractiveStructuredReader(
                inventoryValue: evidence.inventory,
                usageValue: evidence.usage
            )
        )
        let frames = LockedFrames()

        let result = try await executor.execute(
            .stats(resourceIdentifier: productionManagedIdentifier),
            capabilitySnapshot: snapshot(),
            timeoutMilliseconds: 1_000
        ) { frame in
            frames.append(frame)
        }

        XCTAssertEqual(result.operation, .stats)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(runner.runCount, 0)
        let data = frames.payload(for: .standardOutput)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "blockReadBytes",
                "blockWriteBytes",
                "capabilitySHA256",
                "cpuUsageMicroseconds",
                "memoryLimitBytes",
                "memoryUsageBytes",
                "networkReceiveBytes",
                "networkTransmitBytes",
                "processCount",
                "providerID",
                "resourceIdentifier",
                "schemaVersion"
            ]
        )
        XCTAssertEqual(object["providerID"] as? String, "apple-container-cli")
        XCTAssertEqual(
            object["resourceIdentifier"] as? String,
            productionManagedIdentifier
        )
        XCTAssertEqual(object["cpuUsageMicroseconds"] as? Int, 1_100)
        XCTAssertNil(object["cpuUsageUsec"])
        XCTAssertEqual(object["processCount"] as? Int, 3)
        XCTAssertTrue(frames.values.suffix(2).allSatisfy(\.endOfStream))
    }

    func testStructuredReaderRejectsMismatchedNormalizedIdentity() async throws {
        let evidence = try productionStructuredEvidence()
        var duplicateObjects = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    try fixture(
                        "apple-container-1.1.0-inventory-containers.json"
                    ).utf8
                )
            ) as? [[String: Any]]
        )
        duplicateObjects.append(try XCTUnwrap(duplicateObjects.first))
        let duplicateData = try JSONSerialization.data(
            withJSONObject: duplicateObjects
        )
        XCTAssertThrowsError(
            try productionStructuredEvidence(
                containers: String(decoding: duplicateData, as: UTF8.self)
            )
        )

        let mismatchedUsage = RuntimeResourceUsageSnapshot(
            resourceIdentifier: managedIdentifier,
            cpuUsageMicroseconds: evidence.usage.cpuUsageMicroseconds,
            memoryUsageBytes: evidence.usage.memoryUsageBytes,
            memoryLimitBytes: evidence.usage.memoryLimitBytes,
            networkReceiveBytes: evidence.usage.networkReceiveBytes,
            networkTransmitBytes: evidence.usage.networkTransmitBytes,
            blockReadBytes: evidence.usage.blockReadBytes,
            blockWriteBytes: evidence.usage.blockWriteBytes,
            processCount: evidence.usage.processCount
        )
        do {
            _ = try await AppleContainerInteractiveExecutor(
                executableResolver: InteractiveExecutableResolver(),
                processRunner: RecordingInteractiveProcessRunner(output: Data()),
                structuredReader: FixedInteractiveStructuredReader(
                    inventoryValue: evidence.inventory,
                    usageValue: mismatchedUsage
                )
            ).execute(
                .stats(resourceIdentifier: productionManagedIdentifier),
                capabilitySnapshot: snapshot(),
                timeoutMilliseconds: 1_000
            ) { _ in }
            XCTFail("Expected mismatched stats identity rejection.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeInteractiveError,
                .invalidStructuredOutput
            )
        }
    }

    func testLargeStructuredOutputReservesEverySequenceExactlyOnce() async throws {
        var objects = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    try fixture(
                        "apple-container-1.1.0-inventory-containers.json"
                    ).utf8
                )
            ) as? [[String: Any]]
        )
        var managed = try XCTUnwrap(objects.first)
        var configuration = try XCTUnwrap(
            managed["configuration"] as? [String: Any]
        )
        var labels = try XCTUnwrap(
            configuration["labels"] as? [String: Any]
        )
        for index in 0..<80 {
            labels[String(format: "qualified-padding-%03d", index)] =
                String(repeating: "a", count: 1_000)
        }
        configuration["labels"] = labels
        managed["configuration"] = configuration
        objects[0] = managed
        let paddedData = try JSONSerialization.data(
            withJSONObject: objects
        )
        let evidence = try productionStructuredEvidence(
            containers: String(decoding: paddedData, as: UTF8.self)
        )
        let frames = LockedFrames()
        let result = try await AppleContainerInteractiveExecutor(
            executableResolver: InteractiveExecutableResolver(),
            processRunner: RecordingInteractiveProcessRunner(output: Data()),
            structuredReader: FixedInteractiveStructuredReader(
                inventoryValue: evidence.inventory,
                usageValue: evidence.usage
            )
        ).execute(
            .inspect(resourceIdentifier: productionManagedIdentifier),
            capabilitySnapshot: snapshot(),
            timeoutMilliseconds: 1_000
        ) { frames.append($0) }

        XCTAssertGreaterThan(
            frames.values.filter { !$0.endOfStream }.count,
            1
        )
        XCTAssertEqual(
            frames.values.map(\.sequence),
            Array(0..<UInt64(frames.values.count))
        )
        XCTAssertEqual(result.emittedFrameCount, frames.values.count)
        XCTAssertTrue(frames.values.suffix(2).allSatisfy(\.endOfStream))
    }

    func testSlowOutputSinkCannotBlockTimeoutAndProcessCleanupDecision() async throws {
        let sinkStarted = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let runnerFinished = DispatchSemaphore(value: 0)
        let runner = TimeoutAfterOutputInteractiveProcessRunner(
            runnerFinished: runnerFinished
        )
        let identifier = managedIdentifier
        let capability = snapshot()
        let task = Task {
            try await AppleContainerInteractiveExecutor(
                executableResolver: InteractiveExecutableResolver(),
                processRunner: runner
            ).execute(
                .exec(
                    resourceIdentifier: identifier,
                    arguments: ["/bin/true"],
                    interactive: false,
                    tty: false,
                    workingDirectory: nil
                ),
                capabilitySnapshot: capability,
                timeoutMilliseconds: 1_000
            ) { _ in
                sinkStarted.signal()
                _ = releaseSink.wait(timeout: .now() + 2)
            }
        }

        XCTAssertEqual(sinkStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(runnerFinished.wait(timeout: .now() + 5), .success)
        releaseSink.signal()
        do {
            _ = try await task.value
            XCTFail("Expected timeout.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeInteractiveError,
                .processTimedOut
            )
        }
    }

    func testPOSIXRunnerStreamsBinaryInputAndClosesStdin() async throws {
        let control = RuntimeInteractiveProcessControl()
        let input = Data([0x00, 0xff, 0x41, 0x0a])
        XCTAssertTrue(control.sendInput(input))
        control.finishInput()
        let output = LockedData()

        let result = try await POSIXRuntimeInteractiveProcessRunner().run(
            RuntimeInteractiveProcessRequest(
                executablePath: "/bin/cat",
                arguments: [],
                interactive: true,
                tty: false,
                timeoutMilliseconds: 2_000
            ),
            control: control
        ) { chunk in
            if chunk.stream == .standardOutput {
                output.append(chunk.data)
            }
        }

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(output.value, input)
    }

    func testPOSIXRunnerCancellationReapsProcessGroup() async throws {
        let control = RuntimeInteractiveProcessControl()
        let processID = LockedPID()
        let output = LockedData()
        let task = Task {
            try await POSIXRuntimeInteractiveProcessRunner().run(
                RuntimeInteractiveProcessRequest(
                    executablePath: "/usr/bin/python3",
                    arguments: [
                        "-c",
                        """
                        import subprocess, time
                        child = subprocess.Popen(["/bin/sleep", "30"])
                        print(child.pid, flush=True)
                        time.sleep(30)
                        """
                    ],
                    interactive: false,
                    tty: false,
                    timeoutMilliseconds: 60_000,
                    onLaunch: { processID.set($0) }
                ),
                control: control
            ) { chunk in
                if chunk.stream == .standardOutput {
                    output.append(chunk.data)
                }
            }
        }
        for _ in 0..<200 where processID.value == nil || childPID(from: output.value) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let launchedProcessID = try XCTUnwrap(processID.value)
        let launchedChildID = try XCTUnwrap(childPID(from: output.value))
        control.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertEqual(error as? RuntimeInteractiveError, .processCancelled)
        }
        XCTAssertEqual(kill(-launchedProcessID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(kill(launchedChildID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private var managedIdentifier: String {
        RuntimeServiceIdentity(
            projectName: "phase04",
            serviceName: "web"
        ).managedResourceIdentifier
    }

    private var productionManagedIdentifier: String {
        RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api"
        ).managedResourceIdentifier
    }

    private func productionStructuredEvidence(
        containers: String? = nil
    ) throws -> (
        inventory: RuntimeInventory,
        usage: RuntimeResourceUsageSnapshot
    ) {
        let stats = try fixture("apple-container-1.1.0-stats.json")
        let inventory = try AppleContainerInventoryParser.parse(
            outputs: AppleContainerInventoryOutputs(
                version: try fixture("apple-container-1.1.0-version.txt"),
                systemStatus: try fixture(
                    "apple-container-1.1.0-system-status.json"
                ),
                containers: try containers ?? fixture(
                    "apple-container-1.1.0-inventory-containers.json"
                ),
                images: try fixture("apple-container-1.1.0-image-list.json"),
                networks: try fixture(
                    "apple-container-1.1.0-network-list.json"
                ),
                volumes: try fixture(
                    "apple-container-1.1.0-volume-list.json"
                ),
                machines: try fixture(
                    "apple-container-1.1.0-machine-list.json"
                ),
                statsByContainerID: [productionManagedIdentifier: stats]
            )
        )
        let usage = try AppleContainerStatsParser.parse(
            stats,
            expectedResourceIdentifier: productionManagedIdentifier
        )
        return (inventory, usage)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil)
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func snapshot(
        providerID: RuntimeProviderID = .appleContainerCLI
    ) -> RuntimeCapabilitySnapshot {
        let components: [RuntimeProviderComponent]
        if providerID == .appleContainerCLI {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: String(repeating: "a", count: 64)
                )
            ]
        } else {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerizationHelper,
                    version: "0.0.2",
                    build: "release",
                    fingerprint: String(repeating: "a", count: 64)
                ),
                RuntimeProviderComponent(
                    identifier: .containerizationHelperProtocolV1,
                    version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                    build: "release",
                    fingerprint: String(repeating: "b", count: 64)
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerizationFramework,
                    version:
                        RuntimeProviderCapabilityContract
                            .containerizationFrameworkVersion,
                    build: "release",
                    fingerprint: String(repeating: "c", count: 64)
                )
            ]
        }
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: providerID,
                components: components,
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A1",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
    }

    private func helperSnapshot() -> RuntimeCapabilitySnapshot {
        snapshot(providerID: .appleContainerization)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func childPID(from data: Data) -> pid_t? {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int32(value), parsed > 0 else { return nil }
        return pid_t(parsed)
    }

    private func tar(
        entries: [(path: String, type: UInt8, link: String, payload: Data)]
    ) -> Data {
        var archive = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            write(entry.path, to: &header, at: 0, maximumBytes: 100)
            write("0000644", to: &header, at: 100, maximumBytes: 8)
            write("0000000", to: &header, at: 108, maximumBytes: 8)
            write("0000000", to: &header, at: 116, maximumBytes: 8)
            write(
                String(format: "%011o", entry.payload.count),
                to: &header,
                at: 124,
                maximumBytes: 12
            )
            header[156] = entry.type
            write(entry.link, to: &header, at: 157, maximumBytes: 100)
            header.replaceSubrange(148..<156, with: repeatElement(0x20, count: 8))
            let checksum = header.reduce(0) { $0 + UInt64($1) }
            write(
                String(format: "%06llo", checksum),
                to: &header,
                at: 148,
                maximumBytes: 7
            )
            header[154] = 0
            header[155] = 0x20
            archive.append(header)
            archive.append(entry.payload)
            let padding = (512 - entry.payload.count % 512) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: 1_024))
        return archive
    }

    private func pax(records: [(key: String, value: String)]) -> Data {
        var payload = Data()
        for record in records {
            let body = Data("\(record.key)=\(record.value)\n".utf8)
            var length = body.count + 2
            while true {
                let candidate = String(length).utf8.count + 1 + body.count
                if candidate == length {
                    break
                }
                length = candidate
            }
            payload.append(Data("\(length) ".utf8))
            payload.append(body)
        }
        return payload
    }

    private func write(
        _ value: String,
        to data: inout Data,
        at offset: Int,
        maximumBytes: Int
    ) {
        let bytes = Array(value.utf8.prefix(maximumBytes - 1))
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

private final class RecordingInteractiveProcessRunner:
    RuntimeInteractiveProcessRunning,
    @unchecked Sendable {
    private let lock = NSLock()
    private let output: Data
    private var recordedArguments: [String] = []
    private var count = 0

    init(output: Data) {
        self.output = output
    }

    func run(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) async throws -> RuntimeInteractiveProcessResult {
        lock.withLock {
            count += 1
            recordedArguments = request.arguments
        }
        if !output.isEmpty {
            var offset = 0
            while offset < output.count {
                let upperBound = min(
                    offset + RuntimeStreamEnvelope.maximumChunkBytes,
                    output.count
                )
                try sink(
                    RuntimeRawStreamChunk(
                        stream: .standardOutput,
                        data: Data(output[offset..<upperBound])
                    )
                )
                offset = upperBound
            }
        }
        return RuntimeInteractiveProcessResult(
            exitStatus: 0,
            terminationSignal: nil,
            standardErrorTail: ""
        )
    }

    var runCount: Int {
        lock.withLock { count }
    }

    var arguments: [String] {
        lock.withLock { recordedArguments }
    }
}

private struct FixedInteractiveStructuredReader:
    AppleContainerInteractiveStructuredReading {
    let inventoryValue: RuntimeInventory
    let usageValue: RuntimeResourceUsageSnapshot

    func inventory() async throws -> RuntimeInventory {
        inventoryValue
    }

    func resourceUsage(
        for resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot {
        usageValue
    }
}

private final class TimeoutAfterOutputInteractiveProcessRunner:
    RuntimeInteractiveProcessRunning,
    @unchecked Sendable {
    private let runnerFinished: DispatchSemaphore

    init(runnerFinished: DispatchSemaphore) {
        self.runnerFinished = runnerFinished
    }

    func run(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) async throws -> RuntimeInteractiveProcessResult {
        try sink(
            RuntimeRawStreamChunk(
                stream: .standardOutput,
                data: Data("output-before-timeout".utf8)
            )
        )
        runnerFinished.signal()
        throw RuntimeInteractiveError.processTimedOut
    }
}

private struct InteractiveExecutableResolver: RuntimeExecutableResolving {
    func resolveExecutable(named name: String) throws -> ResolvedRuntimeExecutable? {
        ResolvedRuntimeExecutable(name: name, path: "/usr/local/bin/container")
    }
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RuntimeStreamEnvelope] = []

    func append(_ frame: RuntimeStreamEnvelope) {
        lock.withLock { frames.append(frame) }
    }

    var values: [RuntimeStreamEnvelope] {
        lock.withLock { frames }
    }

    func payload(for stream: RuntimeStreamName) -> Data {
        lock.withLock {
            frames
                .filter { $0.stream == stream && !$0.endOfStream }
                .reduce(into: Data()) { $0.append($1.payload) }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        lock.withLock { data.append(value) }
    }

    var value: Data {
        lock.withLock { data }
    }
}

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?

    func set(_ value: pid_t) {
        lock.withLock { processID = value }
    }

    var value: pid_t? {
        lock.withLock { processID }
    }
}

private final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ value: Error) {
        lock.withLock { error = value }
    }

    var value: Error? {
        lock.withLock { error }
    }
}
