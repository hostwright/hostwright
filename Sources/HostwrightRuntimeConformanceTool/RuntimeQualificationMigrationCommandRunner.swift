import HostwrightRuntime

enum RuntimeQualificationMigrationCommandRunner {
    static func execute(_ options: RuntimeQualificationOptions) async throws {
        guard case .migration = options.operation,
              let sourceProviderID = options.sourceProviderID,
              let targetProviderID = options.targetProviderID,
              let expectedSourceVersion = options.expectedSourceVersion,
              let expectedTargetVersion = options.expectedTargetVersion else {
            throw RuntimeQualificationCommandError.usage(
                "migration requires two providers and their expected versions."
            )
        }

        let specification = RuntimeQualificationMigrationSpecification(
            sourceProviderID: sourceProviderID,
            targetProviderID: targetProviderID,
            expectedSourceVersion: expectedSourceVersion,
            expectedTargetVersion: expectedTargetVersion,
            localImage: options.localImage
        )
        let driver: RuntimeQualificationMigrationDriver
        do {
            driver = try RuntimeQualificationMigrationDriver(specification: specification)
        } catch {
            throw RuntimeQualificationCommandError.usage(
                "migration does not match the locked Phase 03 provider contract."
            )
        }

        let evidence: RuntimeQualificationMigrationEvidence
        do {
            evidence = try await driver.run()
        } catch let error as RuntimeQualificationMigrationDriverError {
            switch error {
            case .invalidSpecification:
                throw RuntimeQualificationCommandError.usage(
                    "migration does not match the locked Phase 03 provider contract."
                )
            case .providerPreflightFailed:
                throw RuntimeQualificationCommandError.blocked(
                    "the selected migration providers failed live qualification preflight."
                )
            case .stateFoundationFailed, .expectedRefusalMissing, .migrationFailed,
                 .ownershipMismatch, .rollbackFailed, .recoveryFailed, .cleanupFailed:
                throw RuntimeQualificationCommandError.failed(
                    "live provider migration, recovery, or exact cleanup failed."
                )
            }
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "live provider migration failed at a bounded runtime boundary."
            )
        }

        let commands: [RuntimeQualificationCommandEvidence]
        do {
            commands = try await driver.recorder.evidence()
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "bounded migration command evidence was incomplete."
            )
        }

        let report: RuntimeQualificationMigrationReport
        do {
            report = try RuntimeQualificationMigrationReportComposer.compose(
                specification: specification,
                evidence: evidence,
                commands: commands
            )
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "migration evidence did not satisfy the exact qualification contract."
            )
        }

        do {
            try RuntimeQualificationEvidenceWriter.write(report, to: options.outputURL)
        } catch {
            throw RuntimeQualificationCommandError.failed(
                "the validated migration evidence could not be published atomically."
            )
        }
    }
}
