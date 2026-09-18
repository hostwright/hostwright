import Foundation

extension SQLiteStateStore {
    public func verifyIdentityBootstrapContinuity(
        keyStore: any AuditSigningKeyStoring,
        requireEmptyAuthority: Bool = false
    ) throws {
        try configuration.validateExistingPath()
        let head = try keyStore.loadHead()
        let key = try keyStore.configuredActiveKey()
        guard FileManager.default.fileExists(atPath: path) else {
            guard head == nil, key == nil else { throw AuditTrailError.anchorMismatch }
            return
        }
        let version = try schemaVersion()
        let established = try controlIdentities.hasEstablishedIdentityAuthority()
        if requireEmptyAuthority {
            guard !established, head == nil, key == nil else {
                throw StateStoreError.invalidRecord("Automatic owner preparation requires empty database and external audit authority.")
            }
        }
        if version < 19 {
            guard !established, head == nil, key == nil else { throw AuditTrailError.anchorMismatch }
        } else {
            let report = TamperEvidentAuditTrail(store: self, keyStore: keyStore).verify()
            guard report.health == .healthy else {
                throw AuditTrailError.chainCorrupt("Identity bootstrap audit preflight failed: " + report.findings.joined(separator: "; "))
            }
        }
        guard try keyStore.loadHead() == head, try keyStore.configuredActiveKey() == key else {
            throw AuditTrailError.anchorMismatch
        }
    }
}
