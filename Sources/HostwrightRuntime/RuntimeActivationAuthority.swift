public struct RuntimeActivationAuthorityRejection: Error, Equatable, Sendable {
    public let diagnostic: String

    init(_ error: any Error) {
        diagnostic = String(RuntimeRedactionPolicy.default.redact(String(describing: error)).prefix(4_096))
    }
}

public enum RuntimeActivationAuthority {
    @TaskLocal public static var validator: (@Sendable () throws -> Void)?

    public static func validate() throws {
        do {
            try validator?()
        } catch {
            throw RuntimeActivationAuthorityRejection(error)
        }
    }
}
