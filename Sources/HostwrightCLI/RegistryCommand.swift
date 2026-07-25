import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets

struct RegistryCommandRunner {
    let options: RegistryCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        switch options.action {
        case .login(let server, let username):
            return try login(server: server, username: username)
        case .logout(let server):
            return try logout(server: server)
        case .status(let server, let repository, let actions):
            return try status(
                server: server,
                repository: repository,
                actions: actions
            )
        case .referrers(let action):
            return try RegistryReferrerCommandRunner(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: options.output,
                environment: environment
            ).run()
        case .trust(let action):
            return try RegistryTrustCommandRunner(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: options.output,
                environment: environment
            ).run()
        case .sbom(let action):
            return try RegistrySBOMCommandRunner(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: options.output,
                environment: environment
            ).run()
        case .vulnerability(let action):
            return try RegistryVulnerabilityCommandRunner(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: options.output,
                environment: environment
            ).run()
        case .provenance(let action):
            return try RegistryProvenanceCommandRunner(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: options.output,
                environment: environment
            ).run()
        }
    }

    private func login(server: String, username: String) throws -> CLIRunResult {
        let endpoint = try mappedEndpoint(server)
        let rawSecret: Data
        do {
            rawSecret = try environment.readSecretInput()
        } catch let error as SecretStoreError {
            throw secretDiagnostic(error)
        }
        guard let secret = String(data: rawSecret, encoding: .utf8) else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry credentials must contain valid UTF-8."
            )
        }
        let credential: RegistryCredential
        do {
            credential = try RegistryCredential(
                username: username,
                secret: secret
            )
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry credentials are invalid."
            )
        }

        let result = try authenticate(
            endpoint: endpoint,
            scopes: .empty,
            credential: credential,
            credentialKind: .basic
        )
        let reference = try credentialReference(endpoint)
        let manager = environment.secretManager()
        let action: SecretCLIAction
        do {
            _ = try manager.check(reference: reference)
            action = .update(reference)
        } catch let error as SecretStoreError {
            if case .notFound = error {
                action = .create(reference)
            } else {
                throw secretDiagnostic(error)
            }
        }

        var mutationEnvironment = environment
        let encoded: Data
        do {
            encoded = try credential.encodedForStorage()
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry credentials could not be encoded safely."
            )
        }
        mutationEnvironment.readSecretInput = { encoded }
        _ = try SecretCommandRunner(
            options: SecretCLIOptions(
                action: action,
                stateDatabasePath: options.stateDatabasePath,
                output: .json
            ),
            environment: mutationEnvironment
        ).run()
        return render(
            operation: "login",
            endpoint: endpoint,
            credentialSource: "hostwright-keychain",
            result: result
        )
    }

    private func logout(server: String) throws -> CLIRunResult {
        let endpoint = try mappedEndpoint(server)
        let reference = try credentialReference(endpoint)
        _ = try SecretCommandRunner(
            options: SecretCLIOptions(
                action: .delete(reference),
                stateDatabasePath: options.stateDatabasePath,
                output: .json
            ),
            environment: environment
        ).run()
        return renderLogout(endpoint)
    }

    private func status(
        server: String,
        repository: String?,
        actions: [String]
    ) throws -> CLIRunResult {
        let endpoint = try mappedEndpoint(server)
        let scopes: RegistryAccessScopeSet
        do {
            if let repository {
                let parsedActions = try Set(actions.map { action in
                    guard let value = RegistryScopeAction(rawValue: action) else {
                        throw RegistryContractError.invalidScope(
                            "Registry action is unsupported."
                        )
                    }
                    return value
                })
                scopes = try RegistryAccessScopeSet([
                    RegistryAccessScope(
                        resourceType: .repository,
                        name: repository,
                        actions: parsedActions
                    )
                ])
            } else {
                scopes = .empty
            }
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry scope is invalid."
            )
        }

        let resolved = try resolveCredential(endpoint)
        let result = try authenticate(
            endpoint: endpoint,
            scopes: scopes,
            credential: resolved.credential,
            credentialKind: resolved.kind
        )
        return render(
            operation: "status",
            endpoint: endpoint,
            credentialSource: resolved.source,
            result: result
        )
    }

    func resolveCredential(
        _ endpoint: RegistryEndpoint
    ) throws -> (
        credential: RegistryCredential?,
        kind: RegistryCredentialAuthorizationKind,
        source: String
    ) {
        let manager = environment.secretManager()
        let reference = try credentialReference(endpoint)
        do {
            let raw = try manager.readString(reference: reference)
            let credential = try RegistryCredential.decodeFromStorage(
                Data(raw.utf8)
            )
            return (credential, .basic, "hostwright-keychain")
        } catch let error as SecretStoreError {
            if case .notFound = error {
                // Continue through compatible Docker and OCI stores.
            } else if case .backendUnavailable = error {
                // Hostwright's Keychain may be unavailable in a non-interactive
                // environment while a guarded external credential store exists.
            } else {
                throw secretDiagnostic(error)
            }
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The stored Hostwright registry credential is invalid."
            )
        }

        let documents: [DockerCredentialConfigurationDocument]
        do {
            documents = try environment.registryCredentialDocuments()
        } catch let error as RegistryCredentialLookupError {
            throw lookupDiagnostic(error)
        } catch {
            throw HostwrightDiagnostic(
                code: .registryCredentialUnavailable,
                message: "Registry credential configuration could not be read safely."
            )
        }
        guard !documents.isEmpty else {
            return (nil, .basic, "none")
        }

        do {
            let found = try DockerRegistryCredentialLookup(
                helperResolver: environment.registryCredentialHelperResolver()
            ).lookup(
                registryValue: endpoint.canonicalURLString,
                configurationDocuments: documents
            )
            return (
                found.credential,
                found.kind == .identityToken ? .identityToken : .basic,
                found.source.rawValue
            )
        } catch let error as RegistryCredentialLookupError {
            if case .credentialUnavailable = error {
                return (nil, .basic, "none")
            }
            throw lookupDiagnostic(error)
        }
    }

    private func authenticate(
        endpoint: RegistryEndpoint,
        scopes: RegistryAccessScopeSet,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind
    ) throws -> RegistryAuthenticationResult {
        do {
            return try RegistryAuthenticationClient(
                transport: environment.registryTransport(),
                now: environment.registryDate
            ).authenticate(
                endpoint: endpoint,
                requestedScopes: scopes,
                credential: credential,
                credentialKind: credentialKind
            )
        } catch let error as RegistryAuthenticationError {
            throw authenticationDiagnostic(error)
        }
    }

    private func credentialReference(
        _ endpoint: RegistryEndpoint
    ) throws -> HostwrightSecretReference {
        do {
            return try HostwrightSecretReference(
                service: RegistryEndpoint.credentialKeychainService,
                account: endpoint.credentialKeychainAccount
            )
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry credential identity is invalid."
            )
        }
    }

    private func mappedEndpoint(_ server: String) throws -> RegistryEndpoint {
        do {
            return try RegistryEndpoint(server)
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Registry endpoint must be an exact HTTPS host or host:port."
            )
        }
    }

    private func authenticationDiagnostic(
        _ error: RegistryAuthenticationError
    ) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error {
        case .invalidRequest, .invalidResponse:
            code = .registryInvalid
        case .credentialUnavailable:
            code = .registryCredentialUnavailable
        case .authenticationDenied:
            code = .registryAuthenticationDenied
        case .scopeDenied:
            code = .registryScopeDenied
        case .transportUnavailable:
            code = .registryTransportUnavailable
        case .cancelled:
            code = .registryCancelled
        }
        return HostwrightDiagnostic(
            code: code,
            message: RuntimeRedactionPolicy.default.redact(error.description)
        )
    }

    private func lookupDiagnostic(
        _ error: RegistryCredentialLookupError
    ) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error {
        case .credentialUnavailable, .helperUnavailable:
            code = .registryCredentialUnavailable
        case .cancelled:
            code = .registryCancelled
        case .helperTimedOut, .helperProcessFailed:
            code = .registryTransportUnavailable
        case .invalidRegistry, .configurationTooLarge, .invalidConfiguration,
             .ambiguousConfiguration, .helperRejected,
             .helperOutputTooLarge, .invalidHelperOutput:
            code = .registryInvalid
        }
        return HostwrightDiagnostic(
            code: code,
            message: RuntimeRedactionPolicy.default.redact(error.description)
        )
    }

    private func secretDiagnostic(
        _ error: SecretStoreError
    ) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error {
        case .invalidReference, .invalidValue, .corruptedMetadata:
            code = .registryInvalid
        case .backendUnavailable, .interactionNotAllowed, .notFound:
            code = .registryCredentialUnavailable
        case .permissionDenied:
            code = .registryAuthenticationDenied
        case .cancelled:
            code = .registryCancelled
        case .duplicate, .unmanaged, .concurrentMutation, .partialEffect:
            code = .registryPartialEffect
        }
        return HostwrightDiagnostic(
            code: code,
            message: RuntimeRedactionPolicy.default.redact(error.description)
        )
    }

    private func render(
        operation: String,
        endpoint: RegistryEndpoint,
        credentialSource: String,
        result: RegistryAuthenticationResult
    ) -> CLIRunResult {
        let expiresAt = result.tokenExpiresAt.map {
            ISO8601DateFormatter().string(from: $0)
        }
        if options.output == .json {
            return CLIRunResult(
                standardOutput: renderJSON([
                    "apiVersion": "hostwright.dev/registry-status/v1",
                    "credentialSource": credentialSource,
                    "distributionAPIVersionVerified":
                        result.distributionAPIVersionVerified,
                    "endpoint": endpoint.canonicalURLString,
                    "grantedScopes": result.grantedScopes.scopes.map(
                        \.canonicalValue
                    ),
                    "operation": operation,
                    "requestedScopes": result.requestedScopes.scopes.map(
                        \.canonicalValue
                    ),
                    "scheme": result.kind.rawValue,
                    "tokenExpiresAt": expiresAt as Any,
                    "tokenRefreshAvailable": result.tokenRefreshAvailable
                ])
            )
        }
        return CLIRunResult(
            standardOutput: """
            Registry \(operation) succeeded
            Endpoint: \(endpoint.canonicalURLString)
            Authentication: \(result.kind.rawValue)
            Credential source: \(credentialSource)
            Requested scopes: \(result.requestedScopes.canonicalValue.isEmpty ? "none" : result.requestedScopes.canonicalValue)
            Granted scopes: \(result.grantedScopes.canonicalValue.isEmpty ? "none" : result.grantedScopes.canonicalValue)
            Token expiry: \(expiresAt ?? "not applicable")
            Token refresh: \(result.tokenRefreshAvailable ? "available" : "not available")

            """
        )
    }

    private func renderLogout(_ endpoint: RegistryEndpoint) -> CLIRunResult {
        if options.output == .json {
            return CLIRunResult(
                standardOutput: renderJSON([
                    "apiVersion": "hostwright.dev/registry-status/v1",
                    "endpoint": endpoint.canonicalURLString,
                    "operation": "logout",
                    "status": "credential-removed"
                ])
            )
        }
        return CLIRunResult(
            standardOutput: """
            Registry logout succeeded
            Endpoint: \(endpoint.canonicalURLString)
            Status: credential removed

            """
        )
    }

    private func renderJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8)! + "\n"
    }
}
