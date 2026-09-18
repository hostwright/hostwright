import Foundation
import XCTest
import _CryptoExtras

final class CryptoPublicKeyParsingRegressionTests: XCTestCase {
    func testMalformedDERPublicKeyThrowsWithoutDoubleFree() throws {
        let malformedDER = try XCTUnwrap(Data(base64Encoded: "MAYCAQACAQ=="))
        XCTAssertThrowsError(try _RSA.Signing.PublicKey(derRepresentation: malformedDER))
    }

    func testMalformedPEMPublicKeyThrowsWithoutDoubleFree() {
        let malformedPEM = """
        -----BEGIN PUBLIC KEY-----
        MAYCAQACAQ==
        -----END PUBLIC KEY-----
        """
        XCTAssertThrowsError(try _RSA.Signing.PublicKey(pemRepresentation: malformedPEM))
    }
}
