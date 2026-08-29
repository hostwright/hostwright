import XCTest
@testable import HostwrightManifest

final class ManifestV3AdmissionContractTests: XCTestCase {
    func testParserAndValidatorRejectV3ServiceWithoutResources() throws {
        let source = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
        """

        let parsed = try ManifestParser.parse(source)
        let issues = ManifestValidator.validate(parsed)
        XCTAssertTrue(
            issues.contains {
                $0.message.contains("explicit requests and limits")
            }
        )
    }

    func testDirectV3ValidationRejectsMissingResourcesBeforeAdmission() {
        let manifest = HostwrightManifest(
            version: 3,
            project: "demo",
            services: [HostwrightService(name: "api", image: "local/demo:latest")]
        )

        let issues = ManifestValidator.validate(manifest)
        XCTAssertTrue(
            issues.contains {
                $0.message.contains("explicit requests and limits")
            }
        )
    }

    func testMigrationRefusesToInventCapacityForLegacyServiceWithoutResources() {
        let source = """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest
        """

        XCTAssertThrowsError(try ManifestMigrator.previewV3(source)) { error in
            let parseError = error as? ManifestParseError
            XCTAssertTrue(
                parseError?.issues.contains {
                    $0.path == "$.services.api.resources" &&
                        $0.message.contains("migration cannot infer capacity")
                } == true
            )
        }
    }

    func testSatisfiableOpenDomainAffinityPairsAreAccepted() throws {
        let service = HostwrightService(
            name: "api",
            image: "local/demo:latest",
            resources: executableResources,
            scheduling: HostwrightSchedulingPolicy(
                requiredAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone",
                        operator: .in,
                        values: ["east", "west"]
                    )
                ],
                requiredAntiAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone",
                        operator: .in,
                        values: ["west"]
                    )
                ]
            )
        )

        XCTAssertTrue(
            ManifestValidator.validate(
                HostwrightManifest(version: 3, project: "demo", services: [service])
            ).isEmpty
        )
    }

    func testDuplicatePreferredSelectorIsRejectedRegardlessOfWeight() {
        let selector = HostwrightSchedulingSelector(
            key: "zone",
            operator: .in,
            values: ["east"]
        )
        let service = HostwrightService(
            name: "api",
            image: "local/demo:latest",
            resources: executableResources,
            scheduling: HostwrightSchedulingPolicy(
                preferredAffinity: [
                    HostwrightSchedulingPreference(weight: 10, match: selector),
                    HostwrightSchedulingPreference(weight: 20, match: selector)
                ]
            )
        )

        let messages = ManifestValidator.validate(
            HostwrightManifest(version: 3, project: "demo", services: [service])
        ).map(\.message)
        XCTAssertTrue(
            messages.contains {
                $0.contains(
                    "scheduling.preferredAffinity must not contain duplicate preferences."
                )
            }
        )
    }

    private var executableResources: HostwrightResources {
        HostwrightResources(
            requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
            limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
        )
    }
}
