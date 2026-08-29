import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

public enum CLIControlStreamPreparationContract {
    public static let operation = "cli.stream.prepare"
    public static let schemaVersion = 1

    public static func request(
        route: CLIControlRoute,
        requestID: String
    ) -> ControlRequestEnvelope {
        ControlRequestEnvelope(
            requestID: requestID,
            operation: operation,
            timeoutMilliseconds: 30_000,
            body: route.requestBody()
        )
    }
}

public struct CLIControlStreamPreparation: Codable, Equatable, Sendable {
    public static let schemaVersion = CLIControlStreamPreparationContract.schemaVersion
    public static let maximumTimeoutMilliseconds = 86_400_000
    public let schemaVersion: Int
    public let source: ControlStreamSource
    public let target: String?
    public let filter: ControlPlaneJSONValue?
    public let cursor: String?
    public let timeoutMilliseconds: Int
    public let output: String

    public init(
        source: ControlStreamSource,
        target: String?,
        filter: ControlPlaneJSONValue?,
        cursor: String?,
        timeoutMilliseconds: Int,
        output: CLIOutputFormat
    ) throws {
        guard (1...Self.maximumTimeoutMilliseconds)
                .contains(timeoutMilliseconds) else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI stream timeout is outside the supported bound."
            )
        }
        self.schemaVersion = Self.schemaVersion
        self.source = source
        self.target = target
        self.filter = filter
        self.cursor = cursor
        self.timeoutMilliseconds = timeoutMilliseconds
        self.output = output.rawValue
    }

    public static func decode(_ response: ControlResponseEnvelope) throws -> Self {
        guard response.status == .completed,
              response.reasonCode == .completed,
              let result = response.result else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The daemon rejected CLI stream preparation."
            )
        }
        let data = try ControlPlaneCanonicalJSON.encode(result)
        let value = try Phase09StrictDecoder.decode(
            Self.self,
            from: data,
            allowedKeys: [
                "cursor", "filter", "output", "schemaVersion", "source", "target",
                "timeoutMilliseconds",
            ],
            requiredKeys: ["output", "schemaVersion", "source", "timeoutMilliseconds"]
        )
        guard value.schemaVersion == schemaVersion,
              CLIOutputFormat(rawValue: value.output) != nil,
              (1...Self.maximumTimeoutMilliseconds)
                .contains(value.timeoutMilliseconds) else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The daemon returned an invalid CLI stream preparation."
            )
        }
        return value
    }

    public var outputFormat: CLIOutputFormat {
        CLIOutputFormat(rawValue: output)!
    }
}
