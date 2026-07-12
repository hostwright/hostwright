import HostwrightCore
import HostwrightPolicy
import XCTest

final class TeamWorkflowPolicyTests: XCTestCase {
    func testStrictProfileIsAcceptedDeterministically() {
        let profile = validProfile(requirements: [.requireManifestReview, .requireImageDigest])

        let first = TeamWorkflowPolicyEvaluator.default.evaluate(profile)
        let second = TeamWorkflowPolicyEvaluator.default.evaluate(profile)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.reasonCode), [.teamRequirementDeclared, .teamRequirementDeclared])
        XCTAssertEqual(first.map(\.subject), ["requireImageDigest", "requireManifestReview"])
        XCTAssertTrue(first.allSatisfy { $0.severity == .allow })
    }

    func testProfileFailsClosedForInvalidIdentityVersionKindOptInAndGates() {
        let profile = TeamPolicyProfile(
            kind: "OtherProfile",
            apiVersion: 2,
            identifier: "INVALID PROFILE",
            displayName: "",
            optIn: false,
            requiredGates: [.runtimeAdapter, .runtimeAdapter],
            requirements: [.requireImageDigest, .requireImageDigest]
        )

        let decisions = TeamWorkflowPolicyEvaluator.default.evaluate(profile)
        let reasonCodes = decisions.map(\.reasonCode)

        XCTAssertTrue(reasonCodes.contains(.teamProfileMissingIdentity))
        XCTAssertTrue(reasonCodes.contains(.teamProfileInvalidKind))
        XCTAssertTrue(reasonCodes.contains(.teamProfileUnsupportedVersion))
        XCTAssertTrue(reasonCodes.contains(.teamProfileInvalidDisplayName))
        XCTAssertTrue(reasonCodes.contains(.teamProfileNotOptIn))
        XCTAssertTrue(reasonCodes.contains(.teamProfileDuplicateGate))
        XCTAssertTrue(reasonCodes.contains(.teamProfileDuplicateRequirement))
        XCTAssertEqual(reasonCodes.filter { $0 == .teamProfileMissingRequiredGate }.count, TeamWorkflowGate.allCases.count - 1)
        XCTAssertTrue(decisions.allSatisfy { $0.severity == .blocker })
    }

    func testProfileParserUsesCanonicalHashAndRejectsUnknownWeakeningFields() throws {
        let gates = TeamWorkflowGate.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let first = """
        {"kind":"HostwrightTeamProfile","apiVersion":1,"identifier":"dev.hostwright.team.local","displayName":"Local Maintainers","optIn":true,"requiredGates":[\(gates)],"requirements":["requireImageDigest"]}
        """
        let second = """
        {
          "requirements": ["requireImageDigest"],
          "requiredGates": [\(gates)],
          "optIn": true,
          "displayName": "Local Maintainers",
          "identifier": "dev.hostwright.team.local",
          "apiVersion": 1,
          "kind": "HostwrightTeamProfile"
        }
        """

        let firstArtifact = try TeamWorkflowDocumentParser.parseProfile(first)
        let secondArtifact = try TeamWorkflowDocumentParser.parseProfile(second)

        XCTAssertEqual(firstArtifact, secondArtifact)
        XCTAssertEqual(firstArtifact.profileHash.count, 64)
        XCTAssertTrue(firstArtifact.profile.requiresImageDigest)

        let weakening = first.replacingOccurrences(of: #""requirements":["requireImageDigest"]"#, with: #""requirements":[],"overrides":["bypassOwnershipChecks"]"#)
        XCTAssertThrowsError(try TeamWorkflowDocumentParser.parseProfile(weakening)) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .teamProfileInvalid)
            XCTAssertTrue((error as? HostwrightDiagnostic)?.message.contains("unsupported field(s): overrides") == true)
        }
    }

    func testProfileParserRejectsMissingAndInvalidTypedFieldsWithoutEchoingValues() {
        let secret = "token=should-not-appear"
        let malformed = #"{"kind":"HostwrightTeamProfile","apiVersion":"\#(secret)"}"#

        XCTAssertThrowsError(try TeamWorkflowDocumentParser.parseProfile(malformed)) { error in
            let diagnostic = error as? HostwrightDiagnostic
            XCTAssertEqual(diagnostic?.code, .teamProfileInvalid)
            XCTAssertFalse(diagnostic?.message.contains(secret) == true)
        }
    }

    func testProfileParserRejectsDuplicateAndEscapedDuplicateKeys() {
        let gates = TeamWorkflowGate.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let duplicate = """
        {"kind":"HostwrightTeamProfile","kind":"HostwrightTeamProfile","apiVersion":1,"identifier":"dev.hostwright.team.local","displayName":"Local Maintainers","optIn":true,"requiredGates":[\(gates)],"requirements":[]}
        """
        let escapedDuplicate = duplicate.replacingOccurrences(
            of: #""kind":"HostwrightTeamProfile","kind"#,
            with: #""kind":"HostwrightTeamProfile","\u006b\u0069\u006e\u0064"#
        )

        for text in [duplicate, escapedDuplicate] {
            XCTAssertThrowsError(try TeamWorkflowDocumentParser.parseProfile(text)) { error in
                let diagnostic = error as? HostwrightDiagnostic
                XCTAssertEqual(diagnostic?.code, .teamProfileInvalid)
                XCTAssertTrue(diagnostic?.message.contains("duplicate field 'kind'") == true)
            }
        }
    }

    func testApprovalMustMatchExactScopeAndHashes() {
        let approval = validApproval()
        let expected = TeamApprovalExpectation(
            scope: .apply,
            profileHash: approval.profileHash,
            manifestHash: approval.manifestHash,
            planHash: approval.planHash
        )

        let accepted = TeamWorkflowPolicyEvaluator.default.evaluate(approval, expected: expected)
        XCTAssertEqual(accepted.map(\.reasonCode), [.teamApprovalRecorded])
        XCTAssertEqual(accepted.first?.severity, .allow)

        let mismatched = TeamApprovalExpectation(
            scope: .cleanup,
            profileHash: "different-profile",
            manifestHash: "different-manifest",
            planHash: "different-plan"
        )
        let rejected = TeamWorkflowPolicyEvaluator.default.evaluate(approval, expected: mismatched)
        XCTAssertEqual(rejected.filter { $0.reasonCode == .teamApprovalBindingMismatch }.count, 3)
        XCTAssertTrue(rejected.contains { $0.reasonCode == .teamApprovalScopeMismatch })
        XCTAssertTrue(rejected.allSatisfy { $0.severity == .blocker })
    }

    func testRejectedOrMalformedApprovalNeverAuthorizesMutation() {
        let approval = TeamApprovalRecord(
            kind: "WrongKind",
            apiVersion: 7,
            id: "",
            reviewer: "",
            decision: .rejected,
            scope: .apply,
            recordedAt: "not-a-date",
            profileHash: "profile",
            manifestHash: "manifest",
            planHash: "plan"
        )
        let expected = TeamApprovalExpectation(scope: .apply, profileHash: "profile", manifestHash: "manifest", planHash: "plan")

        let decisions = TeamWorkflowPolicyEvaluator.default.evaluate(approval, expected: expected)
        let reasons = decisions.map(\.reasonCode)

        XCTAssertTrue(reasons.contains(.teamApprovalMissingIdentity))
        XCTAssertTrue(reasons.contains(.teamApprovalInvalidKind))
        XCTAssertTrue(reasons.contains(.teamApprovalUnsupportedVersion))
        XCTAssertTrue(reasons.contains(.teamApprovalRejected))
        XCTAssertTrue(reasons.contains(.teamApprovalInvalidTimestamp))
        XCTAssertFalse(reasons.contains(.teamApprovalRecorded))
    }

    func testApprovalParserCanonicalHashAndManifestSHA256() throws {
        let approval = validApproval()
        let encoder = JSONEncoder()
        let text = String(decoding: try encoder.encode(approval), as: UTF8.self)

        let artifact = try TeamWorkflowDocumentParser.parseApproval(text)

        XCTAssertEqual(artifact.approval, approval)
        XCTAssertEqual(artifact.approvalHash.count, 64)
        XCTAssertEqual(
            TeamWorkflowDocumentParser.manifestHash("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    private func validProfile(requirements: [TeamPolicyRequirement] = []) -> TeamPolicyProfile {
        TeamPolicyProfile(
            identifier: "dev.hostwright.team.local",
            displayName: "Local Maintainers",
            optIn: true,
            requiredGates: TeamWorkflowGate.allCases,
            requirements: requirements
        )
    }

    private func validApproval() -> TeamApprovalRecord {
        TeamApprovalRecord(
            id: "approval-1",
            reviewer: "maintainer",
            decision: .approved,
            scope: .apply,
            recordedAt: "2026-07-12T12:00:00Z",
            profileHash: String(repeating: "a", count: 64),
            manifestHash: String(repeating: "b", count: 64),
            planHash: "plan-hash"
        )
    }
}
