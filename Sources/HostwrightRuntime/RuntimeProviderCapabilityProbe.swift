import Foundation

public enum RuntimeProviderCapabilityProbeError: Error, Equatable, Sendable {
    case executableUnavailable(String)
    case invalidResolvedExecutable(String)
    case invalidProcessResult(String)
    case invalidCLIIdentity
    case apiServiceUnavailable
    case invalidAPIServiceIdentity
    case invalidHostVersion
    case invalidHostBuild
    case unsupportedMacOSVersion(RuntimeProviderMacOSVersion)
    case unsupportedArchitecture(String)
    case helperHandshakeUnavailable
    case helperPeerIdentityUnavailable
    case helperPeerIdentityInvalid
    case helperProtocolUnsupported(Int)
    case helperHostMismatch
    case helperCapabilityDigestInvalid
    case helperCapabilityStale
    case invalidCapability([RuntimeProviderCompatibilityFinding])
}

public struct RuntimeContainerizationHelperCapabilityHandshake: Equatable, Sendable {
    public let protocolVersion: Int
    public let snapshot: RuntimeCapabilitySnapshot
    public let capabilitySHA256: String

    public init(
        protocolVersion: Int,
        snapshot: RuntimeCapabilitySnapshot,
        capabilitySHA256: String
    ) {
        self.protocolVersion = protocolVersion
        self.snapshot = snapshot
        self.capabilitySHA256 = capabilitySHA256
    }
}

public struct RuntimeContainerizationHelperCapabilityProbeInput: Equatable, Sendable {
    public let localHost: RuntimeProviderHostPlatform
    public let expectedUserID: UInt32
    public let peerIdentity: ContainerizationHelperPeerIdentity?
    public let handshake: RuntimeContainerizationHelperCapabilityHandshake?

    public init(
        localHost: RuntimeProviderHostPlatform,
        expectedUserID: UInt32,
        peerIdentity: ContainerizationHelperPeerIdentity?,
        handshake: RuntimeContainerizationHelperCapabilityHandshake?
    ) {
        self.localHost = localHost
        self.expectedUserID = expectedUserID
        self.peerIdentity = peerIdentity
        self.handshake = handshake
    }
}

public struct RuntimeProviderCapabilityProbe: Sendable {
    private static let swVersExecutableName = "sw_vers"
    private static let unameExecutableName = "uname"
    private static let maximumHostEvidenceBytes = 256

    private let executableResolver: RuntimeExecutableResolving
    private let processRunner: RuntimeProcessRunning
    private let timeout: RuntimeCommandTimeout

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.timeout = timeout
    }

    public func probeAppleContainerCLI() async throws -> RuntimeCapabilitySnapshot {
        try Task.checkCancellation()
        let executable = try resolvedExecutable(named: AppleContainerCommand.executableName)
        let versionSpec = AppleContainerCommand.spec(
            kind: .version,
            executable: executable,
            timeout: timeout
        )
        let versionResult = try await run(versionSpec)
        guard let cliIdentity = AppleContainerVersionParser.parseCLIIdentity(
            versionResult.standardOutput
        ) else {
            throw RuntimeProviderCapabilityProbeError.invalidCLIIdentity
        }
        let codec = try AppleContainerCLICodec.select(
            fromVersionOutput: versionResult.standardOutput
        )

        let statusSpec = AppleContainerCommand.spec(
            kind: .systemStatus,
            codec: codec,
            executable: executable,
            timeout: timeout
        )
        let statusResult = try await run(statusSpec)
        let serviceIdentity = try decodeAPIServiceIdentity(
            statusResult.standardOutput,
            versionOutput: versionResult.standardOutput,
            codec: codec,
            cliIdentity: cliIdentity
        )
        let host = try await probeHost()

        let snapshot = RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerCLI,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerCLI,
                        version: cliIdentity.version,
                        build: cliIdentity.build,
                        fingerprint: cliIdentity.commit
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerAPIService,
                        version: serviceIdentity.identity.version,
                        build: serviceIdentity.identity.build,
                        fingerprint: serviceIdentity.fullCommit
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: host,
            features: Self.appleContainerCLIFeatures
        )
        try requireValid(snapshot)
        return snapshot
    }

    public func probeContainerizationHelper(
        _ input: RuntimeContainerizationHelperCapabilityProbeInput
    ) throws -> RuntimeCapabilitySnapshot {
        try Task.checkCancellation()
        guard let handshake = input.handshake else {
            throw RuntimeProviderCapabilityProbeError.helperHandshakeUnavailable
        }
        guard let peerIdentity = input.peerIdentity else {
            throw RuntimeProviderCapabilityProbeError.helperPeerIdentityUnavailable
        }
        do {
            try ContainerizationHelperPeerIdentityPolicy(
                expectedUserID: input.expectedUserID
            ).validate(peerIdentity)
        } catch {
            throw RuntimeProviderCapabilityProbeError.helperPeerIdentityInvalid
        }
        guard handshake.protocolVersion == ContainerizationHelperProtocolV1.version else {
            throw RuntimeProviderCapabilityProbeError.helperProtocolUnsupported(
                handshake.protocolVersion
            )
        }
        guard Self.validSHA256(handshake.capabilitySHA256) else {
            throw RuntimeProviderCapabilityProbeError.helperCapabilityDigestInvalid
        }
        guard handshake.snapshot.host == input.localHost else {
            throw RuntimeProviderCapabilityProbeError.helperHostMismatch
        }
        try requireValid(handshake.snapshot)
        guard handshake.snapshot.descriptor.providerID == .appleContainerization else {
            throw RuntimeProviderCapabilityProbeError.invalidCapability([
                RuntimeProviderCompatibilityFinding(reason: .providerMismatch)
            ])
        }
        guard handshake.capabilitySHA256 == handshake.snapshot.canonicalSHA256 else {
            throw RuntimeProviderCapabilityProbeError.helperCapabilityStale
        }
        try Task.checkCancellation()
        return handshake.snapshot
    }

    public static let appleContainerCLIFeatures: [RuntimeProviderFeatureStatus] =
        RuntimeProviderFeature.knownValues.map { feature in
            switch feature {
            case .observation,
                 .lifecycle,
                 .processControl,
                 .streaming,
                 .images,
                 .cancellation,
                 .timeouts,
                 .errors,
                 .cleanup:
                RuntimeProviderFeatureStatus(
                    feature: feature,
                    state: .available,
                    reason: .implemented
                )
            case .networks, .storage:
                RuntimeProviderFeatureStatus(
                    feature: feature,
                    state: .unavailable,
                    reason: .notImplemented
                )
            default:
                preconditionFailure("Unknown runtime provider feature: \(feature.rawValue)")
            }
        }.sorted { $0.feature.rawValue < $1.feature.rawValue }

    private func probeHost() async throws -> RuntimeProviderHostPlatform {
        let swVers = try resolvedExecutable(named: Self.swVersExecutableName)
        let versionResult = try await run(
            hostSpec(
                executable: swVers,
                arguments: ["-productVersion"],
                purpose: "Read the exact macOS product version"
            )
        )
        guard let version = Self.parseMacOSVersion(versionResult.standardOutput) else {
            throw RuntimeProviderCapabilityProbeError.invalidHostVersion
        }
        guard version >= RuntimeProviderCapabilityContract.minimumMacOSVersion else {
            throw RuntimeProviderCapabilityProbeError.unsupportedMacOSVersion(version)
        }

        let buildResult = try await run(
            hostSpec(
                executable: swVers,
                arguments: ["-buildVersion"],
                purpose: "Read the exact macOS build version"
            )
        )
        guard let build = Self.parseHostBuild(buildResult.standardOutput) else {
            throw RuntimeProviderCapabilityProbeError.invalidHostBuild
        }

        let uname = try resolvedExecutable(named: Self.unameExecutableName)
        let architectureResult = try await run(
            hostSpec(
                executable: uname,
                arguments: ["-m"],
                purpose: "Read the exact host architecture"
            )
        )
        guard let architecture = Self.parseSingleLine(architectureResult.standardOutput) else {
            throw RuntimeProviderCapabilityProbeError.unsupportedArchitecture("invalid")
        }
        guard architecture == RuntimeProviderArchitecture.arm64.rawValue else {
            throw RuntimeProviderCapabilityProbeError.unsupportedArchitecture(architecture)
        }

        return RuntimeProviderHostPlatform(
            macOSVersion: version,
            macOSBuild: build,
            architecture: .arm64
        )
    }

    private func decodeAPIServiceIdentity(
        _ output: String,
        versionOutput: String,
        codec: AppleContainerCLICodec,
        cliIdentity: AppleContainerCLIIdentity
    ) throws -> (identity: AppleContainerCLIIdentity, fullCommit: String) {
        let readiness: RuntimeReadinessReport
        do {
            readiness = try codec.decodeSystemStatus(output, versionOutput: versionOutput)
        } catch {
            throw RuntimeProviderCapabilityProbeError.invalidAPIServiceIdentity
        }
        guard readiness.serviceState == .running else {
            throw RuntimeProviderCapabilityProbeError.apiServiceUnavailable
        }

        let data: Data
        do {
            data = try AppleContainerStructuredOutput.validatedJSONData(
                output,
                operation: "Apple container capability probe",
                maximumBytes: AppleContainerSystemStatusParser.maximumBytes
            )
        } catch {
            throw RuntimeProviderCapabilityProbeError.invalidAPIServiceIdentity
        }
        let payload: APIServicePayload
        do {
            payload = try JSONDecoder().decode(APIServicePayload.self, from: data)
        } catch {
            throw RuntimeProviderCapabilityProbeError.invalidAPIServiceIdentity
        }
        guard payload.status == "running",
              payload.apiServerAppName == "container-apiserver",
              let serviceIdentity = AppleContainerVersionParser.parseServiceIdentity(
                  payload.apiServerVersion
              ),
              serviceIdentity.version == cliIdentity.version,
              serviceIdentity.build == cliIdentity.build,
              payload.apiServerBuild == serviceIdentity.build,
              Self.fingerprintsMatch(cliIdentity.commit, payload.apiServerCommit) else {
            throw RuntimeProviderCapabilityProbeError.invalidAPIServiceIdentity
        }
        return (serviceIdentity, payload.apiServerCommit)
    }

    private func resolvedExecutable(named name: String) throws -> ResolvedRuntimeExecutable {
        try Task.checkCancellation()
        guard let executable = try executableResolver.resolveExecutable(named: name) else {
            throw RuntimeProviderCapabilityProbeError.executableUnavailable(name)
        }
        guard executable.name == name,
              executable.path.hasPrefix("/"),
              !executable.path.contains("\n") else {
            throw RuntimeProviderCapabilityProbeError.invalidResolvedExecutable(name)
        }
        return executable
    }

    private func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        try Task.checkCancellation()
        let result = try await processRunner.run(spec)
        try Task.checkCancellation()
        if result.wasCancelled {
            throw CancellationError()
        }
        guard !result.timedOut,
              result.spec == spec,
              spec.exitStatusPolicy.accepts(result.exitStatus) else {
            throw RuntimeProviderCapabilityProbeError.invalidProcessResult(spec.purpose)
        }
        return result
    }

    private func hostSpec(
        executable: ResolvedRuntimeExecutable,
        arguments: [String],
        purpose: String
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments,
            timeout: timeout,
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: purpose
        )
    }

    private func requireValid(_ snapshot: RuntimeCapabilitySnapshot) throws {
        let findings = RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot)
        guard findings.isEmpty else {
            throw RuntimeProviderCapabilityProbeError.invalidCapability(findings)
        }
    }

    private static func parseMacOSVersion(_ output: String) -> RuntimeProviderMacOSVersion? {
        guard let value = parseSingleLine(output) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let parsed = parts.compactMap { part -> Int? in
            guard part.range(of: "^(?:0|[1-9][0-9]*)$", options: .regularExpression) != nil else {
                return nil
            }
            return Int(part)
        }
        guard parsed.count == parts.count else { return nil }
        return RuntimeProviderMacOSVersion(
            major: parsed[0],
            minor: parsed[1],
            patch: parsed.count == 3 ? parsed[2] : 0
        )
    }

    private static func parseHostBuild(_ output: String) -> String? {
        guard let value = parseSingleLine(output),
              value.range(
                  of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func parseSingleLine(_ output: String) -> String? {
        guard !output.isEmpty,
              output.utf8.count <= maximumHostEvidenceBytes else {
            return nil
        }
        let value = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return value
    }

    private static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || (lhs != "unspecified" && rhs != "unspecified" && (
            lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        ))
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private struct APIServicePayload: Decodable {
        let status: String
        let apiServerVersion: String
        let apiServerBuild: String
        let apiServerCommit: String
        let apiServerAppName: String
    }
}
