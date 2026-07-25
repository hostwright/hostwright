import CryptoKit
import Foundation

public enum ImageProvenanceLimits {
    public static let maximumRecordBytes = 1 * 1_024 * 1_024
    public static let maximumStatementBytes = 2 * 1_024 * 1_024
    public static let maximumEnvelopeBytes = 4 * 1_024 * 1_024
    public static let maximumDependencies = 256
    public static let maximumMaterials = 256
    public static let maximumEnvironmentVariables = 128
    public static let maximumStringBytes = 4_096
    public static let maximumBuildDurationSeconds = 7 * 24 * 60 * 60
}

public enum ImageProvenanceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidRecord
    case invalidStatement
    case invalidEnvelope
    case invalidPolicy
    case limitExceeded
    case subjectDigestMismatch
    case signatureInvalid
    case policyRejected
    case cancelled

    public var description: String {
        switch self {
        case .invalidRecord:
            "The build provenance input record is malformed or unsafe."
        case .invalidStatement:
            "The in-toto/SLSA provenance statement is malformed."
        case .invalidEnvelope:
            "The DSSE provenance envelope is malformed."
        case .invalidPolicy:
            "The image provenance policy or signer material is invalid."
        case .limitExceeded:
            "The image provenance input exceeds a bounded Hostwright limit."
        case .subjectDigestMismatch:
            "The provenance does not bind the exact expected image digest."
        case .signatureInvalid:
            "The provenance DSSE signature is invalid."
        case .policyRejected:
            "The provenance does not satisfy the exact manifest policy."
        case .cancelled:
            "The provenance operation was cancelled at a bounded checkpoint."
        }
    }
}

public struct ImageProvenanceResource:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let uri: String
    public let digest: OCIContentDigest

    public init(uri: String, digest: OCIContentDigest) throws {
        guard imageProvenanceURI(uri),
              digest.algorithm == "sha256" else {
            throw ImageProvenanceError.invalidRecord
        }
        self.uri = uri
        self.digest = digest
    }
}

public enum ImageProvenanceEnvironmentMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case hermetic
    case allowlisted
}

public enum ImageProvenanceNetworkMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case disabled
    case declared
}

public struct ImageProvenanceEnvironmentPolicy:
    Codable,
    Equatable,
    Sendable
{
    public let mode: ImageProvenanceEnvironmentMode
    public let network: ImageProvenanceNetworkMode
    public let variables: [String]
    public let secretVariables: [String]

    public init(
        mode: ImageProvenanceEnvironmentMode,
        network: ImageProvenanceNetworkMode,
        variables: [String],
        secretVariables: [String]
    ) throws {
        guard variables.count <=
                ImageProvenanceLimits.maximumEnvironmentVariables,
              secretVariables.count <=
                ImageProvenanceLimits.maximumEnvironmentVariables,
              Set(variables).count == variables.count,
              Set(secretVariables).count == secretVariables.count,
              Set(variables).isDisjoint(with: secretVariables),
              variables.allSatisfy(imageProvenanceEnvironmentName),
              secretVariables.allSatisfy(
                imageProvenanceEnvironmentName
              ),
              mode != .hermetic ||
                (variables.isEmpty && secretVariables.isEmpty &&
                    network == .disabled) else {
            throw ImageProvenanceError.invalidRecord
        }
        self.mode = mode
        self.network = network
        self.variables = variables.sorted()
        self.secretVariables = secretVariables.sorted()
    }
}

public struct ImageProvenanceCommandModel:
    Codable,
    Equatable,
    Sendable
{
    public static let supportedName = "apple-container-build"
    public static let currentVersion = 1

    public let name: String
    public let version: Int
    public let contextDigest: OCIContentDigest
    public let definitionDigest: OCIContentDigest
    public let target: String?

    public init(
        name: String = Self.supportedName,
        version: Int = Self.currentVersion,
        contextDigest: OCIContentDigest,
        definitionDigest: OCIContentDigest,
        target: String? = nil
    ) throws {
        guard name == Self.supportedName,
              version == Self.currentVersion,
              contextDigest.algorithm == "sha256",
              definitionDigest.algorithm == "sha256",
              target.map(imageProvenanceTarget) ?? true else {
            throw ImageProvenanceError.invalidRecord
        }
        self.name = name
        self.version = version
        self.contextDigest = contextDigest
        self.definitionDigest = definitionDigest
        self.target = target
    }
}

public enum ImageProvenanceReproducibilityStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case verified
    case notVerified = "not-verified"
}

public struct ImageProvenanceReproducibility:
    Codable,
    Equatable,
    Sendable
{
    public let status: ImageProvenanceReproducibilityStatus
    public let comparisonDigest: OCIContentDigest?

    public init(
        status: ImageProvenanceReproducibilityStatus,
        comparisonDigest: OCIContentDigest?
    ) throws {
        guard (status == .verified) == (comparisonDigest != nil),
              comparisonDigest.map({ $0.algorithm == "sha256" }) ??
                true else {
            throw ImageProvenanceError.invalidRecord
        }
        self.status = status
        self.comparisonDigest = comparisonDigest
    }
}

public struct ImageBuildProvenanceRecord:
    Equatable,
    Sendable
{
    public static let currentVersion = 1

    public let schemaVersion: Int
    public let source: ImageProvenanceResource
    public let builderID: String
    public let builderVersion: String
    public let buildType: String
    public let invocationID: String
    public let dependencies: [ImageProvenanceResource]
    public let materials: [ImageProvenanceResource]
    public let command: ImageProvenanceCommandModel
    public let environment: ImageProvenanceEnvironmentPolicy
    public let startedAt: String
    public let finishedAt: String
    public let outputName: String
    public let outputDigest: OCIContentDigest
    public let reproducibility: ImageProvenanceReproducibility

    public static func parse(
        _ data: Data,
        expectedSubjectDigest: OCIContentDigest
    ) throws -> ImageBuildProvenanceRecord {
        guard !data.isEmpty else {
            throw ImageProvenanceError.invalidRecord
        }
        guard data.count <= ImageProvenanceLimits.maximumRecordBytes else {
            throw ImageProvenanceError.limitExceeded
        }
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes:
                    ImageProvenanceLimits.maximumRecordBytes,
                allowedKeys: [
                    "schemaVersion", "source", "builder",
                    "buildType", "invocationID", "dependencies",
                    "materials", "command", "environment",
                    "startedAt", "finishedAt", "output",
                    "reproducibility"
                ],
                requiredKeys: [
                    "schemaVersion", "source", "builder",
                    "buildType", "invocationID", "dependencies",
                    "materials", "command", "environment",
                    "startedAt", "finishedAt", "output",
                    "reproducibility"
                ]
            )
        } catch {
            throw ImageProvenanceError.invalidRecord
        }
        guard RegistryStrictJSONObject.integer(
                object["schemaVersion"]
              ) == Self.currentVersion,
              let sourceObject = object["source"] as? [String: Any],
              let builderObject = object["builder"] as? [String: Any],
              let buildType = object["buildType"] as? String,
              let invocationID =
                object["invocationID"] as? String,
              let dependencyObjects =
                object["dependencies"] as? [Any],
              let materialObjects = object["materials"] as? [Any],
              let commandObject = object["command"] as? [String: Any],
              let environmentObject =
                object["environment"] as? [String: Any],
              let startedAt = object["startedAt"] as? String,
              let finishedAt = object["finishedAt"] as? String,
              let outputObject = object["output"] as? [String: Any],
              let reproducibilityObject =
                object["reproducibility"] as? [String: Any] else {
            throw ImageProvenanceError.invalidRecord
        }
        let source = try parseResource(sourceObject)
        let builder = try parseBuilder(builderObject)
        let dependencies = try parseResources(
            dependencyObjects,
            maximum: ImageProvenanceLimits.maximumDependencies
        )
        let materials = try parseResources(
            materialObjects,
            maximum: ImageProvenanceLimits.maximumMaterials
        )
        let command = try parseCommand(commandObject)
        let environment = try parseEnvironment(environmentObject)
        let output = try parseOutput(outputObject)
        let reproducibility = try parseReproducibility(
            reproducibilityObject
        )
        guard imageProvenanceURI(buildType),
              UUID(uuidString: invocationID) != nil,
              imageProvenanceTimestamp(startedAt) != nil,
              let finished = imageProvenanceTimestamp(finishedAt),
              let started = imageProvenanceTimestamp(startedAt),
              finished >= started,
              finished.timeIntervalSince(started) <=
                Double(
                    ImageProvenanceLimits
                        .maximumBuildDurationSeconds
                ),
              output.digest == expectedSubjectDigest,
              reproducibility.comparisonDigest.map({
                  $0 == expectedSubjectDigest
              }) ?? true else {
            throw ImageProvenanceError.invalidRecord
        }
        return ImageBuildProvenanceRecord(
            schemaVersion: Self.currentVersion,
            source: source,
            builderID: builder.id,
            builderVersion: builder.version,
            buildType: buildType,
            invocationID: invocationID.lowercased(),
            dependencies: dependencies,
            materials: materials,
            command: command,
            environment: environment,
            startedAt: imageProvenanceTimestampString(started),
            finishedAt: imageProvenanceTimestampString(finished),
            outputName: output.name,
            outputDigest: output.digest,
            reproducibility: reproducibility
        )
    }

    public func statementPayload(
        signerID: String
    ) throws -> Data {
        guard imageProvenanceIdentifier(signerID) else {
            throw ImageProvenanceError.invalidRecord
        }
        var resourcesByURI: [String: ImageProvenanceResource] = [:]
        for resource in [source] + dependencies + materials {
            if let existing = resourcesByURI[resource.uri],
               existing != resource {
                throw ImageProvenanceError.invalidRecord
            }
            resourcesByURI[resource.uri] = resource
        }
        let resolved = resourcesByURI.values.sorted {
            $0.uri < $1.uri
        }
        var commandObject: [String: Any] = [
            "name": command.name,
            "version": command.version,
            "contextDigest":
                command.contextDigest.canonicalValue,
            "definitionDigest":
                command.definitionDigest.canonicalValue
        ]
        if let target = command.target {
            commandObject["target"] = target
        }
        var reproducibilityObject: [String: Any] = [
            "status": reproducibility.status.rawValue
        ]
        if let digest = reproducibility.comparisonDigest {
            reproducibilityObject["comparisonDigest"] =
                digest.canonicalValue
        }
        let object: [String: Any] = [
            "_type": ImageProvenanceStatement.statementType,
            "subject": [[
                "name": outputName,
                "digest": [
                    outputDigest.algorithm: outputDigest.encoded
                ]
            ]],
            "predicateType":
                ImageProvenanceStatement.predicateType,
            "predicate": [
                "buildDefinition": [
                    "buildType": buildType,
                    "externalParameters": [
                        "source": resourceObject(source),
                        "command": commandObject,
                        "environment": [
                            "mode": environment.mode.rawValue,
                            "network": environment.network.rawValue,
                            "variables": environment.variables,
                            "secretVariables":
                                environment.secretVariables
                        ],
                        "output": [
                            "name": outputName,
                            "digest":
                                outputDigest.canonicalValue
                        ],
                        "reproducibility":
                            reproducibilityObject,
                        "signerID": signerID
                    ],
                    "internalParameters": [:],
                    "resolvedDependencies":
                        resolved.map(resourceObject)
                ],
                "runDetails": [
                    "builder": [
                        "id": builderID,
                        "version": [
                            "hostwright": builderVersion
                        ]
                    ],
                    "metadata": [
                        "invocationId": invocationID,
                        "startedOn": startedAt,
                        "finishedOn": finishedAt
                    ],
                    "byproducts": []
                ]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ImageProvenanceError.invalidStatement
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <=
                ImageProvenanceLimits.maximumStatementBytes else {
            throw ImageProvenanceError.limitExceeded
        }
        _ = try ImageProvenanceStatement.parse(
            data,
            expectedSubjectDigest: outputDigest
        )
        return data
    }

    private init(
        schemaVersion: Int,
        source: ImageProvenanceResource,
        builderID: String,
        builderVersion: String,
        buildType: String,
        invocationID: String,
        dependencies: [ImageProvenanceResource],
        materials: [ImageProvenanceResource],
        command: ImageProvenanceCommandModel,
        environment: ImageProvenanceEnvironmentPolicy,
        startedAt: String,
        finishedAt: String,
        outputName: String,
        outputDigest: OCIContentDigest,
        reproducibility: ImageProvenanceReproducibility
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.builderID = builderID
        self.builderVersion = builderVersion
        self.buildType = buildType
        self.invocationID = invocationID
        self.dependencies = dependencies
        self.materials = materials
        self.command = command
        self.environment = environment
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputName = outputName
        self.outputDigest = outputDigest
        self.reproducibility = reproducibility
    }

    private static func parseBuilder(
        _ object: [String: Any]
    ) throws -> (id: String, version: String) {
        guard Set(object.keys) == ["id", "version"],
              let id = object["id"] as? String,
              let version = object["version"] as? String,
              imageProvenanceURI(id),
              imageProvenanceString(version, maximumBytes: 128)
        else {
            throw ImageProvenanceError.invalidRecord
        }
        return (id, version)
    }

    private static func parseResource(
        _ object: [String: Any]
    ) throws -> ImageProvenanceResource {
        guard Set(object.keys) == ["uri", "digest"],
              let uri = object["uri"] as? String,
              let rawDigest = object["digest"] as? String else {
            throw ImageProvenanceError.invalidRecord
        }
        return try ImageProvenanceResource(
            uri: uri,
            digest: OCIContentDigest(rawDigest)
        )
    }

    private static func parseResources(
        _ objects: [Any],
        maximum: Int
    ) throws -> [ImageProvenanceResource] {
        guard objects.count <= maximum else {
            throw ImageProvenanceError.limitExceeded
        }
        let values = try objects.map { raw -> ImageProvenanceResource in
            guard let object = raw as? [String: Any] else {
                throw ImageProvenanceError.invalidRecord
            }
            return try parseResource(object)
        }.sorted { $0.uri < $1.uri }
        guard Set(values.map(\.uri)).count == values.count else {
            throw ImageProvenanceError.invalidRecord
        }
        return values
    }

    private static func parseCommand(
        _ object: [String: Any]
    ) throws -> ImageProvenanceCommandModel {
        let allowed = Set([
            "name", "version", "contextDigest",
            "definitionDigest", "target"
        ])
        guard Set(object.keys).isSubset(of: allowed),
              Set(object.keys).isSuperset(
                of: [
                    "name", "version", "contextDigest",
                    "definitionDigest"
                ]
              ),
              let name = object["name"] as? String,
              let version =
                RegistryStrictJSONObject.integer(object["version"]),
              let context = object["contextDigest"] as? String,
              let definition =
                object["definitionDigest"] as? String,
              object["target"] == nil ||
                object["target"] is String else {
            throw ImageProvenanceError.invalidRecord
        }
        return try ImageProvenanceCommandModel(
            name: name,
            version: version,
            contextDigest: OCIContentDigest(context),
            definitionDigest: OCIContentDigest(definition),
            target: object["target"] as? String
        )
    }

    private static func parseEnvironment(
        _ object: [String: Any]
    ) throws -> ImageProvenanceEnvironmentPolicy {
        guard Set(object.keys) == [
            "mode", "network", "variables", "secretVariables"
        ],
        let modeRaw = object["mode"] as? String,
        let mode = ImageProvenanceEnvironmentMode(rawValue: modeRaw),
        let networkRaw = object["network"] as? String,
        let network = ImageProvenanceNetworkMode(rawValue: networkRaw),
        let variables = object["variables"] as? [String],
        let secretVariables =
            object["secretVariables"] as? [String] else {
            throw ImageProvenanceError.invalidRecord
        }
        return try ImageProvenanceEnvironmentPolicy(
            mode: mode,
            network: network,
            variables: variables,
            secretVariables: secretVariables
        )
    }

    private static func parseOutput(
        _ object: [String: Any]
    ) throws -> (name: String, digest: OCIContentDigest) {
        guard Set(object.keys) == ["name", "digest"],
              let name = object["name"] as? String,
              imageProvenanceString(name, maximumBytes: 256),
              let rawDigest = object["digest"] as? String else {
            throw ImageProvenanceError.invalidRecord
        }
        return (name, try OCIContentDigest(rawDigest))
    }

    private static func parseReproducibility(
        _ object: [String: Any]
    ) throws -> ImageProvenanceReproducibility {
        guard Set(object.keys).isSubset(
                of: ["status", "comparisonDigest"]
              ),
              let rawStatus = object["status"] as? String,
              let status =
                ImageProvenanceReproducibilityStatus(
                    rawValue: rawStatus
                ),
              object["comparisonDigest"] == nil ||
                object["comparisonDigest"] is String else {
            throw ImageProvenanceError.invalidRecord
        }
        return try ImageProvenanceReproducibility(
            status: status,
            comparisonDigest: try (
                object["comparisonDigest"] as? String
            ).map(OCIContentDigest.init)
        )
    }
}

public struct ImageProvenanceStatement:
    Equatable,
    Sendable
{
    public static let statementType =
        "https://in-toto.io/Statement/v1"
    public static let predicateType =
        "https://slsa.dev/provenance/v1"

    public let statementDigest: OCIContentDigest
    public let subjectDigest: OCIContentDigest
    public let outputName: String
    public let source: ImageProvenanceResource
    public let builderID: String
    public let builderVersion: String
    public let buildType: String
    public let invocationID: String
    public let resolvedDependencies: [ImageProvenanceResource]
    public let command: ImageProvenanceCommandModel
    public let environment: ImageProvenanceEnvironmentPolicy
    public let startedAt: String
    public let finishedAt: String
    public let reproducibility: ImageProvenanceReproducibility
    public let signerID: String
    public let normalizedMaterialsSHA256: String
    public let commandSHA256: String
    public let environmentPolicySHA256: String

    public static func parse(
        _ data: Data,
        expectedSubjectDigest: OCIContentDigest
    ) throws -> ImageProvenanceStatement {
        guard !data.isEmpty else {
            throw ImageProvenanceError.invalidStatement
        }
        guard data.count <=
                ImageProvenanceLimits.maximumStatementBytes else {
            throw ImageProvenanceError.limitExceeded
        }
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes:
                    ImageProvenanceLimits.maximumStatementBytes,
                allowedKeys: [
                    "_type", "subject", "predicateType",
                    "predicate"
                ],
                requiredKeys: [
                    "_type", "subject", "predicateType",
                    "predicate"
                ]
            )
        } catch {
            throw ImageProvenanceError.invalidStatement
        }
        guard object["_type"] as? String == statementType,
              object["predicateType"] as? String ==
                predicateType,
              let subjects = object["subject"] as? [Any],
              subjects.count == 1,
              let subject = subjects[0] as? [String: Any],
              Set(subject.keys) == ["name", "digest"],
              let outputName = subject["name"] as? String,
              imageProvenanceString(
                outputName,
                maximumBytes: 256
              ),
              let subjectDigests =
                subject["digest"] as? [String: Any],
              Set(subjectDigests.keys) == ["sha256"],
              subjectDigests["sha256"] as? String ==
                expectedSubjectDigest.encoded,
              let predicate =
                object["predicate"] as? [String: Any],
              Set(predicate.keys) ==
                ["buildDefinition", "runDetails"],
              let buildDefinition =
                predicate["buildDefinition"] as? [String: Any],
              Set(buildDefinition.keys) == [
                  "buildType", "externalParameters",
                  "internalParameters", "resolvedDependencies"
              ],
              let buildType =
                buildDefinition["buildType"] as? String,
              imageProvenanceURI(buildType),
              let external =
                buildDefinition[
                    "externalParameters"
                ] as? [String: Any],
              Set(external.keys) == [
                  "source", "command", "environment", "output",
                  "reproducibility", "signerID"
              ],
              let sourceObject =
                external["source"] as? [String: Any],
              let commandObject =
                external["command"] as? [String: Any],
              let environmentObject =
                external["environment"] as? [String: Any],
              let outputObject =
                external["output"] as? [String: Any],
              let reproducibilityObject =
                external[
                    "reproducibility"
                ] as? [String: Any],
              let signerID = external["signerID"] as? String,
              imageProvenanceIdentifier(signerID),
              let internalParameters =
                buildDefinition[
                    "internalParameters"
                ] as? [String: Any],
              internalParameters.isEmpty,
              let dependencyObjects =
                buildDefinition[
                    "resolvedDependencies"
                ] as? [Any],
              dependencyObjects.count <=
                ImageProvenanceLimits.maximumDependencies +
                    ImageProvenanceLimits.maximumMaterials + 1,
              let runDetails =
                predicate["runDetails"] as? [String: Any],
              Set(runDetails.keys) ==
                ["builder", "metadata", "byproducts"],
              let byproducts =
                runDetails["byproducts"] as? [Any],
              byproducts.isEmpty,
              let builder =
                runDetails["builder"] as? [String: Any],
              Set(builder.keys) == ["id", "version"],
              let builderID = builder["id"] as? String,
              imageProvenanceURI(builderID),
              let builderVersions =
                builder["version"] as? [String: Any],
              Set(builderVersions.keys) == ["hostwright"],
              let builderVersion =
                builderVersions["hostwright"] as? String,
              imageProvenanceString(
                builderVersion,
                maximumBytes: 128
              ),
              let metadata =
                runDetails["metadata"] as? [String: Any],
              Set(metadata.keys) ==
                ["invocationId", "startedOn", "finishedOn"],
              let invocationID =
                metadata["invocationId"] as? String,
              UUID(uuidString: invocationID) != nil,
              let startedAt = metadata["startedOn"] as? String,
              let finishedAt =
                metadata["finishedOn"] as? String,
              let started = imageProvenanceTimestamp(startedAt),
              let finished =
                imageProvenanceTimestamp(finishedAt),
              finished >= started,
              finished.timeIntervalSince(started) <=
                Double(
                    ImageProvenanceLimits
                        .maximumBuildDurationSeconds
                ) else {
            throw ImageProvenanceError.invalidStatement
        }
        let source = try ImageBuildProvenanceRecord
            .parseStatementResource(sourceObject)
        let dependencies = try dependencyObjects.map {
            raw -> ImageProvenanceResource in
            guard let value = raw as? [String: Any] else {
                throw ImageProvenanceError.invalidStatement
            }
            return try ImageBuildProvenanceRecord
                .parseStatementResource(value)
        }.sorted { $0.uri < $1.uri }
        guard Set(dependencies.map(\.uri)).count ==
                dependencies.count,
              dependencies.contains(source) else {
            throw ImageProvenanceError.invalidStatement
        }
        let command = try ImageBuildProvenanceRecord
            .parseStatementCommand(commandObject)
        let environment = try ImageBuildProvenanceRecord
            .parseStatementEnvironment(environmentObject)
        let output = try ImageBuildProvenanceRecord
            .parseStatementOutput(outputObject)
        let reproducibility = try ImageBuildProvenanceRecord
            .parseStatementReproducibility(
                reproducibilityObject
            )
        guard output.name == outputName,
              output.digest == expectedSubjectDigest,
              reproducibility.comparisonDigest.map({
                  $0 == expectedSubjectDigest
              }) ?? true else {
            throw ImageProvenanceError.subjectDigestMismatch
        }
        return ImageProvenanceStatement(
            statementDigest: try OCIContentDigest.sha256(of: data),
            subjectDigest: expectedSubjectDigest,
            outputName: outputName,
            source: source,
            builderID: builderID,
            builderVersion: builderVersion,
            buildType: buildType,
            invocationID: invocationID.lowercased(),
            resolvedDependencies: dependencies,
            command: command,
            environment: environment,
            startedAt: imageProvenanceTimestampString(started),
            finishedAt: imageProvenanceTimestampString(finished),
            reproducibility: reproducibility,
            signerID: signerID,
            normalizedMaterialsSHA256:
                try imageProvenanceJSONSHA256(
                    dependencies.map(resourceObject)
                ),
            commandSHA256:
                try imageProvenanceJSONSHA256(commandObject),
            environmentPolicySHA256:
                try imageProvenanceJSONSHA256(
                    environmentObject
                )
        )
    }

    private init(
        statementDigest: OCIContentDigest,
        subjectDigest: OCIContentDigest,
        outputName: String,
        source: ImageProvenanceResource,
        builderID: String,
        builderVersion: String,
        buildType: String,
        invocationID: String,
        resolvedDependencies: [ImageProvenanceResource],
        command: ImageProvenanceCommandModel,
        environment: ImageProvenanceEnvironmentPolicy,
        startedAt: String,
        finishedAt: String,
        reproducibility: ImageProvenanceReproducibility,
        signerID: String,
        normalizedMaterialsSHA256: String,
        commandSHA256: String,
        environmentPolicySHA256: String
    ) {
        self.statementDigest = statementDigest
        self.subjectDigest = subjectDigest
        self.outputName = outputName
        self.source = source
        self.builderID = builderID
        self.builderVersion = builderVersion
        self.buildType = buildType
        self.invocationID = invocationID
        self.resolvedDependencies = resolvedDependencies
        self.command = command
        self.environment = environment
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reproducibility = reproducibility
        self.signerID = signerID
        self.normalizedMaterialsSHA256 =
            normalizedMaterialsSHA256
        self.commandSHA256 = commandSHA256
        self.environmentPolicySHA256 =
            environmentPolicySHA256
    }
}

public struct ImageProvenanceDSSEEnvelope:
    Equatable,
    Sendable
{
    public static let payloadType =
        "application/vnd.in-toto+json"
    public static let layerMediaType =
        "application/vnd.dsse.envelope.v1+json"
    public static let artifactType =
        "application/vnd.in-toto+json"

    public let payload: Data
    public let signerID: String
    public let signature: Data
    public let envelopeDigest: OCIContentDigest
    public let statement: ImageProvenanceStatement

    public static func sign(
        statementPayload: Data,
        expectedSubjectDigest: OCIContentDigest,
        signerID: String,
        privateKeyText: String
    ) throws -> (
        envelopePayload: Data,
        envelope: ImageProvenanceDSSEEnvelope,
        publicKeySHA256: String
    ) {
        guard imageProvenanceIdentifier(signerID) else {
            throw ImageProvenanceError.invalidEnvelope
        }
        let privateKey = try imageProvenancePrivateKey(
            privateKeyText
        )
        let signature: Data
        do {
            signature = try privateKey.signature(
                for: preAuthenticationEncoding(
                    payloadType: payloadType,
                    payload: statementPayload
                )
            )
        } catch {
            throw ImageProvenanceError.signatureInvalid
        }
        let object: [String: Any] = [
            "payloadType": payloadType,
            "payload": statementPayload.base64EncodedString(),
            "signatures": [[
                "keyid": signerID,
                "sig": signature.base64EncodedString()
            ]]
        ]
        let envelopePayload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard envelopePayload.count <=
                ImageProvenanceLimits.maximumEnvelopeBytes else {
            throw ImageProvenanceError.limitExceeded
        }
        let envelope = try parse(
            envelopePayload,
            expectedSubjectDigest: expectedSubjectDigest
        )
        let publicKeySHA256 = imageProvenanceSHA256(
            privateKey.publicKey.rawRepresentation
        )
        return (envelopePayload, envelope, publicKeySHA256)
    }

    public static func parse(
        _ data: Data,
        expectedSubjectDigest: OCIContentDigest
    ) throws -> ImageProvenanceDSSEEnvelope {
        guard !data.isEmpty else {
            throw ImageProvenanceError.invalidEnvelope
        }
        guard data.count <=
                ImageProvenanceLimits.maximumEnvelopeBytes else {
            throw ImageProvenanceError.limitExceeded
        }
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes:
                    ImageProvenanceLimits.maximumEnvelopeBytes,
                allowedKeys: [
                    "payloadType", "payload", "signatures"
                ],
                requiredKeys: [
                    "payloadType", "payload", "signatures"
                ]
            )
        } catch {
            throw ImageProvenanceError.invalidEnvelope
        }
        guard object["payloadType"] as? String == payloadType,
              let encodedPayload = object["payload"] as? String,
              let payload = Data(
                  base64Encoded: encodedPayload,
                  options: []
              ),
              payload.count <=
                ImageProvenanceLimits.maximumStatementBytes,
              let signatures = object["signatures"] as? [Any],
              signatures.count == 1,
              let signatureObject =
                signatures[0] as? [String: Any],
              Set(signatureObject.keys) == ["keyid", "sig"],
              let signerID =
                signatureObject["keyid"] as? String,
              imageProvenanceIdentifier(signerID),
              let encodedSignature =
                signatureObject["sig"] as? String,
              let signature = Data(
                  base64Encoded: encodedSignature,
                  options: []
              ),
              signature.count == 64 else {
            throw ImageProvenanceError.invalidEnvelope
        }
        return ImageProvenanceDSSEEnvelope(
            payload: payload,
            signerID: signerID,
            signature: signature,
            envelopeDigest: try OCIContentDigest.sha256(of: data),
            statement: try ImageProvenanceStatement.parse(
                payload,
                expectedSubjectDigest: expectedSubjectDigest
            )
        )
    }

    public func verify(publicKeyData: Data) throws -> String {
        let publicKey = try imageProvenancePublicKey(
            publicKeyData
        )
        guard publicKey.isValidSignature(
            signature,
            for: Self.preAuthenticationEncoding(
                payloadType: Self.payloadType,
                payload: payload
            )
        ) else {
            throw ImageProvenanceError.signatureInvalid
        }
        return imageProvenanceSHA256(
            publicKey.rawRepresentation
        )
    }

    private static func preAuthenticationEncoding(
        payloadType: String,
        payload: Data
    ) -> Data {
        var result = Data(
            "DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payload.count) "
                .utf8
        )
        result.append(payload)
        return result
    }

    private init(
        payload: Data,
        signerID: String,
        signature: Data,
        envelopeDigest: OCIContentDigest,
        statement: ImageProvenanceStatement
    ) {
        self.payload = payload
        self.signerID = signerID
        self.signature = signature
        self.envelopeDigest = envelopeDigest
        self.statement = statement
    }
}

public enum ImageProvenanceRequirement:
    String,
    Codable,
    Equatable,
    Sendable
{
    case optional
    case required
}

public struct ImageProvenanceSigner:
    Equatable,
    Sendable
{
    public let id: String
    public let publicKeyPath: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let revokedAt: Date?

    public init(
        id: String,
        publicKeyPath: String,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        revokedAt: Date? = nil
    ) throws {
        guard imageProvenanceIdentifier(id),
              publicKeyPath.hasPrefix("/"),
              publicKeyPath.utf8.count <= 4_096,
              URL(fileURLWithPath: publicKeyPath)
                .standardizedFileURL.path == publicKeyPath,
              !publicKeyPath.contains("\0"),
              notBefore == nil || notAfter == nil ||
                notAfter! > notBefore! else {
            throw ImageProvenanceError.invalidPolicy
        }
        self.id = id
        self.publicKeyPath = publicKeyPath
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.revokedAt = revokedAt
    }

    public func isActive(at date: Date) -> Bool {
        if let notBefore, date < notBefore { return false }
        if let notAfter, date > notAfter { return false }
        if let revokedAt, date >= revokedAt { return false }
        return true
    }
}

public struct ImageProvenancePolicy:
    Equatable,
    Sendable
{
    public static let currentVersion = 1

    public let version: Int
    public let requirement: ImageProvenanceRequirement
    public let builderIDs: [String]
    public let buildTypes: [String]
    public let signers: [ImageProvenanceSigner]
    public let maximumAgeSeconds: Int
    public let requireReproducible: Bool

    public init(
        version: Int = Self.currentVersion,
        requirement: ImageProvenanceRequirement,
        builderIDs: [String],
        buildTypes: [String],
        signers: [ImageProvenanceSigner],
        maximumAgeSeconds: Int,
        requireReproducible: Bool
    ) throws {
        guard version == Self.currentVersion,
              (1...16).contains(builderIDs.count),
              (1...16).contains(buildTypes.count),
              (1...8).contains(signers.count),
              Set(builderIDs).count == builderIDs.count,
              Set(buildTypes).count == buildTypes.count,
              Set(signers.map(\.id)).count == signers.count,
              builderIDs.allSatisfy(imageProvenanceURI),
              buildTypes.allSatisfy(imageProvenanceURI),
              (60...31_536_000).contains(maximumAgeSeconds)
        else {
            throw ImageProvenanceError.invalidPolicy
        }
        self.version = version
        self.requirement = requirement
        self.builderIDs = builderIDs.sorted()
        self.buildTypes = buildTypes.sorted()
        self.signers = signers.sorted { $0.id < $1.id }
        self.maximumAgeSeconds = maximumAgeSeconds
        self.requireReproducible = requireReproducible
    }
}

public struct ImageProvenancePolicyMaterial:
    Equatable,
    Sendable
{
    public let policySHA256: String
    public let publicKeySHA256: [String: String]
    public let publicKeys: [String: Data]

    public static func resolve(
        _ policy: ImageProvenancePolicy
    ) throws -> ImageProvenancePolicyMaterial {
        var keyDigests: [String: String] = [:]
        var keys: [String: Data] = [:]
        var signerObjects: [[String: Any]] = []
        for signer in policy.signers {
            let fileData: Data
            do {
                fileData = try imageTrustSecureFileData(
                    path: signer.publicKeyPath,
                    maximumBytes: 16 * 1_024
                )
                let publicKey = try imageProvenancePublicKey(fileData)
                let raw = publicKey.rawRepresentation
                keyDigests[signer.id] =
                    imageProvenanceSHA256(raw)
                keys[signer.id] = raw
            } catch {
                throw ImageProvenanceError.invalidPolicy
            }
            var object: [String: Any] = [
                "id": signer.id,
                "publicKeyPath": signer.publicKeyPath,
                "publicKeySHA256": keyDigests[signer.id]!
            ]
            if let notBefore = signer.notBefore {
                object["notBefore"] =
                    imageProvenanceTimestampString(notBefore)
            }
            if let notAfter = signer.notAfter {
                object["notAfter"] =
                    imageProvenanceTimestampString(notAfter)
            }
            if let revokedAt = signer.revokedAt {
                object["revokedAt"] =
                    imageProvenanceTimestampString(revokedAt)
            }
            signerObjects.append(object)
        }
        let canonical: [String: Any] = [
            "version": policy.version,
            "requirement": policy.requirement.rawValue,
            "builderIDs": policy.builderIDs,
            "buildTypes": policy.buildTypes,
            "signers": signerObjects,
            "maximumAgeSeconds": policy.maximumAgeSeconds,
            "requireReproducible": policy.requireReproducible
        ]
        return ImageProvenancePolicyMaterial(
            policySHA256:
                try imageProvenanceJSONSHA256(canonical),
            publicKeySHA256: keyDigests,
            publicKeys: keys
        )
    }
}

public struct ImageProvenanceVerification:
    Equatable,
    Sendable
{
    public static let verifierVersion =
        "hostwright-image-provenance-v1"

    public let statement: ImageProvenanceStatement
    public let envelopeDigest: OCIContentDigest
    public let signerID: String
    public let signerPublicKeySHA256: String
    public let signatureSHA256: String
    public let policySHA256: String
    public let verifiedAt: String
}

public enum ImageProvenanceVerifier {
    public static func verify(
        envelopePayload: Data,
        expectedSubjectDigest: OCIContentDigest,
        policy: ImageProvenancePolicy,
        material: ImageProvenancePolicyMaterial,
        at date: Date
    ) throws -> ImageProvenanceVerification {
        let envelope = try ImageProvenanceDSSEEnvelope.parse(
            envelopePayload,
            expectedSubjectDigest: expectedSubjectDigest
        )
        guard envelope.signerID == envelope.statement.signerID,
              policy.builderIDs.contains(
                  envelope.statement.builderID
              ),
              policy.buildTypes.contains(
                  envelope.statement.buildType
              ),
              let signer = policy.signers.first(where: {
                  $0.id == envelope.signerID
              }),
              signer.isActive(at: date),
              let publicKey =
                material.publicKeys[envelope.signerID],
              let expectedKeySHA =
                material.publicKeySHA256[envelope.signerID],
              material.policySHA256.count == 64 else {
            throw ImageProvenanceError.policyRejected
        }
        let finished = imageProvenanceTimestamp(
            envelope.statement.finishedAt
        )
        guard let finished,
              date >= finished,
              date.timeIntervalSince(finished) <=
                Double(policy.maximumAgeSeconds),
              !policy.requireReproducible ||
                envelope.statement.reproducibility.status ==
                    .verified else {
            throw ImageProvenanceError.policyRejected
        }
        let observedKeySHA = try envelope.verify(
            publicKeyData: publicKey
        )
        guard observedKeySHA == expectedKeySHA else {
            throw ImageProvenanceError.signatureInvalid
        }
        return ImageProvenanceVerification(
            statement: envelope.statement,
            envelopeDigest: envelope.envelopeDigest,
            signerID: envelope.signerID,
            signerPublicKeySHA256: observedKeySHA,
            signatureSHA256:
                imageProvenanceSHA256(envelope.signature),
            policySHA256: material.policySHA256,
            verifiedAt:
                imageProvenanceTimestampString(date)
        )
    }
}

private extension ImageBuildProvenanceRecord {
    static func parseStatementResource(
        _ object: [String: Any]
    ) throws -> ImageProvenanceResource {
        try parseResource(object)
    }

    static func parseStatementCommand(
        _ object: [String: Any]
    ) throws -> ImageProvenanceCommandModel {
        try parseCommand(object)
    }

    static func parseStatementEnvironment(
        _ object: [String: Any]
    ) throws -> ImageProvenanceEnvironmentPolicy {
        try parseEnvironment(object)
    }

    static func parseStatementOutput(
        _ object: [String: Any]
    ) throws -> (name: String, digest: OCIContentDigest) {
        try parseOutput(object)
    }

    static func parseStatementReproducibility(
        _ object: [String: Any]
    ) throws -> ImageProvenanceReproducibility {
        try parseReproducibility(object)
    }
}

private func resourceObject(
    _ resource: ImageProvenanceResource
) -> [String: Any] {
    [
        "uri": resource.uri,
        "digest": resource.digest.canonicalValue
    ]
}

private func imageProvenancePrivateKey(
    _ text: String
) throws -> Curve25519.Signing.PrivateKey {
    let trimmed = text.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let raw: Data
    if trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----") {
        raw = try imageProvenancePEMBody(
            trimmed,
            header: "PRIVATE KEY",
            prefix: Data([
                0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05,
                0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22,
                0x04, 0x20
            ])
        )
    } else if let decoded = Data(
        base64Encoded: trimmed,
        options: []
    ) {
        raw = decoded
    } else {
        throw ImageProvenanceError.invalidPolicy
    }
    guard raw.count == 32 else {
        throw ImageProvenanceError.invalidPolicy
    }
    do {
        return try Curve25519.Signing.PrivateKey(
            rawRepresentation: raw
        )
    } catch {
        throw ImageProvenanceError.invalidPolicy
    }
}

private func imageProvenancePublicKey(
    _ data: Data
) throws -> Curve25519.Signing.PublicKey {
    let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let raw: Data
    if let text,
       text.hasPrefix("-----BEGIN PUBLIC KEY-----") {
        raw = try imageProvenancePEMBody(
            text,
            header: "PUBLIC KEY",
            prefix: Data([
                0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b,
                0x65, 0x70, 0x03, 0x21, 0x00
            ])
        )
    } else if let text,
              let decoded = Data(
                  base64Encoded: text,
                  options: []
              ) {
        raw = decoded
    } else if data.count == 32 {
        raw = data
    } else {
        throw ImageProvenanceError.invalidPolicy
    }
    guard raw.count == 32 else {
        throw ImageProvenanceError.invalidPolicy
    }
    do {
        return try Curve25519.Signing.PublicKey(
            rawRepresentation: raw
        )
    } catch {
        throw ImageProvenanceError.invalidPolicy
    }
}

private func imageProvenancePEMBody(
    _ text: String,
    header: String,
    prefix: Data
) throws -> Data {
    let begin = "-----BEGIN \(header)-----"
    let end = "-----END \(header)-----"
    guard text.hasPrefix(begin),
          text.hasSuffix(end) else {
        throw ImageProvenanceError.invalidPolicy
    }
    let body = text
        .dropFirst(begin.count)
        .dropLast(end.count)
        .filter { !$0.isWhitespace }
    guard let der = Data(base64Encoded: String(body)),
          der.count == prefix.count + 32,
          der.prefix(prefix.count) == prefix else {
        throw ImageProvenanceError.invalidPolicy
    }
    return Data(der.dropFirst(prefix.count))
}

private func imageProvenanceURI(_ value: String) -> Bool {
    guard imageProvenanceString(value, maximumBytes: 512),
          !value.contains(".."),
          !value.contains("@"),
          !value.contains("?"),
          !value.contains("#") else {
        return false
    }
    if value.hasPrefix("urn:") {
        return value.utf8.count > 4
    }
    guard let components = URLComponents(string: value),
          components.scheme == "https",
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil else {
        return false
    }
    return true
}

private func imageProvenanceIdentifier(_ value: String) -> Bool {
    value.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
        options: .regularExpression
    ) != nil
}

private func imageProvenanceTarget(_ value: String) -> Bool {
    value.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$",
        options: .regularExpression
    ) != nil &&
        !value.contains("..") &&
        !value.hasPrefix("/")
}

private func imageProvenanceEnvironmentName(
    _ value: String
) -> Bool {
    value.range(
        of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$",
        options: .regularExpression
    ) != nil
}

private func imageProvenanceString(
    _ value: String,
    maximumBytes: Int
) -> Bool {
    !value.isEmpty &&
        value.utf8.count <= maximumBytes &&
        value.trimmingCharacters(in: .whitespacesAndNewlines) ==
            value &&
        !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
}

private func imageProvenanceTimestamp(
    _ value: String
) -> Date? {
    let exact = ISO8601DateFormatter()
    exact.formatOptions = [.withInternetDateTime]
    if let date = exact.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [
        .withInternetDateTime, .withFractionalSeconds
    ]
    return fractional.date(from: value)
}

private func imageProvenanceTimestampString(
    _ date: Date
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
        .withInternetDateTime, .withFractionalSeconds
    ]
    return formatter.string(from: date)
}

private func imageProvenanceJSONSHA256(
    _ object: Any
) throws -> String {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw ImageProvenanceError.invalidStatement
    }
    return imageProvenanceSHA256(
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    )
}

private func imageProvenanceSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}
