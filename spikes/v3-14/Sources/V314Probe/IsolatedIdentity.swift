import Foundation
import Security

struct SpikeIdentity {
    let identity: SecIdentity
    let certificate: SecCertificate
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

final class IsolatedKeychain {
    private let root: URL
    private let keychain: SecKeychain

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-v314-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var opened: SecKeychain?
        let password = Data(UUID().uuidString.utf8)
        let status = directory.appendingPathComponent("probe.keychain-db").path.withCString { path in
            password.withUnsafeBytes { bytes in
                SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &opened)
            }
        }
        guard status == errSecSuccess, let opened else {
            try? FileManager.default.removeItem(at: directory)
            throw ProbeFailure("Could not create isolated keychain (OSStatus \(status))")
        }
        let unlocked = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(opened, UInt32(bytes.count), bytes.baseAddress, true)
        }
        guard unlocked == errSecSuccess else {
            _ = SecKeychainDelete(opened)
            try? FileManager.default.removeItem(at: directory)
            throw ProbeFailure("Could not unlock isolated keychain (OSStatus \(unlocked))")
        }
        root = directory
        keychain = opened
    }

    deinit {
        _ = SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: root)
    }

    func identity(named name: String) throws -> SpikeIdentity {
        let privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrIsSensitive: true,
            kSecAttrIsExtractable: false,
            kSecAttrLabel: name,
        ]
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsSensitive: true,
            kSecAttrIsExtractable: false,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ProbeFailure("Could not create isolated private key (\(error?.takeRetainedValue().localizedDescription ?? "unknown error"))")
        }
        let certificate = try FixtureCertificate.make(named: name, key: key)
        let add = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecUseKeychain: keychain,
        ] as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw ProbeFailure("Could not add test certificate to isolated keychain (OSStatus \(add))")
        }
        var result: SecIdentity?
        let lookup = SecIdentityCreateWithCertificate(keychain, certificate, &result)
        guard lookup == errSecSuccess, let result else {
            throw ProbeFailure("Could not resolve test identity in isolated keychain (OSStatus \(lookup))")
        }
        var storedKey: SecKey?
        let copy = SecIdentityCopyPrivateKey(result, &storedKey)
        guard copy == errSecSuccess, let storedKey,
              let keyAttributes = SecKeyCopyAttributes(storedKey) as NSDictionary?,
              (keyAttributes[kSecAttrIsPermanent] as? NSNumber)?.boolValue == true,
              (keyAttributes[kSecAttrIsExtractable] as? NSNumber)?.boolValue == false,
              SecKeyCopyExternalRepresentation(storedKey, nil) == nil else {
            throw ProbeFailure("The fixture identity did not use a permanent non-exportable private key")
        }
        return SpikeIdentity(identity: result, certificate: certificate)
    }
}

// The self-signed certificates are ephemeral fixtures and their exact DER is pinned by each peer.
private enum FixtureCertificate {
    private static let p256PublicKey = sequence([
        oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
        oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
    ])
    private static let ecdsaSHA256 = sequence([oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])])

    static func make(named name: String, key: SecKey) throws -> SecCertificate {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            throw ProbeFailure("Could not read the test public key")
        }
        let commonName = sequence([
            field(0x31, sequence([oid([0x55, 0x04, 0x03]), field(0x0c, Data(name.utf8))]))
        ])
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let validity = sequence([
            field(0x17, Data(formatter.string(from: now.addingTimeInterval(-60)).utf8)),
            field(0x17, Data(formatter.string(from: now.addingTimeInterval(86_400)).utf8)),
        ])
        let usages = sequence([
            oid([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]), // serverAuth
            oid([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]), // clientAuth
        ])
        let extensions = sequence([
            sequence([oid([0x55, 0x1d, 0x13]), field(0x04, sequence([]))]), // basicConstraints
            sequence([oid([0x55, 0x1d, 0x0f]), field(0x04, field(0x03, Data([7, 0x80])))]), // digitalSignature
            sequence([oid([0x55, 0x1d, 0x25]), field(0x04, usages)]), // extendedKeyUsage
        ])
        let serial = Data([1]) + withUnsafeBytes(of: UUID().uuid) { Data($0) }
        let tbs = sequence([
            field(0xa0, field(0x02, Data([2]))),
            field(0x02, serial),
            ecdsaSHA256,
            commonName,
            validity,
            commonName,
            sequence([p256PublicKey, signatureBits(publicBytes as Data)]),
            field(0xa3, extensions),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error),
              let certificate = SecCertificateCreateWithData(
                nil, sequence([tbs, ecdsaSHA256, signatureBits(signature as Data)]) as CFData
              ) else {
            throw ProbeFailure("Could not sign the fixture certificate (\(error?.takeRetainedValue().localizedDescription ?? "invalid DER"))")
        }
        return certificate
    }

    private static func signatureBits(_ data: Data) -> Data { field(0x03, Data([0]) + data) }
    private static func sequence(_ fields: [Data]) -> Data { field(0x30, fields.reduce(into: Data(), +=)) }
    private static func oid(_ data: [UInt8]) -> Data { field(0x06, Data(data)) }

    private static func field(_ type: UInt8, _ body: Data) -> Data {
        if body.count < 128 {
            return Data([type, UInt8(body.count)]) + body
        }
        let length = withUnsafeBytes(of: UInt64(body.count).bigEndian) { Array($0.drop(while: { $0 == 0 })) }
        return Data([type, 0x80 | UInt8(length.count)] + length) + body
    }
}
