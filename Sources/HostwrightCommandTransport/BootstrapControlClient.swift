import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightCore
import HostwrightState
import Security

public enum BootstrapControlClientError: Error, Equatable, Sendable {
    case unsafeCompanion
    case launchFailed
    case deadlineExceeded
    case invalidResponse
}

public struct BootstrapControlClient: Sendable {
    public static let companionName = "hostwright-control"
    private static let codeRevocationFlag = UInt32(1) << 30

    typealias SubprocessRun = @Sendable (
        SecureSubprocessRequest,
        SecureExecutableIdentity
    ) throws -> SecureSubprocessResult

    public let companionPath: String
    private let companionIdentity: SecureExecutableIdentity
    private let runSubprocess: SubprocessRun

    public init(companionPath: String? = nil) throws {
        let resolvedPath = try companionPath ?? Self.defaultCompanionPath()
        let executableIdentity = try Self.validateCompanion(path: resolvedPath)
        let codeIdentity = try Self.validateCodeIdentity(path: resolvedPath)
        self.companionPath = resolvedPath
        self.companionIdentity = executableIdentity
        self.runSubprocess = { request, identity in
            try SecureSubprocessRunner().run(
                request,
                expectedExecutable: identity,
                suspendedProcessValidator: { processID in
                    try Self.validateSpawnedCompanion(
                        processID: processID,
                        expectedIdentity: codeIdentity
                    )
                }
            )
        }
    }

    init(
        testingCompanionPath companionPath: String,
        identity: SecureExecutableIdentity,
        runSubprocess: @escaping SubprocessRun
    ) {
        self.companionPath = companionPath
        self.companionIdentity = identity
        self.runSubprocess = runSubprocess
    }

    public func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
        guard let route = try CLIControlRoute.validate(
            request: request,
            expectedTransport: .bootstrapAPI
        ), route.transport == .bootstrapAPI else {
            throw BootstrapControlClientError.invalidResponse
        }
        let requestData = try ControlPlaneCanonicalJSON.encode(request)
        let timeout = min(
            request.timeoutMilliseconds ?? ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
            ControlPlaneContract.maximumUnaryDeadlineMilliseconds
        )
        let subprocessRequest = SecureSubprocessRequest(
            executablePath: companionIdentity.path,
            arguments: ["--bootstrap"],
            environment: try Self.bootstrapEnvironment(),
            workingDirectory: "/",
            standardInput: requestData,
            timeoutMilliseconds: timeout,
            terminationGraceMilliseconds: 1_000,
            maximumStandardOutputBytes: ControlPlaneContract.maximumResponseOrFrameBytes,
            maximumStandardErrorBytes: ControlPlaneContract.maximumRequestBytes,
            maximumStandardInputBytes: ControlPlaneContract.maximumRequestBytes
        )
        let result: SecureSubprocessResult
        do {
            result = try runSubprocess(subprocessRequest, companionIdentity)
        } catch SecureSubprocessError.timedOut {
            throw BootstrapControlClientError.deadlineExceeded
        } catch SecureSubprocessError.executableChanged {
            throw BootstrapControlClientError.unsafeCompanion
        } catch SecureSubprocessError.outputLimitExceeded {
            throw BootstrapControlClientError.invalidResponse
        } catch {
            throw BootstrapControlClientError.launchFailed
        }
        let responseData = result.standardOutput
        guard result.exitStatus == 0,
              result.terminationSignal == nil,
              result.standardError.isEmpty,
              !result.standardOutputTruncated,
              !result.standardErrorTruncated,
              !responseData.isEmpty,
              responseData.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
            throw BootstrapControlClientError.invalidResponse
        }
        let response = try Phase09StrictDecoder.decode(
            ControlResponseEnvelope.self,
            from: responseData,
            allowedKeys: [
                "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
                "operationRef", "result", "error",
            ],
            requiredKeys: [
                "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
            ]
        )
        try response.validate()
        guard response.requestID == request.requestID else {
            throw BootstrapControlClientError.invalidResponse
        }
        return response
    }

    static func defaultCompanionPath() throws -> String {
        var required: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &required)
        guard required > 0 else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        var buffer = [CChar](repeating: 0, count: Int(required))
        guard _NSGetExecutablePath(&buffer, &required) == 0,
              let resolved = realpath(buffer, nil) else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved))
            .deletingLastPathComponent()
        return directory.appendingPathComponent(companionName).path
    }

    static func validateCompanion(path: String) throws -> SecureExecutableIdentity {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid() || status.st_uid == 0,
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              access(path, X_OK) == 0 else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        let identity: SecureExecutableIdentity
        do {
            identity = try SecureExecutableResolver.verify(path: path)
        } catch {
            throw BootstrapControlClientError.unsafeCompanion
        }
        guard identity.path == path else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        _ = try validateCodeIdentity(path: path)
        do {
            try SecureExecutableResolver.verifyUnchanged(identity)
        } catch {
            throw BootstrapControlClientError.unsafeCompanion
        }
        return identity
    }

    static func bootstrapEnvironment() throws -> [String: String] {
        var result = SecureSubprocessEnvironment.currentUser
        let source = ProcessInfo.processInfo.environment
        for name in [
            HostwrightLocalPathResolver.applicationSupportOverride,
            HostwrightLocalPathResolver.cacheOverride,
            HostwrightLocalPathResolver.logOverride,
            HostwrightLocalPathResolver.stateDatabaseOverride,
        ] {
            guard let value = source[name] else { continue }
            guard value.hasPrefix("/"), value.utf8.count <= 4_096,
                  !value.contains("\0"),
                  URL(fileURLWithPath: value).standardizedFileURL.path == value else {
                throw BootstrapControlClientError.unsafeCompanion
            }
            result[name] = value
        }
        return result
    }

    private static func validateCodeIdentity(path: String) throws -> CodeIdentity {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(),
            &candidate
        ) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(
                candidate,
                SecCSFlags(rawValue: kSecCSStrictValidate | codeRevocationFlag),
                nil
              ) == errSecSuccess else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            candidate,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
              let unique = values[kSecCodeInfoUnique] as? Data,
              !unique.isEmpty else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        let team = values[kSecCodeInfoTeamIdentifier] as? String
        let candidateHash = unique.map { String(format: "%02x", $0) }.joined()
        let validationMode: CodeValidationMode
        if let team {
            guard team == "993YC3JY4Q", signingIdentifier == companionName else {
                throw BootstrapControlClientError.unsafeCompanion
            }
            var requirement: SecRequirement?
            let source = "anchor apple generic and certificate leaf[subject.OU] = \"993YC3JY4Q\" and identifier \"hostwright-control\""
            guard SecRequirementCreateWithString(
                source as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(
                    candidate,
                    SecCSFlags(rawValue: kSecCSStrictValidate | codeRevocationFlag),
                    requirement
                  ) == errSecSuccess else {
                throw BootstrapControlClientError.unsafeCompanion
            }
            validationMode = .installedRequirement
        } else {
            guard isAdHocSourceIdentifier(
                signingIdentifier,
                base: companionName
            ) else {
                throw BootstrapControlClientError.unsafeCompanion
            }
            let resolution = try HostwrightLocalPathResolver.resolve()
            let state = try adHocCompanionState(
                resolution: resolution,
                candidateHash: candidateHash,
                signingIdentifier: signingIdentifier
            )
            guard state.pinned || (state.empty && permitsInitialAdHocBootstrap(path: path)) else {
                throw BootstrapControlClientError.unsafeCompanion
            }
            validationMode = .pinnedAdHoc
        }
        let identity = CodeIdentity(
            teamIdentifier: team,
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: candidateHash,
            validationMode: validationMode
        )
        try identity.validate()
        return identity
    }

    private static func adHocCompanionState(
        resolution: HostwrightLocalPathResolution,
        candidateHash: String,
        signingIdentifier: String
    ) throws -> (pinned: Bool, empty: Bool) {
        guard FileManager.default.fileExists(atPath: resolution.stateDatabasePath) else {
            return (false, true)
        }
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(localPathResolution: resolution)
        )
        let schema = try store.schemaVersion()
        guard (17...HostwrightContractVersions.stateSchema).contains(schema) else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        guard schema >= 18 else { return (false, true) }
        let identities = try store.controlIdentities.listIdentities()
        let pinned = identities.contains(where: {
            $0.userID == UInt32(geteuid())
              && $0.revokedAt == nil
              && $0.codeIdentity.validationMode == .pinnedAdHoc
              && $0.codeIdentity.teamIdentifier == nil
              && $0.codeIdentity.signingIdentifier == signingIdentifier
              && $0.codeIdentity.codeDirectoryHash == candidateHash
        })
        return (pinned, identities.isEmpty)
    }

    private static func permitsInitialAdHocBootstrap(path: String) -> Bool {
        guard (try? defaultCompanionPath()) == path,
              let installer = try? DarwinCurrentControlCodeIdentity.inspect(),
              installer.validationMode == .pinnedAdHoc,
              installer.teamIdentifier == nil,
              (installer.signingIdentifier == "dev.hostwright.cli"
                || isAdHocSourceIdentifier(installer.signingIdentifier, base: "hostwright")) else {
            return false
        }
        return true
    }

    static func isAdHocSourceIdentifier(_ value: String, base: String) -> Bool {
        value == base || value.range(
            of: "^\(NSRegularExpression.escapedPattern(for: base))-[a-f0-9]{40}$",
            options: .regularExpression
        ) != nil
    }

    static func validateSpawnedCompanion(
        processID: pid_t,
        expectedIdentity: CodeIdentity
    ) throws {
        let observed = try spawnedCodeIdentity(processID: processID)
        guard observed == expectedIdentity else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, attributes, SecCSFlags(), &dynamicCode
        ) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(
                dynamicCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | codeRevocationFlag),
                nil
              ) == errSecSuccess else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        if let team = observed.teamIdentifier {
            var requirement: SecRequirement?
            let source = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(expectedIdentity.signingIdentifier)\""
            guard SecRequirementCreateWithString(
                    source as CFString,
                    SecCSFlags(),
                    &requirement
                  ) == errSecSuccess,
                  let requirement,
                  SecCodeCheckValidity(
                    dynamicCode,
                    SecCSFlags(rawValue: kSecCSStrictValidate | codeRevocationFlag),
                    requirement
                  ) == errSecSuccess else {
                throw BootstrapControlClientError.unsafeCompanion
            }
        }
    }

    static func spawnedCodeIdentity(processID: pid_t) throws -> CodeIdentity {
        guard processID > 0 else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        ) == errSecSuccess, let dynamicCode else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String,
              let unique = values[kSecCodeInfoUnique] as? Data else {
            throw BootstrapControlClientError.unsafeCompanion
        }
        let observed = CodeIdentity(
            teamIdentifier: values[kSecCodeInfoTeamIdentifier] as? String,
            signingIdentifier: identifier,
            codeDirectoryHash: unique.map { String(format: "%02x", $0) }.joined(),
            validationMode: values[kSecCodeInfoTeamIdentifier] == nil
                ? .pinnedAdHoc : .installedRequirement
        )
        try observed.validate()
        return observed
    }
}
