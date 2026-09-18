import Foundation
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LocalSchedulerDaemonLifecycleTests: XCTestCase {
    func testUnexpectedStopReleasesThenReacquiresThroughUnattendedLifecycle() throws {
        try assertUnexpectedStopRecovery()
    }

    func testUpdatedGenerationReacquiresThroughUnattendedLifecycle() throws {
        try assertUnexpectedStopRecovery(update: true)
    }

    private func assertUnexpectedStopRecovery(update: Bool = false) throws {
        try withFixture { fixture in
            try fixture.wait {
                await fixture.adapter.useAuthoritativeInventory()
                await fixture.adapter.setPreserveExistingOwnershipFenceOnMutation(true)
            }
            let environment = try fixture.localSchedulerEnvironment()
            try run(.up, fixture: fixture, environment: environment)
            if update {
                fixture.manifestSource.replace(fixture.manifestSource.value.replacingOccurrences(
                    of: "cpus: 1", with: "cpus: 2"
                ))
                try run(.update, fixture: fixture, environment: environment)
            }
            let previous = try XCTUnwrap(fixture.store.schedulerAdmissions.activeReservations().first)
            let manifest = try ManifestValidator.validated(fixture.manifestSource.value)
            let desired = try XCTUnwrap(ManifestRuntimeMapper.map(
                manifest, projectResourceUUID: previous.projectUUID, schedulerAdmissionValidated: true
            ).desiredState.services.first)
            let running = try XCTUnwrap(fixture.wait { try await fixture.adapter.inventory() }.containers.first)
            try fixture.wait {
                await fixture.adapter.seedRecoveryResource(
                    desired: desired, resourceIdentifier: running.name, lifecycle: .stopped,
                    ownership: running.ownership
                )
            }
            let stopped = try fixture.wait { try await fixture.adapter.inventory() }
            try LifecycleSchedulerSession.reconcile(
                store: fixture.store, projectUUID: previous.projectUUID, providerID: .appleContainerCLI,
                inventory: stopped
            )
            XCTAssertTrue(try fixture.store.schedulerAdmissions.activeReservations().isEmpty)
            let project = try fixture.store.desiredStates.loadProject(id: fixture.projectID)
            let authority = try XCTUnwrap(DaemonLocalLifecycleAuthority.resolve(
                store: fixture.store, manifest: manifest, manifestSHA256: project.manifestHash,
                projectID: fixture.projectID
            ))
            XCTAssertEqual(authority.entries.first?.reservation.status, .released)
            let target = try DaemonConfigurationTarget(
                kind: .manifest, path: fixture.manifestPath, contentSHA256: project.manifestHash,
                byteCount: fixture.manifestSource.value.utf8.count, device: 1, inode: 1
            )
            let binding = DaemonSchedulerAuthorityBinding(localLifecycleAuthority: authority)
            let request = try DaemonReconciliationRequest(
                manifestPath: fixture.manifestPath, manifestSHA256: project.manifestHash,
                configurationSetSHA256: DaemonConfigurationSetDigest.sha256([target]),
                configurationTargets: [target], stateDatabasePath: fixture.databasePath,
                projectID: fixture.projectID, maximumParallelism: 1,
                selectedServiceNames: ["api"], schedulerAuthorityBinding: binding
            )
            let result = try fixture.wait {
                try await UnattendedLifecycleReconciler(
                    readManifest: { try environment.readTextFile($0) },
                    makeDriver: { LifecycleLiveDriver(environment: environment, options: $0) },
                    makeAuthorizedDriver: { options, check in
                        LifecycleLiveDriver(environment: environment, options: options, schedulerAuthorityValidator: check)
                    }
                )
                    .reconcileAuthorized(request: request, schedulerAuthorityBinding: binding)
            }
            XCTAssertEqual(result.status, .mutated, result.recoveryHintRedacted)
            let current = try fixture.store.schedulerAdmissions.activeReservations()
            XCTAssertEqual(current.count, 1)
            XCTAssertEqual(current.first?.status, .committed)
            XCTAssertNotEqual(current.first?.reservationID, previous.reservationID)
            XCTAssertEqual(try fixture.wait { try await fixture.adapter.inventory() }.containers.first?.lifecycle, .running)
        }
    }

    func testExplicitDownAndRemovalDoNotAuthorizeDaemonRestart() throws {
        try withFixture { fixture in
            try fixture.wait {
                await fixture.adapter.useAuthoritativeInventory()
                await fixture.adapter.setPreserveExistingOwnershipFenceOnMutation(true)
            }
            let environment = try fixture.localSchedulerEnvironment()
            for command: LifecycleCommandKind in [.up, .update, .down, .up, .rm] {
                if command == .update {
                    fixture.manifestSource.replace(fixture.manifestSource.value.replacingOccurrences(
                        of: "cpus: 1", with: "cpus: 2"
                    ))
                }
                try run(command, fixture: fixture, environment: environment)
                let manifest = try ManifestValidator.validated(fixture.manifestSource.value)
                let project = try fixture.store.desiredStates.loadProject(id: fixture.projectID)
                let authority = try XCTUnwrap(DaemonLocalLifecycleAuthority.resolve(
                    store: fixture.store, manifest: manifest, manifestSHA256: project.manifestHash,
                    projectID: fixture.projectID
                ))
                XCTAssertEqual(authority.entries.isEmpty, command == .down || command == .rm)
            }
        }
    }

    private func run(
        _ command: LifecycleCommandKind, fixture: LifecycleLiveDriverFixture, environment: CLIEnvironment
    ) throws {
        let preview = fixture.options(command: command, dryRun: true)
        let result = LifecycleCommandRunner(
            options: preview, driver: LifecycleLiveDriver(environment: environment, options: preview)
        ).run()
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let plan = try JSONDecoder().decode(LifecyclePlan.self, from: Data(result.standardOutput.utf8))
        let options = fixture.options(command: command, dryRun: false, confirmation: plan.planSHA256)
        let executed = LifecycleCommandRunner(
            options: options, driver: LifecycleLiveDriver(environment: environment, options: options)
        ).run()
        XCTAssertEqual(executed.exitCode, 0, executed.standardError)
    }
}
