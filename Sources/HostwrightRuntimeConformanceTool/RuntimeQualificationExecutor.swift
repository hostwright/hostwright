import HostwrightRuntime

enum RuntimeQualificationExecutor {
    static func execute(_ options: RuntimeQualificationOptions) async throws {
        switch options.operation {
        case .conformance:
            try await executeConformance(options)
        case .migration:
            try await RuntimeQualificationMigrationCommandRunner.execute(options)
        case .recovery:
            try await executeRecovery(options)
        }
    }

    private static func executeConformance(
        _ options: RuntimeQualificationOptions
    ) async throws {
        guard let providerID = options.providerID,
              let expectedVersion = options.expectedVersion else {
            throw RuntimeQualificationCommandError.usage(
                "conformance requires one provider and expected version."
            )
        }
        let driver: RuntimeQualificationLiveDriver
        do {
            driver = try await RuntimeQualificationLiveDriver.make(
                providerID: providerID,
                expectedVersion: expectedVersion,
                localImage: options.localImage
            )
        } catch {
            throw RuntimeQualificationCommandError.blocked(
                "the selected provider failed the live qualification preflight."
            )
        }

        let evidence = await RuntimeProviderLiveQualificationRunner.run(driver: driver)
        guard evidence.passed,
              let before = evidence.baselineInventorySHA256,
              let after = evidence.finalInventorySHA256,
              let unmanagedBefore = evidence.records.first?.beforeUnmanagedSentinelSHA256,
              let unmanagedAfter = evidence.records.last?.afterUnmanagedSentinelSHA256,
              before == after,
              unmanagedBefore == unmanagedAfter else {
            throw RuntimeQualificationCommandError.failed(
                "live runtime conformance or exact cleanup failed."
            )
        }
        let fixtureImage = driver.fixtureImage
        let capabilitySHA256 = driver.capabilitySHA256
        let resourceIdentifier = driver.resourceIdentifier
        let resourceUUID = driver.resourceUUID
        let commands: [RuntimeQualificationCommandEvidence]
        do {
            commands = try await driver.recorder.evidence()
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "bounded command evidence was incomplete."
            )
        }
        let passedCount = evidence.report.cases.filter { $0.status == .passed }.count
        let report = RuntimeQualificationConformanceReport(
            schemaVersion: 1,
            kind: "runtimeProviderConformanceEvidence",
            status: "passed",
            subjects: [RuntimeQualificationSubject(
                providerID: providerID.rawValue,
                providerVersion: expectedVersion
            )],
            fixtureImage: RuntimeQualificationFixtureImage(
                reference: fixtureImage.reference,
                digest: fixtureImage.descriptorDigest
            ),
            inventory: RuntimeQualificationInventoryEvidence(
                beforeSHA256: before,
                afterSHA256: after,
                unmanagedBeforeSHA256: unmanagedBefore,
                unmanagedAfterSHA256: unmanagedAfter
            ),
            unmanagedInventoryUnchanged: true,
            summary: RuntimeQualificationSummary(passed: passedCount, failed: 0),
            commands: commands,
            cleanup: RuntimeQualificationCleanupEvidence(
                complete: true,
                identifiers: [resourceIdentifier, resourceUUID].sorted()
            ),
            details: RuntimeQualificationConformanceDetails(
                capabilitySHA256: capabilitySHA256,
                conformance: evidence,
                imageVariantDigest: fixtureImage.variantDigest,
                runtimeVersion: expectedVersion
            )
        )
        do {
            try RuntimeQualificationEvidenceWriter.write(report, to: options.outputURL)
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "the validated conformance evidence could not be published atomically."
            )
        }
    }

    private static func executeRecovery(
        _ options: RuntimeQualificationOptions
    ) async throws {
        guard let providerID = options.providerID,
              let expectedVersion = options.expectedVersion,
              let scenario = options.scenario,
              let recoveryScenario = RuntimeQualificationRecoveryScenario(rawValue: scenario) else {
            throw RuntimeQualificationCommandError.usage(
                "recovery requires one provider, version, and scenario."
            )
        }
        let report: RuntimeQualificationRecoveryReport
        do {
            report = try await RuntimeQualificationRecoveryDriver(
                specification: RuntimeQualificationRecoverySpecification(
                    providerID: providerID,
                    expectedVersion: expectedVersion,
                    scenario: recoveryScenario,
                    localImage: options.localImage
                )
            ).runReport()
        } catch let error as RuntimeQualificationRecoveryDriverError {
            switch error {
            case .invalidSpecification:
                throw RuntimeQualificationCommandError.usage(
                    "recovery does not match the locked Phase 03 provider contract."
                )
            case .providerPreflightFailed, .hostwrightExecutableUnavailable:
                throw RuntimeQualificationCommandError.blocked(
                    "the selected recovery provider failed live qualification preflight."
                )
            case .expectedRecoveryDecisionMissing, .hostwrightTerminationFailed,
                 .stateFoundationFailed, .runtimeInventoryChanged, .cleanupFailed,
                 .invalidEvidence:
                throw RuntimeQualificationCommandError.failed(
                    "runtime provider recovery or exact cleanup failed."
                )
            }
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "runtime provider recovery failed at a bounded runtime boundary."
            )
        }
        do {
            try RuntimeQualificationEvidenceWriter.write(report, to: options.outputURL)
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "the validated recovery evidence could not be published atomically."
            )
        }
    }

}
