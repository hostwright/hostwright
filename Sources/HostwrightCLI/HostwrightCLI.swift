import Dispatch
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightExtensions
import HostwrightHealth
import HostwrightImport
import HostwrightManifest
import HostwrightObservability
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState
import HostwrightStorage

public enum HostwrightCLI {
    public static let starterManifest = """
    version: 2
    project: api-local

    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
        env:
          APP_ENV: development
        health:
          command: ["curl", "-f", "http://localhost:8080/health"]
          interval: 10s
        restart:
          policy: on-failure
      redis:
        image: redis:7
        ports:
          - "6379:6379"

    """

    public static func run(arguments: [String], environment: CLIEnvironment = .live) -> CLIRunResult {
        let generatedCorrelationID = environment.observabilityCorrelationID()
        let correlationID = (try? HostwrightLogRecord(
            category: .cli,
            severity: .info,
            reason: .cliStarted,
            correlationID: generatedCorrelationID,
            outcome: .started
        )) == nil ? UUID().uuidString.lowercased() : generatedCorrelationID
        return HostwrightLogContext.withValues(
            sink: environment.observabilitySink,
            correlationID: correlationID
        ) {
            runTraced(arguments: arguments, environment: environment, correlationID: correlationID)
        }
    }

    public static func usageFailure(
        _ error: CLIUsageError,
        output: CLIOutputFormat = .text
    ) -> CLIRunResult {
        failure(
            code: .commandUsage,
            message: "\(error.message)\n\n\(helpText)",
            output: output
        )
    }

    public static func diagnosticFailure(
        _ diagnostic: HostwrightDiagnostic,
        output: CLIOutputFormat = .text
    ) -> CLIRunResult {
        failure(code: diagnostic.code, message: diagnostic.message, output: output)
    }

    public static func renderControlEventStream(
        stateDatabasePath: String,
        projectName: String?,
        filters: EventFilters,
        stream: EventStreamCLIOptions,
        output: CLIOutputFormat,
        page: HostwrightEventStreamPage
    ) -> CLIRunResult {
        EventsCommandRunner(
            stateStoreConfiguration: StateStoreConfiguration(
                explicitDatabasePath: stateDatabasePath
            ),
            projectName: projectName,
            filters: filters,
            stream: stream,
            output: output
        ).renderStream(
            page,
            pageSize: filters.limit ?? HostwrightEventStreamPage.defaultPageSize
        )
    }

    private static func runTraced(
        arguments: [String],
        environment: CLIEnvironment,
        correlationID: String
    ) -> CLIRunResult {
        let command = observabilityCommand(arguments)
        let alwaysSampledCommands = Set([
            "apply", "cleanup", "daemon", "down", "recovery", "restart", "rm", "run", "start",
            "stop", "up", "update"
        ]).contains(command)
        let traceAttributeCommands = Set([
            "apply", "cleanup", "daemon", "down", "recovery", "restart", "rm", "up", "update"
        ])
        guard let session = try? HostwrightTraceSession(
            traceID: correlationID,
            processCorrelationID: correlationID,
            selected: alwaysSampledCommands || HostwrightTraceSession.deterministicSelection(traceID: correlationID)
        ) else {
            return runObserved(arguments: arguments, environment: environment, correlationID: correlationID)
        }
        return HostwrightTraceContext.withSession(session) {
            var attributes = [try? HostwrightTraceAttribute(key: .component, value: "cli")]
                .compactMap { $0 }
            if traceAttributeCommands.contains(command) {
                if let commandAttribute = try? HostwrightTraceAttribute(key: .command, value: command) {
                    attributes.append(commandAttribute)
                }
            }
            let root = session.start(.cliRequest, attributes: attributes)
            return HostwrightTraceContext.withSpan(root) {
                let result = runObserved(
                    arguments: arguments,
                    environment: environment,
                    correlationID: correlationID
                )
                let status: HostwrightTraceSpanStatus = result.exitCode == 0
                    ? .succeeded
                    : (result.exitCode == 130 ? .cancelled : .failed)
                let sampling = status == .succeeded
                    ? (alwaysSampledCommands ? "all" : "deterministic-1-of-16")
                    : "failure-override"
                _ = session.finish(
                    root,
                    status: status,
                    attributes: session.rootCompletionAttributes(sampling: sampling)
                )
                session.complete(status: status)
                return result
            }
        }
    }

    private static func runObserved(
        arguments: [String],
        environment: CLIEnvironment,
        correlationID: String
    ) -> CLIRunResult {
        let command = observabilityCommand(arguments)
        emitCLIRecord(
            reason: .cliStarted,
            severity: .notice,
            outcome: .started,
            correlationID: correlationID,
            command: command,
            exitCode: nil
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = runUnobserved(arguments: arguments, environment: environment)
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        emitCLIRecord(
            reason: result.exitCode == 0 ? .cliSucceeded : .cliFailed,
            severity: result.exitCode == 0 ? .notice : .error,
            outcome: result.exitCode == 0 ? .succeeded : .failed,
            correlationID: correlationID,
            command: command,
            exitCode: result.exitCode,
            durationMilliseconds: elapsed
        )
        return result
    }

    private static func runUnobserved(arguments: [String], environment: CLIEnvironment) -> CLIRunResult {
        let outputHint = CLICommand.outputFormatHint(arguments: arguments) ?? .text
        do {
            let command = try CLICommand.parse(arguments: arguments)
            return try run(command: command, environment: environment)
        } catch let error as HostwrightDiagnostic {
            return failure(code: error.code, message: error.message, output: outputHint)
        } catch let error as HostwrightSupportBundleError {
            let diagnostic = error.diagnostic
            return failure(code: diagnostic.code, message: diagnostic.message, output: outputHint)
        } catch let error as CLIUsageError {
            return failure(code: .commandUsage, message: "\(error.message)\n\n\(helpText)", output: outputHint)
        } catch let error as ManifestParseError {
            return failure(issues: error.issues, output: outputHint)
        } catch {
            return failure(code: .fileIOFailed, message: String(describing: error), output: outputHint)
        }
    }

    private static func observabilityCommand(_ arguments: [String]) -> String {
        let supported = Set([
            "apply", "benchmark", "capabilities", "cleanup", "daemon", "diagnostics", "down",
            "doctor", "events", "extension", "help", "image", "init", "interactive",
            "lifecycle", "logs", "metrics", "network", "paths", "plan", "recovery", "registry",
            "observability", "restart", "rm", "run", "runtime", "secret", "start", "state", "status",
            "stop", "storage", "traces", "up", "update", "validate", "version"
        ])
        guard let first = arguments.first else { return "help" }
        let normalized = first.hasPrefix("--") ? String(first.dropFirst(2)) : first
        return supported.contains(normalized) ? normalized : "unknown"
    }

    private static func emitCLIRecord(
        reason: HostwrightLogReason,
        severity: HostwrightLogSeverity,
        outcome: HostwrightLogOutcome,
        correlationID: String,
        command: String,
        exitCode: Int32?,
        durationMilliseconds: UInt64? = nil
    ) {
        var fields = [
            HostwrightLogField(name: .command, value: command, privacy: .publicValue)
        ]
        if let exitCode {
            fields.append(
                HostwrightLogField(
                    name: .exitCode,
                    value: String(exitCode),
                    privacy: .publicValue
                )
            )
        }
        if let durationMilliseconds {
            fields.append(
                HostwrightLogField(
                    name: .durationMilliseconds,
                    value: String(durationMilliseconds),
                    privacy: .publicValue
                )
            )
        }
        guard let record = try? HostwrightLogRecord(
            category: .cli,
            severity: severity,
            reason: reason,
            correlationID: correlationID,
            outcome: outcome,
            fields: fields
        ) else { return }
        HostwrightLogContext.emit(record)
    }

    public static func run(command: CLICommand, environment: CLIEnvironment = .live) throws -> CLIRunResult {
        switch command {
        case .version:
            return CLIRunResult(standardOutput: "\(HostwrightIdentity.version)\n")
        case .capabilities(let output):
            let report = HostwrightCapabilityCatalog.report
            return CLIRunResult(
                standardOutput: output == .json
                    ? CLIJSON.capabilities(report)
                    : renderCapabilities(report)
            )
        case .observabilityStatus(let output):
            let status = environment.observabilityStatus()
            if output == .json {
                return CLIRunResult(standardOutput: CLIJSON.codable(status))
            }
            return CLIRunResult(
                standardOutput: """
                Hostwright local observability
                Schema: v\(status.schemaVersion)
                Subsystem: \(status.subsystem)
                Enabled: \(status.enabled)
                Minimum severity: \(status.minimumSeverity)
                Categories: \(status.categories.joined(separator: ", "))
                Field limit: \(status.maximumFieldCount) fields, \(status.maximumFieldValueBytes) bytes each
                Payload limit: \(status.maximumPayloadBytes) bytes
                Active signpost limit: \(status.maximumActiveSignposts)
                Durable authority: \(status.durableAuthority)
                Rotation authority: \(status.rotationAuthority)
                Automatic upload: \(status.automaticUpload)

                """
            )
        case .runtimeProviders(let output):
            return try RuntimeProvidersCommandRunner(
                output: output,
                environment: environment
            ).run()
        case .runtimeMigrate(let options):
            return RuntimeProviderMigrationCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .paths(let stateDatabasePath, let output):
            let resolution = try hostwrightLocalPathResolution(
                explicitPath: stateDatabasePath,
                environment: environment
            )
            let status = localPathStatus(resolution: resolution, environment: environment)
            let daemonLockPath = try resolution.daemonLockPath()
            if output == .json {
                return CLIRunResult(
                    standardOutput: CLIJSON.localPaths(
                        resolution,
                        readiness: status.readiness,
                        daemonLockPath: daemonLockPath,
                        targetExists: status.targetExists,
                        legacyExists: status.legacyExists,
                        migrationJournalExists: status.migrationJournalExists,
                        policyError: status.policyError
                    )
                )
            }
            return CLIRunResult(
                standardOutput: renderLocalPaths(
                    resolution,
                    readiness: status.readiness,
                    daemonLockPath: daemonLockPath,
                    migrationJournalExists: status.migrationJournalExists,
                    policyError: status.policyError
                )
            )
        case .state(let action, let stateDatabasePath, let output):
            return StateMaintenanceCommandRunner(
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                action: action,
                output: output,
                environment: environment
            ).run()
        case .secret(let options):
            return try SecretCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .registry(let options):
            return try RegistryCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .image(let options):
            return try ImageCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .volume(let options):
            return try StorageCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .daemon(let options):
            return try DaemonLifecycleCommandRunner(
                options: options,
                controller: environment.daemonLifecycleController(),
                controlIdentityBootstrap: environment.controlIdentityBootstrap
            ).run()
        case .restartBudget(let options):
            return try RestartBudgetCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                )
            ).run()
        case .maintenance(let options):
            return try MaintenanceCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                ),
                environment: environment
            ).run()
        case .ownership(let options):
            return try OwnershipCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                )
            ).run()
        case .metrics(let options):
            return try MetricsCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                ),
                environment: environment
            ).run()
        case .traces(let options):
            return try TraceCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                ),
                environment: environment
            ).run()
        case .supportBundle(let options):
            return try SupportBundleCommandRunner(
                options: options,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                ),
                environment: environment
            ).run()
        case .migrateManifestPreview(let path, let output):
            let source = try hostwrightReadManifestText(path: path, environment: environment)
            let preview = try ManifestMigrator.previewV2(source)
            return CLIRunResult(
                standardOutput: output == .json
                    ? CLIJSON.manifestMigrationPreview(preview)
                    : preview.migratedManifest
            )
        case .help:
            return CLIRunResult(standardOutput: helpText)
        case .initManifest:
            return try initManifest(environment: environment)
        case .importStack(let path, let output, let teamProfilePath):
            return try importStack(path: path, output: output, teamProfilePath: teamProfilePath, environment: environment)
        case .validate(let path, let teamProfilePath):
            let validated = try loadValidManifest(path: path, teamProfilePath: teamProfilePath, environment: environment)
            let standardOutput = "Valid hostwright manifest: \(path)\nProject: \(validated.manifest.project ?? "<missing>")\nServices: \(validated.manifest.services.count)\n" + hostwrightTeamProfileText(validated)
            return CLIRunResult(standardOutput: standardOutput)
        case .plan(let path, let output, let teamProfilePath):
            let validated = try loadValidManifest(path: path, teamProfilePath: teamProfilePath, environment: environment)
            let plan = ReconciliationPlanner().plan(manifest: validated.manifest)
            let binding = validated.previewBinding(planHash: plan.planHash)
            let standardOutput = output == .json
                ? CLIJSON.plan(plan, teamBinding: binding)
                : PlanRenderer.render(plan) + hostwrightTeamProfileText(validated, planHash: plan.planHash)
            return CLIRunResult(standardOutput: standardOutput)
        case .status(let path, let stateDatabasePath, let output, let runtimeProvider):
            return StatusCommandRunner(
                manifestPath: path,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                output: output,
                runtimeProvider: runtimeProvider,
                environment: environment
            ).run()
        case .apply(
            let path,
            let stateDatabasePath,
            let confirmedPlanHash,
            let teamProfilePath,
            let approvalRecordPath,
            let runtimeProvider
        ):
            return ApplyLifecycleCompatibilityRunner(
                manifestPath: path,
                stateDatabasePath: stateDatabasePath,
                confirmedPlanHash: confirmedPlanHash,
                teamProfilePath: teamProfilePath,
                approvalRecordPath: approvalRecordPath,
                runtimeProvider: runtimeProvider,
                environment: environment
            ).run()
        case .lifecycle(let options):
            return LifecycleCommandRunner(
                options: options,
                driver: LifecycleLiveDriver(environment: environment, options: options)
            ).run()
        case .interactive(let options):
            return InteractiveCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .logs(let serviceName, let path, let tail, let stateDatabasePath):
            return LogsCommandRunner(
                serviceName: serviceName,
                manifestPath: path,
                tail: tail,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                environment: environment
            ).run()
        case .events(let stateDatabasePath, let projectName, let filters, let stream, let output):
            return EventsCommandRunner(
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                projectName: projectName,
                filters: filters,
                stream: stream,
                output: output,
                monotonicNow: environment.eventWatchMonotonicNow,
                sleep: environment.eventWatchSleep,
                isCancelled: environment.eventWatchCancelled
            ).run()
        case .recovery(let action, let stateDatabasePath, let projectName, let output):
            return RecoveryCommandRunner(
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                action: action,
                projectName: projectName,
                output: output,
                environment: environment
            ).run()
        case .cleanup(let path, let stateDatabasePath, let confirmation, let teamProfilePath, let approvalRecordPath):
            return CleanupCommandRunner(
                manifestPath: path,
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                confirmation: confirmation,
                teamProfilePath: teamProfilePath,
                approvalRecordPath: approvalRecordPath,
                environment: environment
            ).run()
        case .diagnostics(let stateDatabasePath, let bundlePath, let projectName, let manifestPath):
            return DiagnosticsCommandRunner(
                stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                    explicitPath: stateDatabasePath,
                    environment: environment
                ),
                bundlePath: bundlePath,
                projectName: projectName,
                manifestPath: manifestPath,
                environment: environment
            ).run()
        case .benchmark(let options):
            return try BenchmarkCommandRunner(options: options, environment: environment).run()
        case .extensionCheck(let declarationPath, let executablePath, let output):
            return try checkExtension(
                declarationPath: declarationPath,
                executablePath: executablePath,
                output: output
            )
        case .doctor(let stateDatabasePath, let output):
            return doctor(
                stateDatabasePath: stateDatabasePath,
                environment: environment,
                output: output
            )
        }
    }

    public static let helpText = """
    Hostwright CLI

    Usage:
      hostwright --version
      hostwright capabilities [--json|--output text|json]
      hostwright observability status [--json|--output text|json]
      hostwright metrics snapshot [--state-db <path>] [--output text|json]
      hostwright metrics export --output-path <absolute-new-path> --confirm-snapshot <sha256> [--state-db <path>] [--output text|json]
      hostwright traces inspect [--trace-id <uuid>] [--limit <1-100>] [--state-db <path>] [--output text|json]
      hostwright traces export --trace-id <uuid> --output-path <absolute-new-path> --confirm-trace <sha256> [--state-db <path>] [--output text|json]
      hostwright runtime providers [--json]
      hostwright runtime migrate [path] --to apple-cli|containerization --dry-run [--state-db <path>] [--json|--output text|json]
      hostwright runtime migrate [path] --to apple-cli|containerization --confirm-migration <token> [--state-db <path>] [--json|--output text|json]
      hostwright paths [--state-db <path>] [--json|--output text|json]
      hostwright state integrity [--state-db <path>] [--json|--output text|json]
      hostwright state backup [--state-db <path>] [--json|--output text|json]
      hostwright state backups [--state-db <path>] [--json|--output text|json]
      hostwright state restore --backup <id> --dry-run [--state-db <path>] [--json|--output text|json]
      hostwright state restore --backup <id> --confirm-restore <token> [--state-db <path>] [--json|--output text|json]
      hostwright state repair --dry-run [--state-db <path>] [--json|--output text|json]
      hostwright state repair --confirm-repair <token> [--state-db <path>] [--json|--output text|json]
      hostwright state recover [--state-db <path>] [--json|--output text|json]
      hostwright state retention <manifest> [--state-db <path>] [--json|--output text|json]
      hostwright state compact <manifest> --dry-run [--state-db <path>] [--json|--output text|json]
      hostwright state compact <manifest> --confirm-compact <token> [--state-db <path>] [--json|--output text|json]
      hostwright secret create <keychain-reference> [--state-db <path>] [--json|--output text|json]
      hostwright secret update <keychain-reference> [--state-db <path>] [--json|--output text|json]
      hostwright secret list [--json|--output text|json]
      hostwright secret check <keychain-reference> [--json|--output text|json]
      hostwright secret delete <keychain-reference> [--state-db <path>] [--json|--output text|json]
      hostwright registry login <registry> --username <name> [--state-db <path>] [--json|--output text|json]
      hostwright registry logout <registry> [--state-db <path>] [--json|--output text|json]
      hostwright registry status <registry> [--repository <name> [--action pull|push]...] [--json|--output text|json]
      hostwright registry referrers discover|fetch <registry> --repository <name> --subject <digest> [--artifact-type <media-type>] [--offline] [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers publish <discovery-uuid> --target-server <registry> --target-repository <name> [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers copy <registry> --repository <name> --subject <digest> [--artifact-type <media-type>] --target-server <registry> --target-repository <name> [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers retain <discovery-uuid> --owner <id> --expires-at <timestamp> [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers release <lease-uuid> --fencing-token <uuid> [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers status <discovery-uuid> [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers prune <discovery-uuid> --digest <digest> [--confirm-plan <sha256>] [--state-db <path>] [--json|--output text|json]
      hostwright registry referrers resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json|--output text|json]
      hostwright registry trust verify <discovery-uuid> --manifest <path> --subject-manifest <absolute-path> --cosign <absolute-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry trust status <manifest-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry trust grant-exception <absolute-approval-path> --manifest <path> [--state-db <path>] [--json|--output text|json]
      hostwright registry trust revoke-exception <exception-uuid> [--state-db <path>] [--json|--output text|json]
      hostwright registry sbom generate <absolute-oci-archive> --manifest <absolute-path> [--service <name>] --server <registry> --repository <name> --format spdx-json|cyclonedx-json [--provenance-descriptor-digest <digest> --provenance-referrer-digest <digest>] [--state-db <path>] [--json|--output text|json]
      hostwright registry sbom ingest <discovery-uuid> --manifest <absolute-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry sbom query <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry sbom export <absolute-manifest-path> [--service <name>] --format spdx-json|cyclonedx-json --output-path <absolute-new-path> [--state-db <path>] [--json|--output text|json]
      hostwright registry sbom resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json|--output text|json]
      hostwright registry vulnerability evaluate <discovery-uuid> --digest <report-referrer-digest> --manifest <absolute-path> --cosign <absolute-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry vulnerability status <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry vulnerability grant-exception <absolute-approval-path> --manifest <absolute-path> [--state-db <path>] [--json|--output text|json]
      hostwright registry vulnerability revoke-exception <exception-uuid> [--state-db <path>] [--json|--output text|json]
      hostwright registry vulnerability resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json|--output text|json]
      hostwright registry provenance generate <absolute-oci-archive> --record <absolute-build-record> --manifest <absolute-path> [--service <name>] --server <registry> --repository <name> --signer <id> --signing-key-ref <typed-secret-reference> [--state-db <path>] [--json|--output text|json]
      hostwright registry provenance verify <discovery-uuid> --digest <provenance-referrer-digest> --manifest <absolute-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry provenance status <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json|--output text|json]
      hostwright registry provenance resume <operation-group-uuid> --confirm-plan <sha256> [--signing-key-ref <typed-secret-reference>] [--state-db <path>] [--json|--output text|json]
      hostwright image inspect <reference>... [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright volume list [--project <id>] [--state-db <path>] [--json|--output text|json]
      hostwright volume inspect <volume-uuid> [--state-db <path>] [--json|--output text|json]
      hostwright volume capacity|health [--state-db <path>] [--json|--output text|json]
      hostwright volume recover <volume-uuid> --idempotency-key <key> [--state-db <path>] [--json|--output text|json]
      hostwright volume delete <volume-uuid> (--dry-run|--confirm-plan <sha256>) [--state-db <path>] [--json|--output text|json]
      hostwright volume prune (--dry-run|--confirm-plan <sha256>) [--state-db <path>] [--json|--output text|json]
      hostwright volume snapshot create|list|inspect|retain|export|restore|delete ...
      hostwright volume backup create|list|inspect|verify|retain|restore|delete ...
      hostwright daemon status [--json|--output text|json]
      hostwright daemon install --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml> [--json|--output text|json]
      hostwright daemon validate|bootstrap|start|stop|kickstart|rollback|disable|repair|uninstall [--json|--output text|json]
      hostwright daemon upgrade --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml> [--json|--output text|json]
      hostwright restart-budget status [--project <project-id>] [--state-db <path>] [--json|--output text|json]
      hostwright restart-budget release --project <project-id> --service <name> --confirm-hold <sha256> [--state-db <path>] [--json|--output text|json]
      hostwright maintenance preview <manifest> --action <create|start|restart|update|remove>... [--at <RFC3339-UTC>] [--json|--output text|json]
      hostwright maintenance status [--project <project-id>] [--state-db <path>] [--json|--output text|json]
      hostwright maintenance cancel --project <project-id> --confirm-deferral <sha256> [--state-db <path>] [--json|--output text|json]
      hostwright maintenance override --project <project-id> --confirm-deferral <sha256> --reason <text> [--state-db <path>] [--json|--output text|json]
      hostwright ownership status [--project <project-id>] [--state-db <path>] [--json|--output text|json]
      hostwright ownership handoff --group <uuid> --confirm-plan <sha256> --confirm-fence <uuid> --from-controller <id> --from-expiry <RFC3339-UTC> --to-controller resume|rollback --lease-seconds <1-900> [--state-db <path>] [--json|--output text|json]
      hostwright image pull|push <reference> [--platform linux/arm64|linux/amd64] [--offline] [--progress none|plain] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image tag <source> <target> [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image load --input <absolute-path> --reference <expected-reference>... [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image save <reference>... --output <absolute-path> [--platform linux/arm64|linux/amd64] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image build --context <absolute-path> [--file <absolute-path>] --tag <reference> [--platform linux/arm64|linux/amd64] [--offline] [--no-cache] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image delete <reference>... [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image prune [--dry-run|--confirm-plan <sha256>] [--maximum-bytes <bytes> --target-bytes <bytes>] [--retain-seconds <0-31536000>] [--max-delete <1-256>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image cache status [--maximum-bytes <bytes>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright image cache pin|unpin <managed-reference> [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--json|--output text|json]
      hostwright migrate preview <path> [--json|--output text|json]
      hostwright init
      hostwright import-stack <path> [--output text|json] [--team-profile <path>]
      hostwright validate [path] [--team-profile <path>]
      hostwright plan [path] [--output text|json] [--team-profile <path>]
      hostwright status [path] [--state-db <path>] [--output text|json] [--runtime-provider auto|apple-cli|containerization]
      hostwright apply [path] [--state-db <path>] --confirm-plan <hash> [--runtime-provider auto|apple-cli|containerization] [--team-profile <path> --approval-record <path>]
      hostwright up [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright down [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright run [path] --service <name> [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright start [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright stop [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright restart [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright rm [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright update [path] [--service <name>] [--state-db <path>] (--dry-run|--confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--json|--output text|json]
      hostwright exec <service> [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--tty|--no-tty] [--no-stdin] [--json|--output text|json] -- <command> [args...]
      hostwright attach <service> [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--tty|--no-tty] [--no-stdin] [--output text]
      hostwright copy (<absolute-host-path> <service:/absolute/container/path>|<service:/absolute/container/path> <absolute-host-path>) [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--json|--output text|json]
      hostwright export <service> <absolute-destination-path> [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--json|--output text|json]
      hostwright inspect <service> [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--json|--output text|json]
      hostwright stats <service> [--manifest <path>] [--state-db <path>] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--json|--output text|json]
      hostwright logs <service> [path] [--tail <n>] [--follow] [--runtime-provider <auto|apple-cli|containerization>] [--timeout <seconds>] [--state-db <path>] [--output <text|json>]
      hostwright events [--state-db <path>] [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <1...1000>] [--sort asc|desc] [--cursor beginning|<token>] [--watch] [--timeout <1...300>] [--output text|json]
      hostwright recovery [--state-db <path>] [--project <name>] [--output text|json]
      hostwright recovery resume --group <uuid> --confirm-plan <hash> [--timeout <seconds>] [--state-db <path>] [--project <name>] [--output text|json]
      hostwright recovery rollback --group <uuid> --confirm-plan <hash> [--timeout <seconds>] [--state-db <path>] [--project <name>] [--output text|json]
      hostwright cleanup [path] [--state-db <path>] --dry-run [--team-profile <path>]
      hostwright cleanup [path] [--state-db <path>] --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]
      hostwright diagnostics [--state-db <path>] --bundle <path> [--project <name>] [--manifest <path>]
      hostwright diagnostics support status [--state-db <path>] [--output text|json]
      hostwright diagnostics support preview [--state-db <path>] [--project <name>] [--manifest <path>] [--output text|json]
      hostwright diagnostics support create [--state-db <path>] [--project <name>] [--manifest <path>] --output-path <absolute-new-path> --confirm-preview <sha256> [--encrypt-recipient <keychain-certificate-reference>] [--output text|json]
      hostwright diagnostics support delete [--state-db <path>] --bundle <absolute-path> --confirm-bundle <sha256> [--output text|json]
      hostwright diagnostics support recover [--state-db <path>] [--output text|json]
      hostwright benchmark --image <local-image> --samples <3-10> --report <path> --source-commit <40-hex> --source-dirty <true|false> --expected-container-version <version> [--attended-sleep-wake-seconds <15-300>] --confirm-live
      hostwright extension check --declaration <absolute-path> --executable <absolute-path> [--output text|json]
      hostwright doctor [--state-db <path>] [--json|--output text|json]

    Most commands are read-only. capabilities reports tested maturity without probing or mutating the host.
    runtime providers negotiates immutable provider capabilities without changing runtime or state.
    paths reports the resolved macOS-native layout and override origin without creating files.
    state integrity performs SQLite, foreign-key, migration, schema-object, and logical contract checks.
    state backup uses SQLite's online backup API and publishes only a verified private catalog entry.
    state restore and repair require a dry-run token bound to the exact state fingerprint and planned effects.
    state repair clears only reconstructible runtime-observation and health projections; it never invents authoritative state.
    state recover completes or rolls back a journaled maintenance operation before ordinary state access resumes.
    state retention reports bounded class, hold, recovery-horizon, and pressure decisions without mutation.
    state compact requires an exact dry-run token, creates a verified backup, and deletes only revalidated eligible records.
    secret create and update read values only from stdin or an attended no-echo TTY; command arguments, output, and state contain metadata only.
    registry login reads its secret through the same protected input boundary and persists only an exact endpoint-bound Hostwright Keychain item. status also supports guarded Docker and OCI credential stores and never emits credentials.
    registry referrers discovers, verifies, caches, copies, publishes, retains, recovers, and exactly cleans opaque subject-bound OCI artifacts. Offline reads use only complete verified cache records; prune requires exact Hostwright ownership, no active lease, and plan confirmation.
    registry trust verifies exact digest-bound Sigstore v0.3 bundles with a safe cosign v3 verifier, records immutable evidence, reports policy status, and manages exact time-bounded exceptions. Credentials never enter verifier argv, logs, diagnostics, or state.
    registry sbom generates, ingests, queries, exports, and recovers exact digest-bound SPDX or CycloneDX image evidence.
    registry vulnerability verifies signed reports, records explainable exact-digest decisions, applies only exact time-bounded approvals, and revalidates policy before lifecycle or recovery effects.
    registry provenance generates and verifies exact-image DSSE-wrapped in-toto/SLSA v1 build attestations, persists immutable Gate 6 graph evidence, and resolves signing keys only through typed secret-provider references.
    image mutations use the Apple CLI provider, durable intent, structured post-operation digest verification, exact ownership, and exact rollback/cleanup. Containerization image mutations report unavailable before effects.
    recovery inspects durable lifecycle groups; resume and rollback require the exact group UUID and persisted plan hash.
    migrate preview validates and prints an in-memory v1-to-v2 conversion; it never writes the source file.
    init writes hostwright.yaml only when absent.
    import-stack reads a narrow safe stack-file subset and prints converted hostwright.yaml; it does not write files, observe runtime, or imply Compose parity.
    CLI plan output is deterministic but does not perform live runtime observation.
    Apply is a compatibility entry point for an exact confirmed up lifecycle plan. Generate its hash with up --dry-run; execution uses the same durable DAG and saga as up.
    Lifecycle dry-runs emit deterministic plans; confirmed up, down, run, start, stop, restart, rm, and update executions emit deterministic per-resource outcomes. Every lifecycle command supports --json or --output json.
    Cleanup deletes only exact cleanup-eligible Hostwright-owned stopped/created/exited containers after dry-run token confirmation.
    Diagnostics-v1 remains a local redacted JSON export. Support bundles add bounded preview, confirmation-bound local creation, optional Keychain CMS encryption, durable recovery, and exact receipt-proven deletion. Neither workflow uploads telemetry.
    JSON output is supported for capabilities, paths, migrate preview, restart-budget, maintenance, ownership, metrics, traces, support bundles, every state, secret, registry, and image subcommand, import-stack, plan, status, every lifecycle command, events, recovery, extension check, doctor, and errors when --json or --output json is present.
    Team profiles and approvals are loaded only from explicit local paths. Profile-aware mutations require an approval bound to the exact profile, manifest, and plan or cleanup token.
    Benchmark runs are explicit local hardware evidence. They refuse image pulls and broad cleanup, use bounded disposable Hostwright-owned resources, and write only the requested non-existing report path.
    Extension check executes one reviewed-local protocol handshake from explicit absolute paths. The protocol grants no Hostwright capability, but the reviewed executable still has the invoking macOS account's ambient privileges; it is not sandboxed.

    Examples:
      hostwright plan --output json
      hostwright runtime providers --json
      hostwright import-stack compose.yaml --output json
      hostwright paths --json
      hostwright state integrity --json
      hostwright state backup --json
      hostwright state backups --json
      hostwright state retention hostwright.yaml --json
      hostwright status --output json
      hostwright events --project api-local --output json
      hostwright recovery --output json
      hostwright diagnostics --bundle ./hostwright-diagnostics.json
      hostwright diagnostics support preview --output json
      hostwright benchmark --image docker.io/library/python:alpine --samples 3 --report /tmp/hostwright-benchmark.json --source-commit 0123456789012345678901234567890123456789 --source-dirty true --expected-container-version 1.0.0 --confirm-live
      hostwright extension check --declaration /tmp/extension.json --executable /tmp/extension --output json
      hostwright doctor --output json

    """

    private static func renderCapabilities(_ report: HostwrightCapabilityReport) -> String {
        let header = "Hostwright \(report.productVersion) (target \(report.releaseTarget))\n"
        let contracts = "Contracts: manifest v\(report.contracts.manifest), control API v\(report.contracts.controlAPI), runtime provider API v\(report.contracts.runtimeProviderAPI), storage provider API v\(report.contracts.storageProviderAPI), network provider SPI v\(report.contracts.networkProviderSPI), plugin ABI v\(report.contracts.pluginABI), state schema v\(report.contracts.stateSchema)\n"
        let rows = report.capabilities.map {
            "\($0.identifier)\t\($0.state.rawValue)\tphase \(String(format: "%02d", $0.phase))\t#\($0.issue)\t\($0.title)"
        }.joined(separator: "\n")
        return header + contracts + rows + "\n"
    }

    private static func renderLocalPaths(
        _ resolution: HostwrightLocalPathResolution,
        readiness: HostwrightLocalPathReadiness,
        daemonLockPath: String,
        migrationJournalExists: Bool,
        policyError: String?
    ) -> String {
        let policyLine = policyError.map { "Path policy error: \($0)\n" } ?? ""
        return """
        Hostwright local paths
        State origin: \(resolution.statePathOrigin.rawValue)
        Readiness: \(readiness.rawValue)
        State DB: \(resolution.stateDatabasePath)
        Application Support: \(resolution.layout.applicationSupportDirectory)
        Configuration: \(resolution.layout.configurationDirectory)
        Runtime: \(resolution.layout.runtimeDirectory)
        Metadata: \(resolution.layout.metadataDirectory)
        Backups: \(resolution.layout.backupsDirectory)
        Caches: \(resolution.layout.cacheDirectory)
        Logs: \(resolution.layout.logDirectory)
        Control socket: \(resolution.layout.controlSocket)
        Daemon lock: \(daemonLockPath)
        Legacy state candidate: \(resolution.legacyStateDatabase)
        Migration journal: \(resolution.legacyStateMigrationJournal) (\(migrationJournalExists ? "present" : "absent"))
        \(policyLine)

        """
    }

    private static func localPathStatus(
        resolution: HostwrightLocalPathResolution,
        environment: CLIEnvironment
    ) -> (
        readiness: HostwrightLocalPathReadiness,
        targetExists: Bool,
        legacyExists: Bool,
        migrationJournalExists: Bool,
        policyError: String?
    ) {
        let targetExists = environment.fileExists(resolution.stateDatabasePath)
        let legacyExists = environment.fileExists(resolution.legacyStateDatabase)
        let migrationJournalExists = resolution.usesApplicationSupportState &&
            environment.fileExists(resolution.legacyStateMigrationJournal)
        if targetExists && legacyExists {
            return (.blockedConflict, true, true, migrationJournalExists, nil)
        }
        do {
            try StateStoreConfiguration(localPathResolution: resolution)
                .validateProspectivePath()
        } catch {
            return (
                .blockedPolicy,
                targetExists,
                legacyExists,
                migrationJournalExists,
                doctorDiagnostic(error)
            )
        }
        if migrationJournalExists {
            return (.migrationRequired, targetExists, legacyExists, true, nil)
        }
        if targetExists {
            return (.ready, true, false, false, nil)
        }
        if resolution.usesApplicationSupportState && legacyExists {
            return (.migrationRequired, false, true, false, nil)
        }
        return (.needsCreation, false, legacyExists, false, nil)
    }

    private static func initManifest(environment: CLIEnvironment) throws -> CLIRunResult {
        let path = HostwrightIdentity.manifestFileName
        if environment.fileExists(path) {
            return failure(code: .fileAlreadyExists, message: "\(path) already exists. init will not overwrite it.")
        }

        try hostwrightWriteLocalText(path: path, text: starterManifest, role: "starter manifest", environment: environment)
        return CLIRunResult(standardOutput: "Created \(path)\n")
    }

    private static func importStack(
        path: String,
        output: CLIOutputFormat,
        teamProfilePath: String?,
        environment: CLIEnvironment
    ) throws -> CLIRunResult {
        let text = try hostwrightReadLocalText(path: path, role: "stack file", environment: environment)
        let result = StackFileImporter.convert(text)
        let exitCode: CLIExitCode = result.succeeded ? .success : .validation
        var validatedManifest: TeamValidatedManifest?
        if let manifestText = result.manifestText, result.succeeded {
            validatedManifest = try hostwrightValidatedManifest(
                text: manifestText,
                teamProfilePath: teamProfilePath,
                environment: environment
            )
        }

        if output == .json {
            if result.succeeded {
                return CLIRunResult(
                    standardOutput: CLIJSON.stackImport(path: path, result: result, validatedManifest: validatedManifest),
                    exitCode: exitCode.rawValue
                )
            }
            return CLIRunResult(standardError: CLIJSON.stackImportError(path: path, result: result, exitCode: exitCode), exitCode: exitCode.rawValue)
        }

        if result.succeeded, let manifestText = result.manifestText {
            let warningText = result.warnings.isEmpty ? "" : result.warnings.map(\.rendered).joined(separator: "\n") + "\n"
            let teamText = validatedManifest.map { hostwrightTeamProfileText($0) } ?? ""
            return CLIRunResult(standardOutput: manifestText, standardError: warningText + teamText, exitCode: exitCode.rawValue)
        }

        return CLIRunResult(
            standardError: result.errors.map(\.rendered).joined(separator: "\n") + "\n",
            exitCode: exitCode.rawValue
        )
    }

    private static func doctor(
        stateDatabasePath: String?,
        environment: CLIEnvironment,
        output: CLIOutputFormat
    ) -> CLIRunResult {
        let pathResolution: HostwrightLocalPathResolution?
        let pathResolutionError: String?
        do {
            pathResolution = try environment.localPathResolution(stateDatabasePath)
            pathResolutionError = nil
        } catch {
            pathResolution = nil
            pathResolutionError = doctorDiagnostic(error)
        }
        let pathStatus = pathResolution.map {
            localPathStatus(resolution: $0, environment: environment)
        }
        let containerExecutablePath = environment.executablePath("container")
        let runtimeSnapshot = doctorRuntimeSnapshot(
            containerExecutablePath: containerExecutablePath,
            environment: environment
        )
        let stateSnapshot = doctorStateSnapshot(
            resolution: pathResolution,
            pathStatus: pathStatus
        )
        let inputs = DoctorInputs(
            operatingSystemDescription: environment.operatingSystemDescription(),
            platform: environment.platformSnapshot(),
            containerExecutablePath: containerExecutablePath,
            manifestExists: environment.fileExists(HostwrightIdentity.manifestFileName),
            runtimeSnapshot: runtimeSnapshot,
            stateSnapshot: stateSnapshot,
            systemSnapshot: environment.doctorSystemSnapshot(),
            resourceSnapshot: environment.resourceSnapshot(),
            localPathResolution: pathResolution,
            localPathReadiness: pathStatus?.readiness,
            localPathPolicyError: pathStatus?.policyError ?? pathResolutionError
        )
        let report = HostwrightDoctor.report(inputs: inputs)
        let exitCode = doctorExitCode(report)
        if output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.doctor(report),
                exitCode: exitCode.rawValue
            )
        }
        let lines = report.checks.flatMap { check -> [String] in
            let message = RuntimeRedactionPolicy.default.redact(check.message)
            var rendered = [
                "[\(check.status.rawValue)] \(check.identifier.rawValue): \(message)"
            ]
            if let remediation = check.remediation {
                rendered.append(
                    "  Remediation: \(RuntimeRedactionPolicy.default.redact(remediation))"
                )
            }
            return rendered
        }
        return CLIRunResult(
            standardOutput: "Hostwright doctor\nReadiness: \(report.readiness.rawValue)\n"
                + lines.joined(separator: "\n")
                + "\n",
            exitCode: exitCode.rawValue
        )
    }

    private static func doctorRuntimeSnapshot(
        containerExecutablePath: String?,
        environment: CLIEnvironment
    ) -> DoctorRuntimeSnapshot {
        guard containerExecutablePath != nil else {
            return DoctorRuntimeSnapshot(
                availability: .cliMissing,
                diagnostic: "Apple container CLI was not found."
            )
        }
        do {
            let adapter = environment.runtimeAdapter()
            let report = try hostwrightWaitForAsync {
                try await adapter.runtimeReadiness()
            }
            let availability: DoctorRuntimeAvailability
            switch report.serviceState {
            case .running:
                availability = .ready
            case .notRunning:
                availability = .serviceNotRunning
            case .unregistered:
                availability = .serviceUnregistered
            }
            return DoctorRuntimeSnapshot(
                availability: availability,
                cliVersion: report.cliVersion,
                serviceVersion: report.serviceVersion,
                serviceBuild: report.serviceBuild
            )
        } catch let error as RuntimeAdapterError {
            let availability: DoctorRuntimeAvailability
            if case .permissionDenied = error {
                availability = .permissionDenied
            } else {
                availability = .probeFailed
            }
            return DoctorRuntimeSnapshot(
                availability: availability,
                diagnostic: doctorDiagnostic(error.redacted())
            )
        } catch {
            return DoctorRuntimeSnapshot(
                availability: .probeFailed,
                diagnostic: doctorDiagnostic(error)
            )
        }
    }

    private static func doctorStateSnapshot(
        resolution: HostwrightLocalPathResolution?,
        pathStatus: (
            readiness: HostwrightLocalPathReadiness,
            targetExists: Bool,
            legacyExists: Bool,
            migrationJournalExists: Bool,
            policyError: String?
        )?
    ) -> DoctorStateSnapshot {
        guard let resolution, let pathStatus else {
            return DoctorStateSnapshot(
                availability: .inspectionFailed,
                diagnostic: "The state path could not be resolved for immutable inspection."
            )
        }
        guard pathStatus.targetExists else {
            return DoctorStateSnapshot(availability: .absent)
        }
        guard pathStatus.readiness != .blockedConflict,
              pathStatus.readiness != .blockedPolicy else {
            return DoctorStateSnapshot(
                availability: .inspectionFailed,
                diagnostic: pathStatus.policyError
                    ?? "State integrity inspection was refused because path policy is blocked."
            )
        }

        let configuration = StateStoreConfiguration(localPathResolution: resolution)
        let report: StateIntegrityReport
        do {
            report = try StateIntegrityService(
                store: SQLiteStateStore(configuration: configuration)
            ).inspectNonMutating()
        } catch {
            return DoctorStateSnapshot(
                availability: .inspectionFailed,
                diagnostic: doctorDiagnostic(error),
                recommendedAction: doctorStateInspectionRemediation(error)
            )
        }
        let diagnostic = report.checks
            .filter { $0.status != .passed }
            .prefix(3)
            .map(\.message)
            .joined(separator: "; ")
        let availability: DoctorStateAvailability
        switch report.health {
        case .healthy:
            availability = .healthy
        case .degraded:
            availability = .degraded
        case .unrecoverable:
            availability = .unrecoverable
        }
        return DoctorStateSnapshot(
            availability: availability,
            stateSchemaVersion: report.stateSchemaVersion,
            databaseSHA256: report.databaseSHA256,
            diagnostic: diagnostic.isEmpty ? nil : doctorBounded(diagnostic),
            recommendedAction: doctorBounded(report.recommendedAction)
        )
    }

    private static func doctorStateInspectionRemediation(_ error: Error) -> String {
        guard let error = error as? StateStoreError else {
            return "Run hostwright state integrity after the state file becomes stable; use explicit recovery only if that check proves damage."
        }
        switch error {
        case .databaseLocked:
            return "Wait for the active state operation to finish, then run hostwright doctor again."
        case .maintenanceRecoveryRequired:
            return "Run hostwright state recover, verify integrity, then run hostwright doctor again."
        case .pathPolicyViolation, .invalidPath:
            return "Correct state ownership, permissions, ACL, symlink, or file-identity policy before retrying doctor."
        case .corruptDatabase, .incompatibleSchema:
            return "Run hostwright state integrity and use a verified backup or explicit recovery only if the report confirms damage."
        default:
            return "Run hostwright state integrity after the state file becomes stable; use explicit recovery only if that check proves damage."
        }
    }

    private static func doctorExitCode(_ report: DoctorReport) -> CLIExitCode {
        if report.checks.contains(where: { $0.status == .unsupported }) {
            return .validation
        }
        if report.checks.contains(where: {
            ($0.identifier == .statePathPolicy || $0.identifier == .statePermissions)
                && $0.status == .blocked
        }) {
            return .validation
        }
        if report.checks.contains(where: {
            $0.identifier == .stateIntegrity && $0.status == .blocked
        }) {
            return .stateUnavailable
        }
        if report.hasFailures {
            return .validation
        }
        if report.hasExternalConstraints {
            return .runtimeUnavailable
        }
        return .success
    }

    private static func doctorDiagnostic(_ error: Error) -> String {
        doctorBounded(String(describing: error))
    }

    private static func doctorBounded(_ value: String) -> String {
        let normalized = RuntimeRedactionPolicy.default.redact(value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(normalized.prefix(512))
    }

    private static func checkExtension(
        declarationPath: String,
        executablePath: String,
        output: CLIOutputFormat
    ) throws -> CLIRunResult {
        let result = try ReviewedLocalExtensionHost().check(
            declarationURL: URL(fileURLWithPath: declarationPath),
            executableURL: URL(fileURLWithPath: executablePath)
        )
        if output == .json {
            return CLIRunResult(standardOutput: CLIJSON.extensionHandshake(result))
        }
        return CLIRunResult(
            standardOutput: """
            Reviewed-local extension handshake ready
            Identifier: \(result.identifier)
            Capability: \(result.capability.rawValue)
            Protocol version: \(result.protocolVersion)
            Declaration SHA-256: \(result.declarationSHA256)
            Executable SHA-256: \(result.executableSHA256)
            Duration: \(result.durationMilliseconds) ms
            Staging cleanup: succeeded

            """
        )
    }

    private static func loadValidManifest(
        path: String,
        teamProfilePath: String?,
        environment: CLIEnvironment
    ) throws -> TeamValidatedManifest {
        let text = try hostwrightReadManifestText(path: path, environment: environment)
        return try hostwrightValidatedManifest(text: text, teamProfilePath: teamProfilePath, environment: environment)
    }

    private static func failure(issues: [ManifestIssue], output: CLIOutputFormat = .text) -> CLIRunResult {
        let exitCode = CLIExitCode.validation
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.manifestError(issues: issues, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: render(issues: issues), exitCode: exitCode.rawValue)
    }

    private static func render(issues: [ManifestIssue]) -> String {
        issues.map(\.rendered).joined(separator: "\n") + "\n"
    }

    private static func failure(code: HostwrightErrorCode, message: String, output: CLIOutputFormat = .text) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        let redactedMessage = RuntimeRedactionPolicy.default.redact(message)
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.error(code: code, message: redactedMessage, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: "\(code.rawValue): \(redactedMessage)\n", exitCode: exitCode.rawValue)
    }
}
