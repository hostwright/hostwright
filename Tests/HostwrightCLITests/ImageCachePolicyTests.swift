import XCTest
@testable import HostwrightCLI

final class ImageCachePolicyTests: XCTestCase {
    func testPressurePlanSelectsLeastRecentlyUsedExactContent() throws {
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: 100,
            targetBytes: 60,
            retentionSeconds: 0,
            maximumDeletions: 2
        )
        let older = content(
            digestByte: "1",
            sizeBytes: 60,
            reference: "registry.example/app:old",
            lastUsedAt: "2026-01-01T00:00:00Z"
        )
        let newer = content(
            digestByte: "2",
            sizeBytes: 60,
            reference: "registry.example/app:new",
            lastUsedAt: "2026-01-02T00:00:00.000Z"
        )

        let plan = try ImageCachePrunePlanner.plan(
            providerID: "apple-cli",
            capabilitySHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            content: [newer, older],
            staleOwnedReferences: [],
            policy: policy,
            evaluatedAt: "2026-01-03T00:00:00Z"
        )

        XCTAssertEqual(plan.pressure, .exceeded)
        XCTAssertEqual(plan.totalBytes, 120)
        XCTAssertEqual(plan.projectedBytes, 60)
        XCTAssertEqual(plan.candidates.map(\.digest), [older.digest])
        XCTAssertEqual(
            plan.candidates.first?.references,
            ["registry.example/app:old"]
        )
    }

    func testEligibilityRejectsEveryUnsafeReclamationClass() throws {
        let old = "2025-01-01T00:00:00Z"
        let content = [
            self.content(
                digestByte: "1",
                sizeBytes: 10,
                reference: "registry.example/app:missing",
                owned: false,
                lastUsedAt: old
            ),
            self.content(
                digestByte: "2",
                sizeBytes: 10,
                reference: "registry.example/app:unmanaged",
                additionalReference: "registry.example/app:foreign",
                lastUsedAt: old
            ),
            self.content(
                digestByte: "3",
                sizeBytes: 10,
                reference: "registry.example/app:live",
                live: true,
                lastUsedAt: old
            ),
            self.content(
                digestByte: "4",
                sizeBytes: 10,
                reference: "registry.example/app:leased",
                leased: true,
                lastUsedAt: old
            ),
            self.content(
                digestByte: "5",
                sizeBytes: 10,
                reference: "registry.example/app:pinned",
                pinned: true,
                lastUsedAt: old
            ),
            self.content(
                digestByte: "6",
                sizeBytes: 10,
                reference: "registry.example/app:retained",
                lastUsedAt: "2026-01-03T00:00:00Z"
            ),
            self.content(
                digestByte: "7",
                sizeBytes: 0,
                reference: "registry.example/app:unknown-size",
                lastUsedAt: old
            )
        ]
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: 1,
            targetBytes: 0,
            retentionSeconds: 86_400,
            maximumDeletions: 256
        )

        let plan = try ImageCachePrunePlanner.plan(
            providerID: "apple-cli",
            capabilitySHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            content: content,
            staleOwnedReferences: [],
            policy: policy,
            evaluatedAt: "2026-01-03T12:00:00Z"
        )
        let reasons: [String: ImageCacheEligibilityReason] = Dictionary(
            uniqueKeysWithValues: plan.content.map {
                ($0.digest, $0.reason)
            }
        )

        XCTAssertEqual(reasons[content[0].digest], .missingOwnership)
        XCTAssertEqual(reasons[content[1].digest], .unmanagedReference)
        XCTAssertEqual(reasons[content[2].digest], .liveReference)
        XCTAssertEqual(reasons[content[3].digest], .leased)
        XCTAssertEqual(reasons[content[4].digest], .pinned)
        XCTAssertEqual(reasons[content[5].digest], .retained)
        XCTAssertEqual(reasons[content[6].digest], .sizeUnavailable)
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testConfirmationHashDoesNotDependOnObservationClock() throws {
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: nil,
            targetBytes: nil,
            retentionSeconds: 0,
            maximumDeletions: 1
        )
        let observed = content(
            digestByte: "8",
            sizeBytes: 10,
            reference: "registry.example/app:old",
            lastUsedAt: "2025-01-01T00:00:00Z"
        )
        let first = try ImageCachePrunePlanner.plan(
            providerID: "apple-cli",
            capabilitySHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            content: [observed],
            staleOwnedReferences: [],
            policy: policy,
            evaluatedAt: "2026-01-01T00:00:00Z"
        )
        let second = try ImageCachePrunePlanner.plan(
            providerID: "apple-cli",
            capabilitySHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            content: [observed],
            staleOwnedReferences: [],
            policy: policy,
            evaluatedAt: "2026-01-01T00:00:01.000Z"
        )

        XCTAssertNotEqual(first.evaluatedAt, second.evaluatedAt)
        XCTAssertEqual(first.planSHA256, second.planSHA256)
    }

    func testAccountingOverflowAndInvalidPolicyFailClosed() throws {
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: nil,
            targetBytes: nil,
            retentionSeconds: 0,
            maximumDeletions: 1
        )
        XCTAssertThrowsError(
            try ImageCachePrunePlanner.plan(
                providerID: "apple-cli",
                capabilitySHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64),
                content: [
                    content(
                        digestByte: "9",
                        sizeBytes: Int64.max,
                        reference: "registry.example/app:max",
                        lastUsedAt: "2025-01-01T00:00:00Z"
                    ),
                    content(
                        digestByte: "a",
                        sizeBytes: 1,
                        reference: "registry.example/app:one",
                        lastUsedAt: "2025-01-01T00:00:00Z"
                    )
                ],
                staleOwnedReferences: [],
                policy: policy,
                evaluatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertThrowsError(
            try ImageCachePrunePolicyV1(
                maximumBytes: 10,
                targetBytes: 11,
                retentionSeconds: 0,
                maximumDeletions: 1
            )
        )
    }

    func testStaleOwnershipCleanupIsDeterministicallyBounded()
        throws
    {
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: nil,
            targetBytes: nil,
            retentionSeconds: 0,
            maximumDeletions: 2
        )
        let stale = [
            "registry.example/app:three",
            "registry.example/app:one",
            "registry.example/app:two"
        ]
        let plan = try ImageCachePrunePlanner.plan(
            providerID: "apple-cli",
            capabilitySHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            content: [],
            staleOwnedReferences: stale,
            policy: policy,
            evaluatedAt: "2026-01-01T00:00:00Z"
        )

        XCTAssertEqual(
            plan.staleOwnedReferences,
            [
                "registry.example/app:one",
                "registry.example/app:three"
            ]
        )
        XCTAssertThrowsError(
            try ImageCachePrunePlanner.plan(
                providerID: "apple-cli",
                capabilitySHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64),
                content: [],
                staleOwnedReferences:
                    (0...ImageCacheLimits.maximumRecords).map {
                        "registry.example/app:stale-\($0)"
                    },
                policy: policy,
                evaluatedAt: "2026-01-01T00:00:00Z"
            )
        )
    }

    private func content(
        digestByte: Character,
        sizeBytes: Int64,
        reference: String,
        additionalReference: String? = nil,
        owned: Bool = true,
        live: Bool = false,
        leased: Bool = false,
        pinned: Bool = false,
        lastUsedAt: String
    ) -> ImageCacheObservedContent {
        let references = [reference, additionalReference].compactMap {
            $0
        }
        return ImageCacheObservedContent(
            providerID: "apple-cli",
            digest:
                "sha256:" + String(repeating: digestByte, count: 64),
            sizeBytes: sizeBytes,
            references: references,
            ownedReferences: owned ? [reference] : [],
            liveReferences: live ? [reference] : [],
            liveDigest: live,
            pinned: pinned,
            leased: leased,
            lastUsedAt: lastUsedAt
        )
    }
}
