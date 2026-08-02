import XCTest

@testable import HostwrightControlPlane

final class ControlPlaneContractTests: XCTestCase {
  private let decoder: JSONDecoder = {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .iso8601
    return value
  }()
  private let encoder: JSONEncoder = {
    let value = JSONEncoder()
    value.dateEncodingStrategy = .iso8601
    return value
  }()
  private var contracts: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("contracts/v0.0.2")
  }

  func testFrozenVersionsAndLimits() throws {
    XCTAssertEqual(ControlPlaneContract.apiVersion, 2)
    XCTAssertEqual(ControlProtocolRevision.allCases.map(\.rawValue), ["2.0", "2.1"])
    XCTAssertEqual(
      [
        ControlPlaneContract.maximumRequestBytes, ControlPlaneContract.maximumResponseOrFrameBytes,
        ControlPlaneContract.maximumStreams, ControlPlaneContract.maximumOutstandingUnary,
        ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
      ], [65_536, 1_048_576, 32, 64, 300_000])
    XCTAssertEqual(
      [
        WASILimits.default.moduleBytes, WASILimits.default.inputBytes,
        WASILimits.default.outputBytes, WASILimits.default.memoryBytes,
        WASILimits.default.normalExecutionMilliseconds,
        WASILimits.default.absoluteExecutionMilliseconds,
      ], [16_777_216, 1_048_576, 1_048_576, 67_108_864, 5_000, 30_000])
    XCTAssertThrowsError(try ControlPlaneContract.validateRequestByteCount(65_537))
    XCTAssertThrowsError(try ControlPlaneContract.validateRequestByteCount(0))
    XCTAssertThrowsError(try ControlPlaneContract.validateResponseOrFrameByteCount(1_048_577))
    XCTAssertThrowsError(try ControlPlaneContract.validateResponseOrFrameByteCount(0))
    XCTAssertThrowsError(try ControlSessionLimits(streams: 33, outstandingUnary: 64).validate())
    XCTAssertEqual(ControlFramingContract.transport, "SOCK_STREAM")
    XCTAssertEqual(ControlFramingContract.lengthPrefixBytes, 4)
    XCTAssertEqual(ControlFramingContract.lengthByteOrder, "unsigned-big-endian")
    XCTAssertThrowsError(try ControlFramingContract.validateDeclaredLength(65_537, kind: .request))
    XCTAssertThrowsError(try ControlFramingContract.validateDeclaredLength(0, kind: .request))
    XCTAssertNoThrow(try ControlFramingContract.validateDeclaredLength(1_048_576, kind: .frame))
    let canonical = try ControlPlaneCanonicalJSON.encode(
      ControlPlaneJSONValue.object([
        "url": .string("/a/b"), "integer": .integer(1), "float": .number(1.5),
      ]))
    XCTAssertEqual(
      String(decoding: canonical, as: UTF8.self), "{\"float\":1.5,\"integer\":1,\"url\":\"/a/b\"}")
  }

  func testClientEnvelopeHasNoIdentityAndLegacyRevisionCompatibility() throws {
    let request = ControlRequestEnvelope(
      requestID: "r", operation: "plan", timeoutMilliseconds: 1,
      body: .object(["integer": .integer(2), "decimal": .number(2.5)]))
    try request.validate()
    XCTAssertEqual(try roundTrip(request), request)
    let legacy = ControlRequestEnvelope(protocolRevision: nil, requestID: "r", operation: "plan")
    try legacy.validate()
    XCTAssertNil(legacy.protocolRevision)
    XCTAssertThrowsError(
      try ControlRequestEnvelope(
        protocolRevision: nil, requestID: "r", operation: "plan", timeoutMilliseconds: 1
      ).validate())
    XCTAssertThrowsError(
      try ControlRequestEnvelope(
        protocolRevision: nil, requestID: "r", operation: "plan", body: .object([:])
      ).validate())
    XCTAssertThrowsError(
      try ControlRequestEnvelope(
        apiVersion: 3, requestID: "r", operation: "plan", timeoutMilliseconds: 1
      ).validate())
    XCTAssertThrowsError(
      try ControlRequestEnvelope(requestID: "r", operation: "plan", timeoutMilliseconds: 300_001)
        .validate())
    XCTAssertThrowsError(
      try ControlRequestEnvelope(
        requestID: "r", operation: "plan", timeoutMilliseconds: 1, idempotencyKey: ""
      ).validate())
  }

  func testResponseAndStreamConsistency() throws {
    XCTAssertEqual(ControlResponseStatus.allCases, [.accepted, .completed, .rejected, .error])
    XCTAssertNoThrow(
      try ControlResponseEnvelope(requestID: "r", status: .completed, reasonCode: .completed)
        .validate())
    XCTAssertThrowsError(
      try ControlResponseEnvelope(requestID: "r", status: .error, reasonCode: .internalError)
        .validate())
    XCTAssertThrowsError(try StreamFrame(streamID: "s", sequence: 0, kind: .data).validate())
    XCTAssertThrowsError(
      try StreamFrame(streamID: "s", sequence: 1, kind: .ack, credit: -1).validate())
    XCTAssertThrowsError(try StreamFrame(streamID: "s", sequence: 1, kind: .error).validate())
    XCTAssertNoThrow(
      try StreamFrame(
        streamID: "s", sequence: 1, kind: .error,
        error: SanitizedError(code: "bad", message: "safe")
      ).validate())
  }

  func testIdentityAndSessionBindingCrossChecksUID() throws {
    let hash = String(repeating: "a", count: 64)
    let code = CodeIdentity(
      teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
      codeDirectoryHash: hash, validationMode: .installedRequirement)
    let subject = LocalSubject(identifier: "u", userID: 501, codeIdentityHash: hash)
    let peer = UnixPeerIdentity(
      effectiveUID: 501, effectiveGID: 20, pid: 1, pidVersion: 1, auditSessionID: 1,
      codeIdentity: code)
    XCTAssertNoThrow(
      try ControlSessionBinding(
        sessionID: "s", daemonGeneration: 1, serverNonce: "n", socketDevice: 1, socketInode: 1,
        peer: peer, subject: subject
      ).validate())
    XCTAssertThrowsError(
      try ControlSessionBinding(
        sessionID: "s", daemonGeneration: 1, serverNonce: "n", socketDevice: 1, socketInode: 1,
        peer: peer, subject: LocalSubject(identifier: "u", userID: 502, codeIdentityHash: hash)
      ).validate())
    XCTAssertEqual(CodeValidationMode.allCases, [.installedRequirement, .pinnedAdHoc])
  }

  func testRBACScopesRolesAndAdmissionRules() throws {
    XCTAssertEqual(RBACResource.secretMetadata.rawValue, "secret-metadata")
    XCTAssertEqual(DefaultRole.securityAdmin.rawValue, "security-admin")
    XCTAssertThrowsError(try RBACScope(kind: .global, identifier: "x").validate())
    XCTAssertThrowsError(try RBACScope(kind: .project).validate())
    let rule = RBACRule(
      identifier: "read", effect: .allow, resources: [.project], verbs: [.get],
      scope: RBACScope(kind: .project, identifier: "p"))
    XCTAssertNoThrow(
      try RoleDefinition(identifier: "viewer", builtIn: true, rules: [rule]).validate())
    XCTAssertThrowsError(
      try AdmissionMutation(
        policyIdentifier: "p", stage: .canonicalize, fieldPath: "/x", value: .null
      ).validate())
    XCTAssertEqual(
      DefaultRolePolicy.matrix.map(\.role),
      [.viewer, .operator, .maintainer, .securityAdmin, .owner])
    XCTAssertTrue(DefaultRolePolicy.denyOverridesAllow)
    XCTAssertTrue(DefaultRolePolicy.conditionsCombineWithANDOnly)
    XCTAssertTrue(DefaultRolePolicy.builtInRolesImmutable)
    XCTAssertEqual(
      try decoder.decode(
        [DefaultRolePermission].self,
        from: data("phase09-default-role-matrix.json")
      ),
      DefaultRolePolicy.matrix
    )
    XCTAssertThrowsError(
      try RBACDelegation(
        identifier: "d", delegator: "a", delegate: "b", roleIdentifiers: ["owner"],
        delegatedRules: [], scope: RBACScope(kind: .global), expiresAt: Date()
      ).validate())
    XCTAssertEqual(
      AdmissionStage.allCases,
      [
        .authenticate, .authorizeRequestedIntent, .canonicalize, .builtInMutation,
        .extensionMutation, .conflictDetection, .builtInValidation, .extensionValidation,
        .authorizeEffectiveIntent, .bindApproval, .persistRequestOperationAudit, .acknowledge,
      ])
  }

  func testAuditAndMigrationContracts() throws {
    XCTAssertEqual(
      StateMigrationPlan.phase09,
      [
        .init(version: 18, stage: .identity), .init(version: 19, stage: .audit),
        .init(version: 20, stage: .policyProfile), .init(version: 21, stage: .plugin),
      ])
    XCTAssertEqual(
      try decoder.decode(
        [StateMigrationEdge].self, from: data("phase09-migration-plan-v18-v21.json")),
      StateMigrationPlan.phase09Edges)
    let data = try Data(contentsOf: contracts.appendingPathComponent("phase09-audit-v2.1.json"))
    let audit = try strict(
      AuditRecord.self, data,
      [
        "schemaVersion", "identifier", "segmentID", "sequence", "timestamp", "subjectID", "action",
        "outcome", "reasonCode", "payloadDigest", "recordDigest", "signingKeyID",
      ])
    try audit.validate()
    XCTAssertEqual(try roundTrip(audit), audit)
    let digest = "sha256:" + String(repeating: "a", count: 64)
    XCTAssertThrowsError(
      try AuditRecord(
        identifier: "second", segmentID: "segment", sequence: 2, timestamp: Date(),
        subjectID: "subject", action: .request, outcome: "accepted", reasonCode: "accepted",
        payloadDigest: digest, recordDigest: digest, signingKeyID: "key"
      ).validate())
    XCTAssertThrowsError(
      try AuditRecord(
        identifier: "first", segmentID: "segment", sequence: 1, timestamp: Date(),
        previousDigest: digest, subjectID: "subject", action: .request, outcome: "accepted",
        reasonCode: "accepted", payloadDigest: digest, recordDigest: digest, signingKeyID: "key"
      ).validate())
    XCTAssertThrowsError(
      try AuditSegmentSeal(
        segmentID: "segment", firstSequence: 1, lastSequence: 3, recordCount: 2,
        sha256Digest: digest, p256Signature: "signature", keyID: "key"
      ).validate())
    XCTAssertEqual(
      AuditAction.allCases,
      [
        .request, .authentication, .authorization, .admission, .operation, .effect, .recovery,
        .plugin, .admin, .export, .retention,
      ])
  }

  func testTypedProfileAndPluginContracts() throws {
    let profile = try strict(
      WorkloadProfile.self, data("phase09-profile-v1.json"),
      Set([
        "version", "identifier", "filesystem", "network", "resources", "identity", "secrets",
        "images", "runtime", "hostAccess", "observability", "accelerators", "syscalls",
        "extensionGrants",
      ]))
    try profile.validate()
    XCTAssertEqual(try roundTrip(profile), profile)
    let manifest = try strict(
      PluginPackageManifest.self, data("phase09-plugin-v1.json"),
      [
        "abiVersion", "identifier", "packageVersion", "hostwrightCompatibility", "providerKind",
        "entrypoint", "grants", "artifactDigest", "contentDigests", "provenance", "cmsSignature",
        "signerIdentifier",
      ])
    try manifest.validate()
    XCTAssertEqual(try roundTrip(manifest), manifest)
    XCTAssertEqual(WASISandboxContract.preopens, [])
    XCTAssertFalse(WASISandboxContract.ambientNetwork)
    XCTAssertTrue(WASISandboxContract.freshInstancePerInvocation)
    let invocation = try strict(
      PluginInvocation.self, data("phase09-plugin-invocation-v1.json"),
      ["invocationID", "pluginIdentifier", "capability", "timestamp", "seed", "input", "limits"])
    try invocation.validate()
    XCTAssertEqual(try roundTrip(invocation), invocation)
    XCTAssertEqual(
      PluginLifecycleState.allCases,
      [.discovered, .verified, .staged, .active, .rollback, .quarantined, .revoked, .uninstalled])
  }

  func testXPCProtocolAndExactEntitlement() throws {
    XCTAssertEqual(
      XPCServiceContract.requiredEntitlements, ["com.apple.security.app-sandbox": .bool(true)])
    XCTAssertThrowsError(try XPCServiceContract(entitlements: ["extra": .bool(true)]).validate())
    let request = try strict(
      XPCRequest.self, data("phase09-xpc-v1.json"),
      ["protocolVersion", "kind", "requestID", "operation", "timeoutMilliseconds"])
    try request.validate()
    XCTAssertEqual(request.protocolVersion, 1)
    XCTAssertEqual(try roundTrip(request), request)
    XCTAssertNoThrow(try XPCRequest(kind: .cancel, requestID: "x", operation: nil).validate())
    XCTAssertThrowsError(try XPCRequest(requestID: "x", timeoutMilliseconds: 5_001).validate())
    let proof = CodeIdentityProof(
      signingIdentifier: XPCServiceContract.serviceIdentifier,
      codeDirectoryHash: String(repeating: "a", count: 64))
    XCTAssertNoThrow(
      try XPCResponse(requestID: "x", status: .completed, proof: proof).validate())
    XCTAssertNoThrow(try XPCResponse(requestID: "x", status: .cancelled).validate())
    XCTAssertNoThrow(
      try XPCResponse(
        requestID: "x", status: .error, error: SanitizedError(code: "failed", message: "safe")
      ).validate())
    XCTAssertThrowsError(try XPCResponse(requestID: "x", status: .completed).validate())
  }

  func testEveryGoldenStrictlyDecodesAndRejectsUnknownFields() throws {
    let request = try strict(
      ControlRequestEnvelope.self, data("phase09-control-request-v2.1.json"),
      [
        "apiVersion", "protocolRevision", "requestID", "operation", "timeoutMilliseconds",
        "idempotencyKey", "body",
      ])
    try request.validate()
    XCTAssertEqual(try roundTrip(request), request)
    let legacyData = try Data(
      contentsOf: contracts.appendingPathComponent("control-plan-request.json"))
    let legacy = try strict(
      ControlRequestEnvelope.self, legacyData, ["apiVersion", "requestID", "operation"])
    try legacy.validate()
    XCTAssertNil(legacy.protocolRevision)
    XCTAssertEqual(try roundTrip(legacy), legacy)
    let legacyResponseData = try Data(
      contentsOf: contracts.appendingPathComponent("control-plan-response.json"))
    let legacyResponse = try strict(
      LegacyControlResponse.self, legacyResponseData,
      ["apiVersion", "requestID", "operation", "success", "exitCode", "result"])
    XCTAssertEqual(legacyResponse.requestID, "golden-plan-1")
    XCTAssertTrue(legacyResponse.success)
    let response = try strict(
      ControlResponseEnvelope.self, data("phase09-control-response-v2.1.json"),
      ["apiVersion", "protocolRevision", "requestID", "status", "reasonCode", "result"])
    try response.validate()
    XCTAssertEqual(try roundTrip(response), response)
    let frame = try strict(
      StreamFrame.self, data("phase09-stream-frame-v2.1.json"),
      [
        "apiVersion", "protocolRevision", "streamID", "sequence", "cursor", "kind", "credit",
        "payload",
      ])
    try frame.validate()
    let encodedFrame = try encoder.encode(frame)
    XCTAssertEqual(try decoder.decode(StreamFrame.self, from: encodedFrame), frame)
    let rule = try strict(
      RBACRule.self, data("phase09-rbac-v2.1.json"),
      ["identifier", "effect", "resources", "verbs", "scope", "conditions"])
    try rule.validate()
    XCTAssertEqual(try roundTrip(rule), rule)
    let admission = try strict(
      AdmissionDecision.self, data("phase09-admission-v2.1.json"),
      [
        "policyIdentifier", "stage", "allowed", "failurePolicy", "reasonCode", "mutations",
        "advisory",
      ])
    try admission.validate()
    XCTAssertEqual(try roundTrip(admission), admission)
    XCTAssertThrowsError(
      try strict(
        ControlRequestEnvelope.self,
        Data(
          "{\"apiVersion\":2,\"requestID\":\"r\",\"operation\":\"x\",\"timeoutMilliseconds\":1,\"unknown\":true}"
            .utf8), ["apiVersion", "requestID", "operation", "timeoutMilliseconds"]))
    XCTAssertThrowsError(
      try strict(
        ControlRequestEnvelope.self,
        Data("{\"apiVersion\":2,\"apiVersion\":2,\"requestID\":\"r\",\"operation\":\"x\"}".utf8),
        ["apiVersion", "requestID", "operation"]))
    XCTAssertThrowsError(
      try strict(
        ControlRequestEnvelope.self,
        Data(
          "{\"apiVersion\":2,\"\\u0061piVersion\":2,\"requestID\":\"r\",\"operation\":\"x\"}".utf8),
        ["apiVersion", "requestID", "operation"]))
    XCTAssertThrowsError(
      try strict(
        ControlRequestEnvelope.self, Data("{\"requestID\":\"r\",\"operation\":\"x\"}".utf8),
        ["apiVersion", "requestID", "operation"]))
    XCTAssertThrowsError(
      try strict(
        ControlRequestEnvelope.self,
        Data(
          "{\"apiVersion\":2,\"protocolRevision\":\"9.0\",\"requestID\":\"r\",\"operation\":\"x\",\"timeoutMilliseconds\":1}"
            .utf8),
        ["apiVersion", "protocolRevision", "requestID", "operation", "timeoutMilliseconds"]))
  }

  func testFrozenCLIParityInventory() throws {
    let inventory =
      try JSONSerialization.jsonObject(with: data("phase09-cli-parity-inventory.json"))
      as? [[String: String]] ?? []
    let commands = inventory.map { $0["command"]! }
    XCTAssertEqual(
      commands,
      [
        "version", "help", "capabilities", "observability", "runtime", "paths", "state", "secret",
        "registry", "image", "volume", "daemon.status", "daemon.install", "daemon.validate",
        "daemon.bootstrap", "daemon.start", "daemon.stop", "daemon.kickstart", "daemon.upgrade",
        "daemon.rollback", "daemon.disable", "daemon.repair", "daemon.uninstall", "restart-budget",
        "maintenance", "ownership", "metrics", "traces", "migrate", "init", "import-stack",
        "validate", "plan", "status", "apply", "up", "down", "run", "start", "stop", "restart",
        "rm", "update", "exec", "attach", "copy", "export", "inspect", "stats", "logs", "events",
        "recovery", "cleanup", "diagnostics", "benchmark", "extension", "doctor",
      ])
    XCTAssertEqual(
      inventory.filter { $0["transport"] == "local-presentation" }.map { $0["command"]! },
      ["version", "help"])
    XCTAssertEqual(
      inventory.filter { $0["transport"] == "bootstrap-api" }.map { $0["command"]! },
      ["daemon.install", "daemon.repair", "daemon.uninstall"])
    XCTAssertTrue(inventory.filter { $0["transport"] == "persistent-control-api" }.count > 40)
  }

  private func data(_ file: String) throws -> Data {
    try Data(contentsOf: contracts.appendingPathComponent(file))
  }
  private func strict<T: Decodable>(_ type: T.Type, _ data: Data, _ keys: Set<String>) throws -> T {
    try Phase09StrictDecoder.decode(
      type, from: data, allowedKeys: keys, requiredKeys: keys, decoder: decoder)
  }
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try decoder.decode(T.self, from: encoder.encode(value))
  }
}
