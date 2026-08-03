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
        ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds,
      ], [65_536, 1_048_576, 32, 64, 300_000, 5_000])
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

  func testAuthenticationHandshakeIsCanonicalStrictAndProofBound() throws {
    let hash = String(repeating: "a", count: 40)
    let peer = UnixPeerIdentity(
      effectiveUID: 501, effectiveGID: 20, pid: 42, pidVersion: 7, auditSessionID: 9,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: hash, validationMode: .installedRequirement
      )
    )
    let challenge = ControlPeerCredentialChallenge(
      subjectID: "owner", serverNonce: "MDEyMzQ1Njc4OWFiY2RlZg==", daemonGeneration: 2,
      socketDevice: 3, socketInode: 5, peer: peer, credentialProofRequired: true
    )
    let challengeData = try challenge.canonicalData()
    XCTAssertLessThanOrEqual(challengeData.count, ControlPlaneContract.maximumResponseOrFrameBytes)
    XCTAssertEqual(try ControlAuthenticationWireContract.decodeChallenge(challengeData), challenge)
    let unpersistableGeneration = ControlPeerCredentialChallenge(
      subjectID: "owner", serverNonce: "MDEyMzQ1Njc4OWFiY2RlZg==",
      daemonGeneration: UInt64.max,
      socketDevice: 3, socketInode: 5, peer: peer, credentialProofRequired: true
    )
    XCTAssertThrowsError(try unpersistableGeneration.canonicalData())

    let proof = ControlPeerCredentialProof(
      credentialID: "owner-key",
      signatureDERBase64:
        "MEUCIQCJEZNLJFhnUeauqx63oJcbAK7DvW/1J3E/S3vGBpgMsgIgFX5SLGa03gkrRzSSf6R4IUj2P8u5TTohLGdBhvsUQT4="
    )
    let response = ControlAuthenticationResponse(credentialProof: proof)
    let responseData = try ControlPlaneCanonicalJSON.encode(response)
    XCTAssertLessThanOrEqual(responseData.count, ControlPlaneContract.maximumRequestBytes)
    XCTAssertEqual(
      try ControlAuthenticationWireContract.decodeResponse(responseData, for: challenge),
      response
    )
    XCTAssertThrowsError(
      try ControlAuthenticationResponse().validate(for: challenge)
    )

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    )
    object["unexpected"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(unknown, for: challenge)
    )
  }

  func testAuthenticationWireProofRequirementIsSymmetricAndRejectsPartialProof() throws {
    let required = authenticationChallenge(proofRequired: true)
    let optional = authenticationChallenge(proofRequired: false)
    let proof = authenticationProof()
    let encodedProof = try ControlPlaneCanonicalJSON.encode(
      ControlAuthenticationResponse(credentialProof: proof))
    let encodedAbsent = try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse())

    XCTAssertEqual(
      try ControlAuthenticationWireContract.decodeResponse(encodedProof, for: required),
      ControlAuthenticationResponse(credentialProof: proof))
    XCTAssertEqual(
      try ControlAuthenticationWireContract.decodeResponse(encodedAbsent, for: optional),
      ControlAuthenticationResponse())
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(encodedAbsent, for: required))
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(encodedProof, for: optional))

    for partial in [
      "{\"apiVersion\":2,\"protocolRevision\":\"2.1\",\"kind\":\"authentication-response\",\"credentialID\":\"owner-key\"}",
      "{\"apiVersion\":2,\"protocolRevision\":\"2.1\",\"kind\":\"authentication-response\",\"signatureDERBase64\":\"AQEBAQEBAQE=\"}",
    ] {
      XCTAssertThrowsError(
        try ControlAuthenticationWireContract.decodeResponse(Data(partial.utf8), for: required))
      XCTAssertThrowsError(
        try ControlAuthenticationWireContract.decodeResponse(Data(partial.utf8), for: optional))
    }
  }

  func testAuthenticationWireRejectsUnknownDuplicateAndMissingFields() throws {
    let challenge = authenticationChallenge(proofRequired: true)
    let challengeData = try challenge.canonicalData()
    let responseData = try ControlPlaneCanonicalJSON.encode(
      ControlAuthenticationResponse(credentialProof: authenticationProof()))

    var unknownChallenge = try XCTUnwrap(
      JSONSerialization.jsonObject(with: challengeData) as? [String: Any])
    unknownChallenge["unexpected"] = true
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeChallenge(
        JSONSerialization.data(withJSONObject: unknownChallenge)))

    var unknownResponse = try XCTUnwrap(
      JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    unknownResponse["unexpected"] = true
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(
        JSONSerialization.data(withJSONObject: unknownResponse), for: challenge))

    var missingChallenge = try XCTUnwrap(
      JSONSerialization.jsonObject(with: challengeData) as? [String: Any])
    missingChallenge.removeValue(forKey: "peerPID")
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeChallenge(
        JSONSerialization.data(withJSONObject: missingChallenge)))
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(
        Data("{\"apiVersion\":2,\"protocolRevision\":\"2.1\"}".utf8), for: challenge))

    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeChallenge(
        Data(
          "{\"apiVersion\":2,\"apiVersion\":2,\"protocolRevision\":\"2.1\",\"kind\":\"authentication-challenge\"}"
            .utf8)))
    XCTAssertThrowsError(
      try ControlAuthenticationWireContract.decodeResponse(
        Data(
          "{\"apiVersion\":2,\"protocolRevision\":\"2.1\",\"kind\":\"authentication-response\",\"kind\":\"authentication-response\"}"
            .utf8), for: challenge))
  }

  func testAuthenticationWireRejectsWrongVersionKindNonceHashAndBounds() throws {
    let challenge = authenticationChallenge(proofRequired: true)
    let response = ControlAuthenticationResponse(credentialProof: authenticationProof())
    let challengeData = try challenge.canonicalData()
    let responseData = try ControlPlaneCanonicalJSON.encode(response)

    for mutation: (String, Any) in [
      ("apiVersion", 3),
      ("kind", "authentication-response"),
      ("serverNonce", "not-base64!"),
      ("serverNonce", Data(repeating: 1, count: 15).base64EncodedString()),
      ("codeDirectoryHash", String(repeating: "A", count: 40)),
      ("codeDirectoryHash", String(repeating: "a", count: 41)),
      ("daemonGeneration", 0),
      ("socketDevice", 0),
      ("socketInode", 0),
      ("peerPID", 0),
      ("peerPIDVersion", 0),
      ("peerAuditSessionID", 0),
    ] {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: challengeData) as? [String: Any])
      object[mutation.0] = mutation.1
      XCTAssertThrowsError(
        try ControlAuthenticationWireContract.decodeChallenge(
          JSONSerialization.data(withJSONObject: object)),
        "mutation of \(mutation.0) must be rejected")
    }

    for mutation: (String, Any) in [
      ("apiVersion", 3),
      ("kind", "authentication-challenge"),
      ("credentialID", "invalid credential"),
      ("signatureDERBase64", "not-base64!"),
      ("signatureDERBase64", Data(repeating: 1, count: 7).base64EncodedString()),
    ] {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
      object[mutation.0] = mutation.1
      XCTAssertThrowsError(
        try ControlAuthenticationWireContract.decodeResponse(
          JSONSerialization.data(withJSONObject: object), for: challenge),
        "mutation of \(mutation.0) must be rejected")
    }
  }

  func testAuthenticationWireCanonicalRoundTrips() throws {
    let challenge = authenticationChallenge(proofRequired: true)
    let challengeData = try challenge.canonicalData()
    let decodedChallenge = try ControlAuthenticationWireContract.decodeChallenge(challengeData)
    XCTAssertEqual(decodedChallenge, challenge)
    XCTAssertEqual(try decodedChallenge.canonicalData(), challengeData)

    let response = ControlAuthenticationResponse(credentialProof: authenticationProof())
    let responseData = try ControlPlaneCanonicalJSON.encode(response)
    let decodedResponse = try ControlAuthenticationWireContract.decodeResponse(
      responseData, for: decodedChallenge)
    XCTAssertEqual(decodedResponse, response)
    XCTAssertEqual(try ControlPlaneCanonicalJSON.encode(decodedResponse), responseData)
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
    XCTAssertNoThrow(
      try ControlResponseEnvelope(
        requestID: "r", status: .accepted, reasonCode: .accepted,
        operationRef: "operation:r"
      ).validate())
    XCTAssertThrowsError(
      try ControlResponseEnvelope(requestID: "r", status: .accepted, reasonCode: .accepted)
        .validate())
    XCTAssertThrowsError(
      try ControlResponseEnvelope(
        requestID: "r", status: .accepted, reasonCode: .accepted,
        operationRef: "operation:r", result: .string("transient")
      ).validate())
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
    let hash = String(repeating: "a", count: 40)
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
    XCTAssertNoThrow(
      try CodeIdentity(
        signingIdentifier: "hostwright", codeDirectoryHash: String(repeating: "b", count: 64),
        validationMode: .pinnedAdHoc
      ).validate())
    for invalidLength in [39, 41, 63, 65] {
      XCTAssertThrowsError(
        try CodeIdentity(
          signingIdentifier: "hostwright",
          codeDirectoryHash: String(repeating: "c", count: invalidLength),
          validationMode: .pinnedAdHoc
        ).validate())
    }
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
      codeDirectoryHash: String(repeating: "a", count: 40))
    XCTAssertNoThrow(
      try XPCResponse(requestID: "x", status: .completed, proof: proof).validate())
    XCTAssertNoThrow(try XPCResponse(requestID: "x", status: .cancelled).validate())
    XCTAssertNoThrow(
      try XPCResponse(
        requestID: "x", status: .error, error: SanitizedError(code: "failed", message: "safe")
      ).validate())
    XCTAssertThrowsError(try XPCResponse(requestID: "x", status: .completed).validate())
    XCTAssertNoThrow(
      try CodeIdentityProof(
        signingIdentifier: XPCServiceContract.serviceIdentifier,
        codeDirectoryHash: String(repeating: "b", count: 64)
      ).validate())
    XCTAssertThrowsError(
      try CodeIdentityProof(
        signingIdentifier: XPCServiceContract.serviceIdentifier,
        codeDirectoryHash: String(repeating: "c", count: 41)
      ).validate())
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
    let challenge = try ControlAuthenticationWireContract.decodeChallenge(
      data("phase09-auth-challenge-v2.1.json")
    )
    let authenticationResponse = try ControlAuthenticationWireContract.decodeResponse(
      data("phase09-auth-response-v2.1.json"),
      for: challenge
    )
    XCTAssertNotNil(authenticationResponse.credentialProof)
    let frame = try Phase09StrictDecoder.decode(
      StreamFrame.self,
      from: data("phase09-stream-frame-v2.1.json"),
      allowedKeys: [
        "apiVersion", "protocolRevision", "streamID", "sequence", "cursor", "kind", "credit",
        "payload",
      ],
      requiredKeys: [
        "apiVersion", "protocolRevision", "streamID", "sequence", "cursor", "kind", "payload",
      ],
      decoder: decoder
    )
    try ControlStreamFrameContract.validate(frame, direction: .serverToClient)
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
  private func authenticationChallenge(proofRequired: Bool) -> ControlPeerCredentialChallenge {
    let hash = String(repeating: "a", count: 40)
    return ControlPeerCredentialChallenge(
      subjectID: "owner", serverNonce: "MDEyMzQ1Njc4OWFiY2RlZg==", daemonGeneration: 2,
      socketDevice: 3, socketInode: 5,
      peer: UnixPeerIdentity(
        effectiveUID: 501, effectiveGID: 20, pid: 42, pidVersion: 7, auditSessionID: 9,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
          codeDirectoryHash: hash, validationMode: .installedRequirement)),
      credentialProofRequired: proofRequired)
  }
  private func authenticationProof() -> ControlPeerCredentialProof {
    ControlPeerCredentialProof(
      credentialID: "owner-key",
      signatureDERBase64:
        "MEUCIQCJEZNLJFhnUeauqx63oJcbAK7DvW/1J3E/S3vGBpgMsgIgFX5SLGa03gkrRzSSf6R4IUj2P8u5TTohLGdBhvsUQT4="
    )
  }
}
