import Foundation
import HostwrightRegistry
import HostwrightSecrets

public enum RegistryCLIAction: Equatable, Sendable {
    case login(server: String, username: String)
    case logout(server: String)
    case status(server: String, repository: String?, actions: [String])
    case referrers(RegistryReferrerCLIAction)
    case trust(RegistryTrustCLIAction)
    case sbom(RegistrySBOMCLIAction)
    case vulnerability(RegistryVulnerabilityCLIAction)
    case provenance(RegistryProvenanceCLIAction)
}

public enum RegistryProvenanceCLIAction: Equatable, Sendable {
    case generate(
        archivePath: String,
        recordPath: String,
        manifestPath: String,
        serviceName: String?,
        server: String,
        repository: String,
        signerID: String,
        signingKeyReference: String
    )
    case verify(
        discoveryID: String,
        referrerDigest: String,
        manifestPath: String,
        serviceName: String?
    )
    case status(manifestPath: String, serviceName: String?)
    case resume(
        operationGroupID: String,
        confirmationPlanSHA256: String,
        signingKeyReference: String?
    )
}

enum RegistryProvenanceCLIParser {
    static func parse(arguments: [String]) throws
        -> RegistryCLIOptions
    {
        guard arguments.count >= 4,
              arguments[1] == "provenance",
              ["generate", "verify", "status", "resume"]
                .contains(arguments[2]) else {
            throw CLIUsageError(
                "registry provenance requires generate, verify, status, or resume and one exact target."
            )
        }
        let operation = arguments[2]
        let target = arguments[3]
        guard valid(target, maximumBytes: 4_096) else {
            throw CLIUsageError(
                "registry provenance target is invalid."
            )
        }

        var recordPath: String?
        var manifestPath: String?
        var serviceName: String?
        var server: String?
        var repository: String?
        var signerID: String?
        var signingKeyReference: String?
        var referrerDigest: String?
        var confirmationPlan: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 4
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--record":
                recordPath = try unique(
                    recordPath, arguments, &index, flag, 4_096
                )
            case "--manifest":
                manifestPath = try unique(
                    manifestPath, arguments, &index, flag, 4_096
                )
            case "--service":
                serviceName = try unique(
                    serviceName, arguments, &index, flag, 128
                )
            case "--server":
                server = try unique(
                    server, arguments, &index, flag, 512
                )
            case "--repository":
                repository = try unique(
                    repository, arguments, &index, flag, 255
                )
            case "--signer":
                signerID = try unique(
                    signerID, arguments, &index, flag, 128
                )
            case "--signing-key-ref":
                signingKeyReference = try unique(
                    signingKeyReference,
                    arguments,
                    &index,
                    flag,
                    4_096
                )
            case "--digest":
                referrerDigest = try unique(
                    referrerDigest,
                    arguments,
                    &index,
                    flag,
                    160
                )
            case "--confirm-plan":
                confirmationPlan = try unique(
                    confirmationPlan,
                    arguments,
                    &index,
                    flag,
                    64
                )
            case "--state-db":
                stateDatabasePath = try unique(
                    stateDatabasePath,
                    arguments,
                    &index,
                    flag,
                    4_096
                )
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry provenance accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry provenance --output supports text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry provenance rejects secret values and unsupported arguments."
                )
            }
        }

        if let stateDatabasePath,
           !normalizedAbsolutePath(stateDatabasePath) {
            throw invalid(operation)
        }
        let action: RegistryProvenanceCLIAction
        switch operation {
        case "generate":
            guard normalizedAbsolutePath(target),
                  let recordPath,
                  normalizedAbsolutePath(recordPath),
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  let server,
                  let repository,
                  let signerID,
                  signerID.range(
                      of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
                      options: .regularExpression
                  ) != nil,
                  let signingKeyReference,
                  validSecretReference(signingKeyReference),
                  referrerDigest == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .generate(
                archivePath: target,
                recordPath: recordPath,
                manifestPath: manifestPath,
                serviceName: serviceName,
                server: server,
                repository: repository,
                signerID: signerID,
                signingKeyReference: signingKeyReference
            )
        case "verify":
            guard validUUID(target),
                  let referrerDigest,
                  (try? OCIContentDigest(referrerDigest)) != nil,
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  recordPath == nil,
                  server == nil,
                  repository == nil,
                  signerID == nil,
                  signingKeyReference == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .verify(
                discoveryID: target.lowercased(),
                referrerDigest: referrerDigest,
                manifestPath: manifestPath,
                serviceName: serviceName
            )
        case "status":
            guard normalizedAbsolutePath(target),
                  recordPath == nil,
                  manifestPath == nil,
                  server == nil,
                  repository == nil,
                  signerID == nil,
                  signingKeyReference == nil,
                  referrerDigest == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .status(
                manifestPath: target,
                serviceName: serviceName
            )
        case "resume":
            guard validUUID(target),
                  let confirmationPlan,
                  confirmationPlan.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil,
                  signingKeyReference.map(validSecretReference) ??
                    true,
                  recordPath == nil,
                  manifestPath == nil,
                  serviceName == nil,
                  server == nil,
                  repository == nil,
                  signerID == nil,
                  referrerDigest == nil else {
                throw invalid(operation)
            }
            action = .resume(
                operationGroupID: target.lowercased(),
                confirmationPlanSHA256: confirmationPlan,
                signingKeyReference: signingKeyReference
            )
        default:
            throw invalid(operation)
        }
        return RegistryCLIOptions(
            action: .provenance(action),
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func unique(
        _ existing: String?,
        _ arguments: [String],
        _ index: inout Int,
        _ flag: String,
        _ maximumBytes: Int
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "registry provenance accepts one value after \(flag)."
            )
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(value, maximumBytes: maximumBytes) else {
            throw CLIUsageError(
                "registry provenance \(flag) value is invalid."
            )
        }
        index += 2
        return value
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.hasPrefix("-") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil &&
            value.utf8.count == 36
    }

    private static func normalizedAbsolutePath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/") &&
            URL(fileURLWithPath: value)
                .standardizedFileURL.path == value &&
            !value.contains("\0")
    }

    private static func validSecretReference(
        _ value: String
    ) -> Bool {
        (try? HostwrightSecretReference.parse(value))?.rawValue ==
            value
    }

    private static func invalid(
        _ operation: String
    ) -> CLIUsageError {
        CLIUsageError(
            "registry provenance \(operation) has missing or incompatible fields."
        )
    }
}

public enum RegistryVulnerabilityCLIAction: Equatable, Sendable {
    case evaluate(
        discoveryID: String,
        referrerDigest: String,
        manifestPath: String,
        cosignPath: String,
        serviceName: String?
    )
    case status(manifestPath: String, serviceName: String?)
    case grantException(
        approvalRecordPath: String,
        manifestPath: String
    )
    case revokeException(exceptionID: String)
    case resume(
        operationGroupID: String,
        confirmationPlanSHA256: String
    )
}

enum RegistryVulnerabilityCLIParser {
    static func parse(arguments: [String]) throws -> RegistryCLIOptions {
        guard arguments.count >= 4,
              arguments[1] == "vulnerability",
              [
                "evaluate", "status", "grant-exception",
                "revoke-exception", "resume"
              ].contains(arguments[2]) else {
            throw CLIUsageError(
                "registry vulnerability requires evaluate, status, grant-exception, revoke-exception, or resume and one exact target."
            )
        }
        let operation = arguments[2]
        let target = arguments[3]
        guard valid(target, maximumBytes: 4_096) else {
            throw CLIUsageError(
                "registry vulnerability target is invalid."
            )
        }
        var manifestPath: String?
        var referrerDigest: String?
        var cosignPath: String?
        var serviceName: String?
        var confirmationPlan: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 4
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--manifest":
                manifestPath = try unique(
                    manifestPath, arguments, &index, flag, 4_096
                )
            case "--digest":
                referrerDigest = try unique(
                    referrerDigest, arguments, &index, flag, 160
                )
            case "--cosign":
                cosignPath = try unique(
                    cosignPath, arguments, &index, flag, 4_096
                )
            case "--service":
                serviceName = try unique(
                    serviceName, arguments, &index, flag, 128
                )
            case "--confirm-plan":
                confirmationPlan = try unique(
                    confirmationPlan, arguments, &index, flag, 64
                )
            case "--state-db":
                stateDatabasePath = try unique(
                    stateDatabasePath, arguments, &index, flag, 4_096
                )
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry vulnerability accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry vulnerability --output supports text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry vulnerability rejects credentials and unsupported arguments."
                )
            }
        }

        let action: RegistryVulnerabilityCLIAction
        switch operation {
        case "evaluate":
            guard validUUID(target),
                  let referrerDigest,
                  (try? OCIContentDigest(referrerDigest)) != nil,
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  let cosignPath,
                  normalizedAbsolutePath(cosignPath),
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .evaluate(
                discoveryID: target.lowercased(),
                referrerDigest: referrerDigest,
                manifestPath: manifestPath,
                cosignPath: cosignPath,
                serviceName: serviceName
            )
        case "status":
            guard normalizedAbsolutePath(target),
                  manifestPath == nil,
                  referrerDigest == nil,
                  cosignPath == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .status(
                manifestPath: target,
                serviceName: serviceName
            )
        case "grant-exception":
            guard normalizedAbsolutePath(target),
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  referrerDigest == nil,
                  cosignPath == nil,
                  serviceName == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .grantException(
                approvalRecordPath: target,
                manifestPath: manifestPath
            )
        case "revoke-exception":
            guard validUUID(target),
                  manifestPath == nil,
                  referrerDigest == nil,
                  cosignPath == nil,
                  serviceName == nil,
                  confirmationPlan == nil else {
                throw invalid(operation)
            }
            action = .revokeException(
                exceptionID: target.lowercased()
            )
        case "resume":
            guard validUUID(target),
                  manifestPath == nil,
                  referrerDigest == nil,
                  cosignPath == nil,
                  serviceName == nil,
                  let confirmationPlan,
                  confirmationPlan.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil else {
                throw invalid(operation)
            }
            action = .resume(
                operationGroupID: target.lowercased(),
                confirmationPlanSHA256: confirmationPlan
            )
        default:
            throw invalid(operation)
        }
        return RegistryCLIOptions(
            action: .vulnerability(action),
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func unique(
        _ existing: String?,
        _ arguments: [String],
        _ index: inout Int,
        _ flag: String,
        _ maximumBytes: Int
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "registry vulnerability accepts one value after \(flag)."
            )
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(value, maximumBytes: maximumBytes) else {
            throw CLIUsageError(
                "registry vulnerability \(flag) value is invalid."
            )
        }
        index += 2
        return value
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.hasPrefix("-") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil &&
            value.utf8.count == 36
    }

    private static func normalizedAbsolutePath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/") &&
            URL(fileURLWithPath: value)
                .standardizedFileURL.path == value &&
            !value.contains("\0")
    }

    private static func invalid(
        _ operation: String
    ) -> CLIUsageError {
        CLIUsageError(
            "registry vulnerability \(operation) has missing or incompatible fields."
        )
    }
}

public enum RegistrySBOMCLIAction: Equatable, Sendable {
    case generate(
        archivePath: String,
        manifestPath: String,
        serviceName: String?,
        server: String,
        repository: String,
        format: String,
        provenanceDescriptorDigest: String?,
        provenanceReferrerDigest: String?
    )
    case ingest(
        discoveryID: String,
        manifestPath: String,
        serviceName: String?
    )
    case query(manifestPath: String, serviceName: String?)
    case export(
        manifestPath: String,
        serviceName: String?,
        format: String,
        outputPath: String
    )
    case resume(
        operationGroupID: String,
        confirmationPlanSHA256: String
    )
}

enum RegistrySBOMCLIParser {
    static func parse(arguments: [String]) throws -> RegistryCLIOptions {
        guard arguments.count >= 4,
              arguments[1] == "sbom",
              ["generate", "ingest", "query", "export", "resume"]
                .contains(arguments[2]) else {
            throw CLIUsageError(
                "registry sbom requires generate, ingest, query, export, or resume and one exact target."
            )
        }
        let operation = arguments[2]
        let target = arguments[3]
        guard valid(target, maximumBytes: 4_096) else {
            throw CLIUsageError("registry sbom target is invalid.")
        }
        var manifestPath: String?
        var serviceName: String?
        var server: String?
        var repository: String?
        var format: String?
        var outputPath: String?
        var provenanceDescriptor: String?
        var provenanceReferrer: String?
        var confirmationPlan: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 4
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--manifest":
                manifestPath = try unique(
                    manifestPath, arguments, &index, flag, 4_096
                )
            case "--service":
                serviceName = try unique(
                    serviceName, arguments, &index, flag, 128
                )
            case "--server":
                server = try unique(
                    server, arguments, &index, flag, 512
                )
            case "--repository":
                repository = try unique(
                    repository, arguments, &index, flag, 255
                )
            case "--format":
                format = try unique(
                    format, arguments, &index, flag, 64
                )
            case "--output-path":
                outputPath = try unique(
                    outputPath, arguments, &index, flag, 4_096
                )
            case "--provenance-descriptor-digest":
                provenanceDescriptor = try unique(
                    provenanceDescriptor,
                    arguments,
                    &index,
                    flag,
                    256
                )
            case "--provenance-referrer-digest":
                provenanceReferrer = try unique(
                    provenanceReferrer,
                    arguments,
                    &index,
                    flag,
                    256
                )
            case "--confirm-plan":
                confirmationPlan = try unique(
                    confirmationPlan,
                    arguments,
                    &index,
                    flag,
                    64
                )
            case "--state-db":
                stateDatabasePath = try unique(
                    stateDatabasePath,
                    arguments,
                    &index,
                    flag,
                    4_096
                )
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry sbom accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry sbom --output supports text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry sbom rejects credentials and unsupported arguments."
                )
            }
        }
        let action: RegistrySBOMCLIAction
        switch operation {
        case "generate":
            guard normalizedAbsolutePath(target),
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  let server,
                  let repository,
                  let format,
                  ImageSBOMFormat(rawValue: format) != nil,
                  confirmationPlan == nil,
                  outputPath == nil,
                  (provenanceDescriptor == nil) ==
                    (provenanceReferrer == nil) else {
                throw invalid(operation)
            }
            action = .generate(
                archivePath: target,
                manifestPath: manifestPath,
                serviceName: serviceName,
                server: server,
                repository: repository,
                format: format,
                provenanceDescriptorDigest:
                    provenanceDescriptor,
                provenanceReferrerDigest: provenanceReferrer
            )
        case "ingest":
            guard UUID(uuidString: target) != nil,
                  target.utf8.count == 36,
                  let manifestPath,
                  normalizedAbsolutePath(manifestPath),
                  server == nil,
                  repository == nil,
                  format == nil,
                  confirmationPlan == nil,
                  outputPath == nil,
                  provenanceDescriptor == nil,
                  provenanceReferrer == nil else {
                throw invalid(operation)
            }
            action = .ingest(
                discoveryID: target.lowercased(),
                manifestPath: manifestPath,
                serviceName: serviceName
            )
        case "query":
            guard normalizedAbsolutePath(target),
                  manifestPath == nil,
                  server == nil,
                  repository == nil,
                  format == nil,
                  confirmationPlan == nil,
                  outputPath == nil,
                  provenanceDescriptor == nil,
                  provenanceReferrer == nil else {
                throw invalid(operation)
            }
            action = .query(
                manifestPath: target,
                serviceName: serviceName
            )
        case "export":
            guard normalizedAbsolutePath(target),
                  manifestPath == nil,
                  let format,
                  ImageSBOMFormat(rawValue: format) != nil,
                  let outputPath,
                  normalizedAbsolutePath(outputPath),
                  confirmationPlan == nil,
                  server == nil,
                  repository == nil,
                  provenanceDescriptor == nil,
                  provenanceReferrer == nil else {
                throw invalid(operation)
            }
            action = .export(
                manifestPath: target,
                serviceName: serviceName,
                format: format,
                outputPath: outputPath
            )
        case "resume":
            guard UUID(uuidString: target) != nil,
                  target.utf8.count == 36,
                  manifestPath == nil,
                  serviceName == nil,
                  server == nil,
                  repository == nil,
                  format == nil,
                  outputPath == nil,
                  provenanceDescriptor == nil,
                  provenanceReferrer == nil,
                  let confirmationPlan,
                  confirmationPlan.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil else {
                throw invalid(operation)
            }
            action = .resume(
                operationGroupID: target.lowercased(),
                confirmationPlanSHA256: confirmationPlan
            )
        default:
            throw invalid(operation)
        }
        return RegistryCLIOptions(
            action: .sbom(action),
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func unique(
        _ existing: String?,
        _ arguments: [String],
        _ index: inout Int,
        _ flag: String,
        _ maximumBytes: Int
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "registry sbom accepts one value after \(flag)."
            )
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(value, maximumBytes: maximumBytes) else {
            throw CLIUsageError(
                "registry sbom \(flag) value is invalid."
            )
        }
        index += 2
        return value
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.hasPrefix("-") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func normalizedAbsolutePath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/") &&
            URL(fileURLWithPath: value)
                .standardizedFileURL.path == value &&
            !value.contains("\0")
    }

    private static func invalid(
        _ operation: String
    ) -> CLIUsageError {
        CLIUsageError(
            "registry sbom \(operation) has missing or incompatible fields."
        )
    }
}

public enum RegistryReferrerCLIAction: Equatable, Sendable {
    case discover(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?,
        offline: Bool
    )
    case fetch(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?,
        offline: Bool
    )
    case publish(
        discoveryID: String,
        targetServer: String,
        targetRepository: String
    )
    case copy(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?,
        targetServer: String,
        targetRepository: String
    )
    case retain(
        discoveryID: String,
        ownerID: String,
        expiresAt: String
    )
    case release(leaseID: String, fencingToken: String)
    case status(discoveryID: String)
    case prune(
        discoveryID: String,
        referrerDigest: String,
        confirmationPlanSHA256: String?
    )
    case resume(
        operationGroupID: String,
        confirmationPlanSHA256: String
    )
}

public enum RegistryTrustCLIAction: Equatable, Sendable {
    case verify(
        discoveryID: String,
        manifestPath: String,
        subjectManifestPath: String,
        cosignPath: String,
        serviceName: String?
    )
    case status(manifestPath: String, serviceName: String?)
    case grantException(
        approvalRecordPath: String,
        manifestPath: String
    )
    case revokeException(exceptionID: String)
}

public struct RegistryCLIOptions: Equatable, Sendable {
    public let action: RegistryCLIAction
    public let stateDatabasePath: String?
    public let output: CLIOutputFormat

    public init(
        action: RegistryCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
    }
}

enum RegistryTrustCLIParser {
    static func parse(arguments: [String]) throws -> RegistryCLIOptions {
        guard arguments.count >= 4,
              arguments[1] == "trust",
              ["verify", "status", "grant-exception", "revoke-exception"]
                .contains(arguments[2]) else {
            throw CLIUsageError(
                "registry trust requires verify, status, grant-exception, or revoke-exception and one exact target."
            )
        }
        let operation = arguments[2]
        let target = arguments[3]
        guard validValue(target, maximumBytes: 4_096) else {
            throw CLIUsageError("registry trust target is invalid.")
        }
        var manifestPath: String?
        var subjectManifestPath: String?
        var cosignPath: String?
        var serviceName: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 4
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--manifest":
                manifestPath = try uniqueValue(
                    manifestPath,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 4_096
                )
            case "--subject-manifest":
                subjectManifestPath = try uniqueValue(
                    subjectManifestPath,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 4_096
                )
            case "--cosign":
                cosignPath = try uniqueValue(
                    cosignPath,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 4_096
                )
            case "--service":
                serviceName = try uniqueValue(
                    serviceName,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 128
                )
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    stateDatabasePath,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 4_096
                )
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry trust accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry trust --output supports text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry trust rejects credentials and unsupported arguments."
                )
            }
        }

        let action: RegistryTrustCLIAction
        switch operation {
        case "verify":
            guard validUUID(target),
                  let manifestPath,
                  let subjectManifestPath,
                  let cosignPath,
                  normalizedAbsolutePath(subjectManifestPath),
                  normalizedAbsolutePath(cosignPath) else {
                throw invalidCombination(operation)
            }
            action = .verify(
                discoveryID: target.lowercased(),
                manifestPath: manifestPath,
                subjectManifestPath: subjectManifestPath,
                cosignPath: cosignPath,
                serviceName: serviceName
            )
        case "status":
            guard manifestPath == nil,
                  subjectManifestPath == nil,
                  cosignPath == nil else {
                throw invalidCombination(operation)
            }
            action = .status(
                manifestPath: target,
                serviceName: serviceName
            )
        case "grant-exception":
            guard let manifestPath,
                  subjectManifestPath == nil,
                  cosignPath == nil,
                  serviceName == nil,
                  normalizedAbsolutePath(target) else {
                throw invalidCombination(operation)
            }
            action = .grantException(
                approvalRecordPath: target,
                manifestPath: manifestPath
            )
        case "revoke-exception":
            guard validUUID(target),
                  manifestPath == nil,
                  subjectManifestPath == nil,
                  cosignPath == nil,
                  serviceName == nil else {
                throw invalidCombination(operation)
            }
            action = .revokeException(exceptionID: target.lowercased())
        default:
            throw invalidCombination(operation)
        }
        return RegistryCLIOptions(
            action: .trust(action),
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func uniqueValue(
        _ existing: String?,
        arguments: [String],
        index: inout Int,
        flag: String,
        maximumBytes: Int
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "registry trust accepts one value after \(flag)."
            )
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard validValue(value, maximumBytes: maximumBytes) else {
            throw CLIUsageError("registry trust \(flag) value is invalid.")
        }
        index += 2
        return value
    }

    private static func validValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.hasPrefix("-") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.utf8.count == 36
    }

    private static func normalizedAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") &&
            URL(fileURLWithPath: value).standardizedFileURL.path == value &&
            !value.contains("\0")
    }

    private static func invalidCombination(
        _ operation: String
    ) -> CLIUsageError {
        CLIUsageError(
            "registry trust \(operation) has missing or incompatible fields."
        )
    }
}

enum RegistryReferrerCLIParser {
    static func parse(
        arguments: [String]
    ) throws -> RegistryCLIOptions {
        guard arguments.count >= 4,
              arguments[1] == "referrers" else {
            throw CLIUsageError(
                "registry referrers requires an operation and exact target."
            )
        }
        let operation = arguments[2]
        let target = arguments[3]
        guard [
            "discover", "fetch", "publish", "copy", "retain",
            "release", "status", "prune", "resume"
        ].contains(operation),
        validBounded(target, maximumBytes: 512) else {
            throw CLIUsageError(
                "registry referrers operation or target is invalid."
            )
        }

        var repository: String?
        var subjectDigest: String?
        var artifactType: String?
        var targetServer: String?
        var targetRepository: String?
        var ownerID: String?
        var expiresAt: String?
        var fencingToken: String?
        var referrerDigest: String?
        var confirmation: String?
        var stateDatabasePath: String?
        var offline = false
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 4

        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--repository":
                repository = try uniqueValue(
                    repository,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 255
                )
            case "--subject":
                subjectDigest = try uniqueValue(
                    subjectDigest,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 160
                )
            case "--artifact-type":
                artifactType = try uniqueValue(
                    artifactType,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 255
                )
            case "--target-server":
                targetServer = try uniqueValue(
                    targetServer,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 512
                )
            case "--target-repository":
                targetRepository = try uniqueValue(
                    targetRepository,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 255
                )
            case "--owner":
                ownerID = try uniqueValue(
                    ownerID,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 128
                )
            case "--expires-at":
                expiresAt = try uniqueValue(
                    expiresAt,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 64
                )
            case "--fencing-token":
                fencingToken = try uniqueValue(
                    fencingToken,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 36
                )
            case "--digest":
                referrerDigest = try uniqueValue(
                    referrerDigest,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 160
                )
            case "--confirm-plan":
                confirmation = try uniqueValue(
                    confirmation,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 64
                )
                guard confirmation?.range(
                    of: "^[a-f0-9]{64}$",
                    options: .regularExpression
                ) != nil else {
                    throw CLIUsageError(
                        "registry referrers --confirm-plan requires an exact lowercase SHA-256."
                    )
                }
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    stateDatabasePath,
                    arguments: arguments,
                    index: &index,
                    flag: flag,
                    maximumBytes: 4_096
                )
            case "--offline":
                guard !offline else {
                    throw CLIUsageError(
                        "registry referrers accepts --offline once."
                    )
                }
                offline = true
                index += 1
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry referrers accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry referrers --output supports text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry referrers does not accept credentials or unsupported arguments."
                )
            }
        }

        let action: RegistryReferrerCLIAction
        switch operation {
        case "discover", "fetch":
            guard let repository, let subjectDigest,
                  (try? RegistryEndpoint(target)) != nil,
                  (try? OCIRepositoryName(repository)) != nil,
                  (try? OCIContentDigest(subjectDigest)) != nil,
                  artifactType.map({
                      (try? OCIArtifactType($0)) != nil
                  }) ?? true,
                  targetServer == nil, targetRepository == nil,
                  ownerID == nil, expiresAt == nil,
                  fencingToken == nil, referrerDigest == nil,
                  confirmation == nil else {
                throw invalidCombination(operation)
            }
            if operation == "discover" {
                action = .discover(
                    server: target,
                    repository: repository,
                    subjectDigest: subjectDigest,
                    artifactType: artifactType,
                    offline: offline
                )
            } else {
                action = .fetch(
                    server: target,
                    repository: repository,
                    subjectDigest: subjectDigest,
                    artifactType: artifactType,
                    offline: offline
                )
            }
        case "publish":
            guard let targetServer, let targetRepository,
                  validUUID(target),
                  (try? RegistryEndpoint(targetServer)) != nil,
                  (try? OCIRepositoryName(targetRepository)) != nil,
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, ownerID == nil,
                  expiresAt == nil, fencingToken == nil,
                  referrerDigest == nil, confirmation == nil,
                  !offline else {
                throw invalidCombination(operation)
            }
            action = .publish(
                discoveryID: target.lowercased(),
                targetServer: targetServer,
                targetRepository: targetRepository
            )
        case "copy":
            guard let repository, let subjectDigest,
                  let targetServer, let targetRepository,
                  (try? RegistryEndpoint(target)) != nil,
                  (try? OCIRepositoryName(repository)) != nil,
                  (try? OCIContentDigest(subjectDigest)) != nil,
                  artifactType.map({
                      (try? OCIArtifactType($0)) != nil
                  }) ?? true,
                  (try? RegistryEndpoint(targetServer)) != nil,
                  (try? OCIRepositoryName(targetRepository)) != nil,
                  ownerID == nil, expiresAt == nil,
                  fencingToken == nil, referrerDigest == nil,
                  confirmation == nil, !offline else {
                throw invalidCombination(operation)
            }
            action = .copy(
                server: target,
                repository: repository,
                subjectDigest: subjectDigest,
                artifactType: artifactType,
                targetServer: targetServer,
                targetRepository: targetRepository
            )
        case "retain":
            guard validUUID(target), let ownerID, let expiresAt,
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, targetServer == nil,
                  targetRepository == nil, fencingToken == nil,
                  referrerDigest == nil, confirmation == nil,
                  !offline else {
                throw invalidCombination(operation)
            }
            action = .retain(
                discoveryID: target.lowercased(),
                ownerID: ownerID,
                expiresAt: expiresAt
            )
        case "release":
            guard validUUID(target), let fencingToken,
                  validUUID(fencingToken),
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, targetServer == nil,
                  targetRepository == nil, ownerID == nil,
                  expiresAt == nil, referrerDigest == nil,
                  confirmation == nil, !offline else {
                throw invalidCombination(operation)
            }
            action = .release(
                leaseID: target.lowercased(),
                fencingToken: fencingToken.lowercased()
            )
        case "status":
            guard validUUID(target),
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, targetServer == nil,
                  targetRepository == nil, ownerID == nil,
                  expiresAt == nil, fencingToken == nil,
                  referrerDigest == nil, confirmation == nil,
                  !offline else {
                throw invalidCombination(operation)
            }
            action = .status(discoveryID: target.lowercased())
        case "prune":
            guard validUUID(target), let referrerDigest,
                  (try? OCIContentDigest(referrerDigest)) != nil,
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, targetServer == nil,
                  targetRepository == nil, ownerID == nil,
                  expiresAt == nil, fencingToken == nil,
                  !offline else {
                throw invalidCombination(operation)
            }
            action = .prune(
                discoveryID: target.lowercased(),
                referrerDigest: referrerDigest,
                confirmationPlanSHA256: confirmation
            )
        case "resume":
            guard validUUID(target), let confirmation,
                  repository == nil, subjectDigest == nil,
                  artifactType == nil, targetServer == nil,
                  targetRepository == nil, ownerID == nil,
                  expiresAt == nil, fencingToken == nil,
                  referrerDigest == nil, !offline else {
                throw invalidCombination(operation)
            }
            action = .resume(
                operationGroupID: target.lowercased(),
                confirmationPlanSHA256: confirmation
            )
        default:
            throw invalidCombination(operation)
        }
        return RegistryCLIOptions(
            action: .referrers(action),
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func uniqueValue(
        _ existing: String?,
        arguments: [String],
        index: inout Int,
        flag: String,
        maximumBytes: Int
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "registry referrers accepts one value after \(flag)."
            )
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard validBounded(value, maximumBytes: maximumBytes) else {
            throw CLIUsageError(
                "registry referrers \(flag) value is invalid."
            )
        }
        index += 2
        return value
    }

    private static func validBounded(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.hasPrefix("-") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil &&
            value.utf8.count == 36
    }

    private static func invalidCombination(
        _ operation: String
    ) -> CLIUsageError {
        CLIUsageError(
            "registry referrers \(operation) has missing or incompatible fields."
        )
    }
}
