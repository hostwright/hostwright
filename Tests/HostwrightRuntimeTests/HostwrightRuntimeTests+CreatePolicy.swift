import Foundation
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {
    func testCreateMissingServiceMutationPolicyAcceptsOnlyResolvedCreateSpecs() throws {
        let create = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(create))
        XCTAssertEqual(create.classification, .mutating)
        XCTAssertEqual(create.mutationKind, .createMissingService)
        XCTAssertEqual(create.arguments.prefix(3), ["create", "--name", identity.managedResourceIdentifier])
        XCTAssertTrue(create.arguments.contains("--label"))
        XCTAssertTrue(create.arguments.contains("\(RuntimeManagedResourceIdentity.managedLabel)=true"))
        XCTAssertTrue(create.arguments.contains("--publish"))
        XCTAssertTrue(create.arguments.contains("127.0.0.1:8080:8080"))
        XCTAssertFalse(create.arguments.contains("run"))
        XCTAssertFalse(create.arguments.contains("--rm"))

        let unresolved = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create"],
            classification: .mutating,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unresolved))

        let forbidden = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete"],
            classification: .forbidden,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(forbidden))

        let mislabeledDelete = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(mislabeledDelete))

        let nonHostwrightCreate = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "manual-api", "local/demo:latest"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(nonHostwrightCreate))
    }

    func testAppleCreateRendersResolvedTCPAndUDPPublishArguments()
        throws
    {
        let service = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            ports: [
                RuntimePortMapping(
                    hostPort: 49_153,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                ),
                RuntimePortMapping(
                    hostPort: 49_152,
                    containerPort: 5_353,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                ),
            ]
        )
        let arguments = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: service,
            mutationContext: mutationContext
        )
        let published = arguments.indices.compactMap {
            index -> String? in
            guard arguments[index] == "--publish",
                  arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        XCTAssertEqual(
            published,
            [
                "127.0.0.1:49152:5353/udp",
                "127.0.0.1:49153:8080",
            ]
        )

        let unresolved = DesiredRuntimeService(
            identity: identity,
            image: service.image,
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    allocation: .dynamic
                ),
            ]
        )
        XCTAssertThrowsError(
            try AppleContainerCommand.arguments(
                for: .createContainer,
                desiredService: unresolved,
                mutationContext: mutationContext
            )
        )
    }

    func testCreateMissingServiceMutationPolicyRejectsPreImageFlagsAndAllowsLiteralWorkloadArguments() throws {
        let valid = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )
        let imageIndex = valid.arguments.firstIndex(of: desiredService.image)!
        var unsafeImageArguments = valid.arguments
        unsafeImageArguments[imageIndex] = "--mount=src=/,dst=/host"
        let unsafeImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: unsafeImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unsafeImage)) { error in
            XCTAssertTrue(String(describing: error).contains("image"))
        }

        var badImageArguments = valid.arguments
        badImageArguments[imageIndex] = "-bad"
        let badImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: badImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(badImage))

        let literalWorkloadArguments = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: valid.arguments + ["--network", "literal-network", "--name", "literal-name"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                literalWorkloadArguments
            )
        )

        var preImageArguments = valid.arguments
        preImageArguments.insert("--future-flag", at: imageIndex)
        let unsupportedCreateOption = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: preImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                unsupportedCreateOption
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "unsupported option before its image"
                )
            )
        }
    }

    func testCreateMissingServiceMutationPolicyPermitsOnlyBoundedNonreservedUserLabels() throws {
        func spec(labels: [String: String]) throws -> RuntimeCommandSpec {
            try AppleContainerCommand.spec(
                kind: .createContainer,
                executable: ResolvedRuntimeExecutable(
                    name: "container",
                    path: "/usr/bin/container-fixture"
                ),
                desiredService: DesiredRuntimeService(
                    identity: identity,
                    image: desiredService.image,
                    command: desiredService.command,
                    labels: labels
                ),
                mutationContext: mutationContext
            )
        }

        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(labels: ["com.example.role": "api"])
            )
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(labels: ["dev.hostwright.unexpected": "true"])
            )
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(
                    labels: [
                        "com.example.oversized":
                            String(
                                repeating: "x",
                                count: RuntimeInventoryLimits.maximumStringBytes + 1
                            )
                    ]
                )
            )
        )
    }

    func testCreateMissingServiceMutationPolicyRejectsTamperedOwnershipBinding() throws {
        let valid = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(valid))

        var tamperedArguments = valid.arguments
        let resourceLabelPrefix = "\(RuntimeManagedResourceIdentity.resourceIdentifierLabel)="
        let labelIndex = tamperedArguments.firstIndex { $0.hasPrefix(resourceLabelPrefix) }!
        tamperedArguments[labelIndex] = "\(resourceLabelPrefix)\(RuntimeServiceIdentity(projectName: "other", serviceName: "api").managedResourceIdentifier)"
        let tampered = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: tamperedArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "tampered ownership fixture"
        )

        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(tampered)) { error in
            XCTAssertTrue(String(describing: error).contains("ownership labels bound to the exact container identifier"))
        }

        var duplicateNameArguments = valid.arguments
        let nameIndex = duplicateNameArguments.firstIndex(of: "--name")!
        duplicateNameArguments.insert(
            contentsOf: ["--name", RuntimeServiceIdentity(projectName: "other", serviceName: "api").managedResourceIdentifier],
            at: nameIndex + 2
        )
        let duplicateName = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: duplicateNameArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "duplicate name fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(duplicateName)) { error in
            XCTAssertTrue(String(describing: error).contains("exactly one"))
        }

        var duplicateLabelArguments = valid.arguments
        let firstLabelOptionIndex = try XCTUnwrap(
            duplicateLabelArguments.firstIndex(of: "--label")
        )
        duplicateLabelArguments.insert(
            contentsOf: [
                "--label",
                duplicateLabelArguments[firstLabelOptionIndex + 1]
            ],
            at: firstLabelOptionIndex + 2
        )
        let duplicateLabel = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: duplicateLabelArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "duplicate label fixture"
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                duplicateLabel
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate ownership label"))
        }
    }

    func testCreateMissingServiceEncodesBindAndTmpfsMountsByCodec() throws {
        let service = DesiredRuntimeService(
            identity: identity,
            image: desiredService.image,
            command: desiredService.command,
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/hostwright-input",
                    target: "/input",
                    kind: .bind,
                    access: .readOnly
                ),
                RuntimeMountReference(
                    source: "tmpfs",
                    target: "/tmp",
                    kind: .tmpfs,
                    access: .readWrite
                )
            ]
        )
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")

        let v11 = try AppleContainerCommand.spec(
            kind: .createContainer,
            codec: .v1_1_0,
            executable: executable,
            desiredService: service,
            mutationContext: mutationContext
        )
        XCTAssertTrue(v11.arguments.contains("--mount"))
        XCTAssertTrue(v11.arguments.contains("type=bind,source=/tmp/hostwright-input,target=/input,readonly"))
        XCTAssertTrue(v11.arguments.contains("--tmpfs"))
        XCTAssertTrue(v11.arguments.contains("/tmp"))

        let v10BindOnly = try AppleContainerCommand.spec(
            kind: .createContainer,
            codec: .v1_0_0,
            executable: executable,
            desiredService: DesiredRuntimeService(
                identity: identity,
                image: desiredService.image,
                command: desiredService.command,
                mounts: [
                    RuntimeMountReference(
                        source: "/tmp/hostwright-input",
                        target: "/input",
                        kind: .bind,
                        access: .readOnly
                    )
                ]
            ),
            mutationContext: mutationContext
        )
        XCTAssertTrue(v10BindOnly.arguments.contains("--volume"))
        XCTAssertTrue(v10BindOnly.arguments.contains("/tmp/hostwright-input:/input:ro"))

        XCTAssertThrowsError(
            try AppleContainerCommand.spec(
                kind: .createContainer,
                codec: .v1_0_0,
                executable: executable,
                desiredService: service,
                mutationContext: mutationContext
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("1.0.0 does not qualify tmpfs"))
        }
    }

    func testCreateMissingServiceRejectsMountDelimiterInjection() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        let service = DesiredRuntimeService(
            identity: identity,
            image: desiredService.image,
            command: desiredService.command,
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/bad,source",
                    target: "/input",
                    kind: .bind,
                    access: .readOnly
                )
            ]
        )

        XCTAssertThrowsError(
            try AppleContainerCommand.spec(
                kind: .createContainer,
                codec: .v1_1_0,
                executable: executable,
                desiredService: service,
                mutationContext: mutationContext
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("mount delimiters"))
        }
    }
}
