import CryptoKit
import Foundation
import HostwrightCore
import Security

public enum DeveloperIDIdentityParser {
    public static func parse(_ output: String) -> [TrustedReleaseIdentity] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let text = String(line)
            guard let match = text.firstMatch(
                of: /^\s*\d+\)\s+([A-F0-9]{40})\s+"([^"]+)"\s*$/
            ) else {
                return nil
            }
            let fingerprint = String(match.output.1)
            let commonName = String(match.output.2)
            let kind: TrustedReleaseIdentityKind
            if commonName.hasPrefix("Developer ID Application: ") {
                kind = .application
            } else if commonName.hasPrefix("Developer ID Installer: ") {
                kind = .installer
            } else {
                return nil
            }
            guard let teamMatch = commonName.firstMatch(of: /\(([A-Z0-9]{10})\)$/) else {
                return nil
            }
            return TrustedReleaseIdentity(
                kind: kind,
                sha1Fingerprint: fingerprint,
                commonName: commonName,
                teamIdentifier: String(teamMatch.output.1)
            )
        }
    }
}

public struct DeveloperIDIdentityResolver: Sendable {
    private let runner: DistributionProcessRunner

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
    }

    public func resolve(
        fingerprint: String,
        kind: TrustedReleaseIdentityKind,
        expectedTeamIdentifier: String,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> (identity: TrustedReleaseIdentity, command: DistributionCommandResult) {
        guard fingerprint.range(of: "^[A-F0-9]{40}$", options: .regularExpression) != nil,
              expectedTeamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw DistributionError.invalidArguments("Developer ID fingerprints and team identifiers must use exact uppercase identity text.")
        }
        let result = try runner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-identity", "-v"],
            label: "resolve exact Developer ID identity",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        let matches = DeveloperIDIdentityParser.parse(result.standardOutput).filter {
            $0.sha1Fingerprint == fingerprint && $0.kind == kind
        }
        guard matches.count == 1, let identity = matches.first else {
            throw DistributionError.invalidArtifact("the exact required Developer ID identity is unavailable or ambiguous")
        }
        let sameName = DeveloperIDIdentityParser.parse(result.standardOutput).filter {
            $0.commonName == identity.commonName
        }
        guard sameName.count == 1 else {
            throw DistributionError.invalidArtifact("the required Developer ID common name is ambiguous")
        }
        try identity.validate()
        guard identity.teamIdentifier == expectedTeamIdentifier else {
            throw DistributionError.invalidArtifact("the selected Developer ID identity belongs to a different team")
        }
        return (identity, result)
    }
}

enum TrustedCMSSignerInspector {
    static func inspect(
        signature: URL,
        detachedContent: URL
    ) throws -> (sha1Fingerprint: String, commonName: String) {
        let maximumSignatureBytes: UInt64 = 4 * 1_024 * 1_024
        let maximumContentBytes: UInt64 = 32 * 1_024 * 1_024
        guard try DistributionFileSystem.isRegularNonSymlink(signature),
              try DistributionFileSystem.isRegularNonSymlink(detachedContent),
              try DistributionFileSystem.size(of: signature) <= maximumSignatureBytes,
              try DistributionFileSystem.size(of: detachedContent) <= maximumContentBytes else {
            throw DistributionError.invalidArtifact("detached CMS input is missing, unsafe, or oversized")
        }
        let signatureData = try Data(contentsOf: signature, options: .mappedIfSafe)
        let contentData = try Data(contentsOf: detachedContent, options: .mappedIfSafe)
        guard !signatureData.isEmpty, !contentData.isEmpty else {
            throw DistributionError.invalidArtifact("detached CMS input cannot be empty")
        }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw DistributionError.invalidArtifact("detached CMS decoder could not be created")
        }
        let encoded = signatureData as NSData
        guard CMSDecoderUpdateMessage(decoder, encoded.bytes, encoded.length) == errSecSuccess,
              CMSDecoderSetDetachedContent(decoder, contentData as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw DistributionError.invalidArtifact("detached CMS data is malformed")
        }
        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess,
              signerCount == 1 else {
            throw DistributionError.invalidArtifact("detached CMS must contain exactly one signer")
        }
        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess,
              let certificate else {
            throw DistributionError.invalidArtifact("detached CMS signer certificate is unavailable")
        }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              let commonName else {
            throw DistributionError.invalidArtifact("detached CMS signer common name is unavailable")
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = Insecure.SHA1.hash(data: certificateData)
            .map { String(format: "%02X", $0) }
            .joined()
        return (fingerprint, commonName as String)
    }
}

public enum NotarytoolOutputParser {
    public static func acceptedRecord(
        output: String,
        artifactFileName: String,
        attachment: TrustedTicketAttachment,
        gatekeeperSource: String = "Notarized Developer ID"
    ) throws -> TrustedNotarizationRecord {
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = object["id"] as? String,
              let status = object["status"] as? String else {
            throw DistributionError.invalidArtifact("notarytool returned malformed JSON")
        }
        let record = TrustedNotarizationRecord(
            artifactFileName: artifactFileName,
            submissionID: identifier,
            status: status,
            ticketAttachment: attachment,
            gatekeeperSource: gatekeeperSource
        )
        try record.validate(expectedFileName: artifactFileName, expectedAttachment: attachment)
        return record
    }
}

struct TrustedNotaryTicketExpectation: Equatable, Sendable {
    let path: String
    let cdHash: String
    let architecture: String

    init(path: String, cdHash: String, architecture: String = "arm64") {
        self.path = path
        self.cdHash = cdHash.lowercased()
        self.architecture = architecture
    }
}

public enum NotarytoolLogParser {
    static func requireAcceptedTicketContents(
        output: String,
        archiveFileName: String,
        expectedTickets: [TrustedNotaryTicketExpectation]
    ) throws {
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "Accepted",
              object["archiveFilename"] as? String == archiveFileName,
              let ticketContents = object["ticketContents"] as? [[String: Any]] else {
            throw DistributionError.invalidArtifact("notarytool log did not describe an accepted archive ticket")
        }
        guard !expectedTickets.isEmpty,
              ticketContents.count == expectedTickets.count else {
            throw DistributionError.invalidArtifact("notarytool archive ticket contents do not match the signed executables")
        }

        var actualByPath: [String: TrustedNotaryTicketExpectation] = [:]
        for entry in ticketContents {
            guard let path = entry["path"] as? String,
                  let digestAlgorithm = entry["digestAlgorithm"] as? String,
                  let cdHash = entry["cdhash"] as? String,
                  let architecture = entry["arch"] as? String,
                  digestAlgorithm == "SHA-256",
                  cdHash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
                throw DistributionError.invalidArtifact("notarytool archive ticket content is malformed")
            }
            guard actualByPath[path] == nil else {
                throw DistributionError.invalidArtifact("notarytool archive ticket contains duplicate executable paths")
            }
            actualByPath[path] = TrustedNotaryTicketExpectation(
                path: path,
                cdHash: cdHash,
                architecture: architecture
            )
        }

        guard Set(actualByPath.keys) == Set(expectedTickets.map(\.path)) else {
            throw DistributionError.invalidArtifact("notarytool archive ticket paths do not match the signed executables")
        }
        for expected in expectedTickets {
            guard actualByPath[expected.path] == expected else {
                throw DistributionError.invalidArtifact("notarytool archive ticket hash or architecture differs for \(expected.path)")
            }
        }
    }
}

public enum TrustedReleaseSPDXFactory {
    public static func make(
        payloadManifest: DistributionArtifactManifest,
        artifact: DistributionArtifactDescriptor
    ) -> DistributionSPDXDocument {
        let packageID = "SPDXRef-Package-Hostwright"
        let files = payloadManifest.files.enumerated().map { index, file in
            SPDXFileRecord(
                fileName: "./\(file.path)",
                SPDXID: "SPDXRef-File-\(index + 1)",
                checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: file.sha256)],
                fileTypes: [file.path.hasPrefix("bin/") ? "BINARY" : "TEXT"],
                licenseConcluded: "Apache-2.0",
                copyrightText: "NOASSERTION"
            )
        }
        return DistributionSPDXDocument(
            spdxVersion: "SPDX-2.3",
            dataLicense: "CC0-1.0",
            SPDXID: "SPDXRef-DOCUMENT",
            name: "Hostwright \(payloadManifest.packageVersion) artifact-content SBOM",
            documentNamespace: "urn:hostwright:spdx:\(payloadManifest.sourceCommit):\(artifact.sha256)",
            creationInfo: SPDXCreationInfo(
                created: payloadManifest.createdAt,
                creators: ["Tool: hostwright-dist-2"]
            ),
            packages: [
                SPDXPackageRecord(
                    name: "Hostwright",
                    SPDXID: packageID,
                    versionInfo: payloadManifest.packageVersion,
                    downloadLocation: "NOASSERTION",
                    filesAnalyzed: true,
                    checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: artifact.sha256)],
                    licenseConcluded: "Apache-2.0",
                    licenseDeclared: "Apache-2.0",
                    copyrightText: "NOASSERTION"
                )
            ],
            files: files,
            relationships: [
                SPDXRelationship(
                    spdxElementId: "SPDXRef-DOCUMENT",
                    relationshipType: "DESCRIBES",
                    relatedSpdxElement: packageID
                )
            ] + files.map {
                SPDXRelationship(
                    spdxElementId: packageID,
                    relationshipType: "CONTAINS",
                    relatedSpdxElement: $0.SPDXID
                )
            }
        )
    }
}

public struct HomebrewFormulaRequest: Equatable, Sendable {
    public let manifest: TrustedReleaseManifest
    public let artifactURL: String

    public init(manifest: TrustedReleaseManifest, artifactURL: String) {
        self.manifest = manifest
        self.artifactURL = artifactURL
    }

    public func validate() throws {
        try manifest.validate()
        guard let components = URLComponents(string: artifactURL),
              components.scheme == "https",
              components.host == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            throw DistributionError.invalidArguments("Homebrew artifact URL must be immutable HTTPS GitHub release storage.")
        }
        let expectedPath = "/hostwright/hostwright/releases/download/\(manifest.releaseTag)/\(manifest.archive.fileName)"
        guard components.percentEncodedPath == expectedPath else {
            throw DistributionError.invalidArguments("Homebrew artifact URL must bind the exact release tag and archive name.")
        }
    }
}

public enum HomebrewFormulaRenderer {
    public static func render(_ request: HomebrewFormulaRequest) throws -> String {
        try request.validate()
        let version = request.manifest.packageVersion
        return """
        class Hostwright < Formula
          desc "Mac-native desired-state control plane for Apple container workloads"
          homepage "https://hostwright.dev"
          url "\(request.artifactURL)"
          version "\(version)"
          sha256 "\(request.manifest.archive.sha256)"
          license "Apache-2.0"

          depends_on arch: :arm64
          depends_on macos: :tahoe

          def install
            executables = %w[hostwright hostwright-control hostwright-containerization-helper hostwright-dist hostwrightd]
            executables.each do |name|
              system "/usr/bin/codesign", "--verify", "--strict", "--verbose=2", "bin/#{name}"
            end
            bin.install executables.map { |name| "bin/#{name}" }
            doc.install "share/doc/hostwright/LICENSE", "share/doc/hostwright/README.md"
            pkgshare.install "share/hostwright/examples/hostwright.yaml"
            pkgshare.install "share/hostwright/containerization"
          end

          service do
            run [opt_bin/"hostwrightd", "--foreground", "--config", etc/"hostwright/hostwright.yaml"]
            keep_alive crashed: true
            working_dir var
            log_path var/"log/hostwrightd.log"
            error_log_path var/"log/hostwrightd.error.log"
          end

          def caveats
            <<~EOS
              Hostwright is installed without starting its service. To use hostwrightd,
              place a reviewed v2 manifest at:
                #{etc}/hostwright/hostwright.yaml
              An example is installed at:
                #{pkgshare}/hostwright.yaml
            EOS
          end

          test do
            assert_equal version.to_s, shell_output("#{bin}/hostwright --version").strip
            assert_equal version.to_s, shell_output("#{bin}/hostwright-control --version").strip
            assert_equal version.to_s, shell_output("#{bin}/hostwright-containerization-helper --version").strip
            assert_equal version.to_s, shell_output("#{bin}/hostwright-dist --version").strip
            assert_equal version.to_s, shell_output("#{bin}/hostwrightd --version").strip
            assert_path_exists pkgshare/"containerization/kernel/\(DistributionContainerizationAssets.kernelFileName)"
            assert_path_exists pkgshare/"containerization/vminit/index.json"
            capabilities = shell_output("#{bin}/hostwright capabilities --json")
            assert_match '"schemaVersion":1', capabilities
            assert_match '"productVersion":"\(version)"', capabilities
          end
        end
        """ + "\n"
    }
}
