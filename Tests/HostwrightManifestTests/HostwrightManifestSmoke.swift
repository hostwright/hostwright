import HostwrightManifest

let hostwrightManifestSmoke: Void = {
    let valid = """
    project: api-local

    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
        health:
          command: ["curl", "-f", "http://localhost:8080/health"]
          interval: 10s
        restart:
          policy: on-failure

    """

    do {
        let manifest = try ManifestValidator.validated(valid)
        precondition(manifest.project == "api-local")
        precondition(manifest.services.count == 1)
        precondition(manifest.services[0].ports == ["8080:8080"])
    } catch {
        preconditionFailure("Expected valid manifest, got \(error).")
    }

    do {
        _ = try ManifestValidator.validated("""
        services:
          api:
            image: ghcr.io/example/api:latest
        """)
        preconditionFailure("Expected missing project validation failure.")
    } catch let error as ManifestParseError {
        precondition(error.issues.contains { $0.message.contains("project") })
    } catch {
        preconditionFailure("Unexpected error: \(error).")
    }

    do {
        _ = try ManifestValidator.validated("""
        project: api-local
        services:
          api:
            ports:
              - "8080:8080"
        """)
        preconditionFailure("Expected missing image validation failure.")
    } catch let error as ManifestParseError {
        precondition(error.issues.contains { $0.message.contains("image") })
    } catch {
        preconditionFailure("Unexpected error: \(error).")
    }

    do {
        _ = try ManifestValidator.validated("""
        project: api-local
        services:
          api:
            image: ghcr.io/example/api:latest
            ports:
              - "not-a-port"
        """)
        preconditionFailure("Expected malformed port validation failure.")
    } catch let error as ManifestParseError {
        precondition(error.issues.contains { $0.message.contains("host:container") })
    } catch {
        preconditionFailure("Unexpected error: \(error).")
    }

    do {
        _ = try ManifestParser.parse("""
        apiVersion: hostwright.dev/v1alpha1
        kind: Stack
        """)
        preconditionFailure("Expected unsupported YAML shape failure.")
    } catch let error as ManifestParseError {
        precondition(error.issues.contains { $0.code.rawValue == "HW-MANIFEST-003" })
    } catch {
        preconditionFailure("Unexpected error: \(error).")
    }
}()

