import CryptoKit
import Foundation

public enum HostwrightResourceUUID {
    public static func generate() -> String {
        UUID().uuidString.lowercased()
    }

    public static func legacy(kind: String, identifier: String) -> String {
        let input = Data("hostwright:resource:v1:\(kind):\(identifier)".utf8)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    public static func isValid(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}
