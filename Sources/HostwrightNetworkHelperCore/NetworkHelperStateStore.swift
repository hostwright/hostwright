import CryptoKit
import Darwin
import Foundation

private let networkHelperPermissionBits = mode_t(
    S_ISUID | S_ISGID | S_ISTXT | S_IRWXU | S_IRWXG | S_IRWXO
)

private struct NetworkHelperFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

private struct NetworkHelperPersistedMetadata: Codable, Equatable {
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let corefileSHA256: String

    init(identity: NetworkHelperDNSIdentity, corefileSHA256: String) {
        schemaVersion = 1
        self.identity = identity
        self.corefileSHA256 = corefileSHA256
    }
}

private struct NetworkHelperCurrentPointer: Codable, Equatable {
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let corefileSHA256: String

    init(metadata: NetworkHelperPersistedMetadata) {
        schemaVersion = 1
        identity = metadata.identity
        corefileSHA256 = metadata.corefileSHA256
    }
}

private struct NetworkHelperRemovalMarker: Codable, Equatable {
    let schemaVersion: Int
    let projectUUID: String
    let dnsUUID: String

    init(identity: NetworkHelperDNSIdentity) {
        schemaVersion = 1
        projectUUID = identity.projectUUID
        dnsUUID = identity.dnsUUID
    }
}

final class NetworkHelperStateStore: @unchecked Sendable {
    let rootURL: URL
    private let owner: uid_t
    private let fileManager: FileManager
    private let lock = NSLock()
    private let rootIdentity: NetworkHelperFileIdentity

    init(
        rootURL: URL,
        owner: uid_t = geteuid(),
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.owner = owner
        self.fileManager = fileManager
        try Self.preparePrivateDirectory(
            rootURL,
            owner: owner,
            requireSafeParent: true
        )
        var metadata = stat()
        guard lstat(rootURL.path, &metadata) == 0 else {
            throw NetworkHelperError.unsafePath
        }
        rootIdentity = NetworkHelperFileIdentity(metadata)
        try recover()
    }

    func apply(
        identity: NetworkHelperDNSIdentity,
        corefile: String,
        predecessorFencingToken: String? = nil
    ) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        guard !corefile.isEmpty,
              !corefile.utf8.contains(0),
              corefile.lengthOfBytes(using: .utf8)
                <= NetworkHelperProtocolV1.maximumCorefileBytes else {
            throw NetworkHelperError.invalidCorefile
        }

        try recoverLocked()
        let dnsRoot = try ensureDNSRoot(for: identity)
        let current = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        switch current.disposition {
        case .active:
            let digest = Self.sha256(Data(corefile.utf8))
            guard current.corefileSHA256 == digest else {
                throw NetworkHelperError.conflict
            }
            return current
        case .conflict:
            guard let active = current.identity,
                  active.projectUUID == identity.projectUUID,
                  active.dnsUUID == identity.dnsUUID,
                  identity.generation > active.generation,
                  predecessorFencingToken ==
                    active.fencingToken else {
                throw NetworkHelperError.conflict
            }
        case .quarantined:
            throw NetworkHelperError.quarantined
        case .absent:
            guard predecessorFencingToken == nil else {
                throw NetworkHelperError.conflict
            }
        }

        try validateGenerationDirectoryContents(
            at: dnsRoot,
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID
        )

        let metadata = NetworkHelperPersistedMetadata(
            identity: identity,
            corefileSHA256: Self.sha256(Data(corefile.utf8))
        )
        try stageGeneration(
            metadata: metadata,
            corefile: Data(corefile.utf8),
            dnsRoot: dnsRoot
        )
        try replaceCurrentPointer(
            NetworkHelperCurrentPointer(metadata: metadata),
            dnsRoot: dnsRoot
        )
        try refreshActiveCorefile(
            pointer: NetworkHelperCurrentPointer(metadata: metadata),
            dnsRoot: dnsRoot
        )
        try removeSupersededGenerations(
            dnsRoot: dnsRoot,
            keeping: identity.generation,
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID
        )
        return NetworkHelperStatus(
            disposition: .active,
            identity: identity,
            corefileSHA256: metadata.corefileSHA256,
            reason: nil
        )
    }

    func status(identity: NetworkHelperDNSIdentity) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        do {
            try recoverLocked()
        } catch NetworkHelperError.quarantined {
            return quarantinedStatus("persisted DNS metadata is invalid")
        }
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return NetworkHelperStatus(
                disposition: .absent,
                identity: nil,
                corefileSHA256: nil,
                reason: nil
            )
        }
        return try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
    }

    func remove(identity: NetworkHelperDNSIdentity) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return NetworkHelperStatus(
                disposition: .absent,
                identity: nil,
                corefileSHA256: nil,
                reason: nil
            )
        }

        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active else {
            if status.disposition == .quarantined {
                throw NetworkHelperError.quarantined
            }
            throw NetworkHelperError.conflict
        }
        try validateGenerationDirectoryContents(
            at: dnsRoot,
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID
        )

        let markerURL = dnsRoot.appendingPathComponent(
            "removal.json",
            isDirectory: false
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(
                NetworkHelperRemovalMarker(identity: identity)
            ),
            to: markerURL
        )

        let projectRoot = dnsRoot.deletingLastPathComponent()
        let removingURL = projectRoot.appendingPathComponent(
            ".removing-\(identity.dnsUUID)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard rename(dnsRoot.path, removingURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        try finishRemoval(at: removingURL)
        try removeDirectoryIfEmpty(projectRoot)
        return NetworkHelperStatus(
            disposition: .absent,
            identity: nil,
            corefileSHA256: nil,
            reason: nil
        )
    }

    func recover() throws {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked()
    }

    private func recoverLocked() throws {
        try Self.validatePrivateDirectory(rootURL, owner: owner)
        var rootMetadata = stat()
        guard lstat(rootURL.path, &rootMetadata) == 0,
              NetworkHelperFileIdentity(rootMetadata) == rootIdentity else {
            throw NetworkHelperError.unsafePath
        }
        for projectURL in try safeDirectoryContents(at: rootURL) {
            guard Self.isCanonicalUUID(projectURL.lastPathComponent) else {
                throw NetworkHelperError.quarantined
            }
            try Self.validatePrivateDirectory(projectURL, owner: owner)
            for entry in try safeDirectoryContents(at: projectURL) {
                if entry.lastPathComponent.hasPrefix(".removing-") {
                    let markerURL = entry.appendingPathComponent(
                        "removal.json",
                        isDirectory: false
                    )
                    if fileManager.fileExists(atPath: markerURL.path) {
                        try finishRemoval(at: entry)
                    } else {
                        try Self.validatePrivateDirectory(entry, owner: owner)
                        guard try safeDirectoryContents(at: entry).isEmpty,
                              rmdir(entry.path) == 0 else {
                            throw NetworkHelperError.quarantined
                        }
                    }
                    continue
                }
                guard Self.isCanonicalUUID(entry.lastPathComponent) else {
                    throw NetworkHelperError.quarantined
                }
                let markerURL = entry.appendingPathComponent(
                    "removal.json",
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: markerURL.path) {
                    let marker: NetworkHelperRemovalMarker = try loadCanonical(
                        NetworkHelperRemovalMarker.self,
                        from: markerURL
                    )
                    guard marker.schemaVersion == 1,
                          marker.projectUUID == projectURL.lastPathComponent,
                          marker.dnsUUID == entry.lastPathComponent else {
                        throw NetworkHelperError.quarantined
                    }
                    let removingURL = projectURL.appendingPathComponent(
                        ".removing-\(marker.dnsUUID)-\(UUID().uuidString.lowercased())",
                        isDirectory: true
                    )
                    guard rename(entry.path, removingURL.path) == 0 else {
                        throw NetworkHelperError.ioFailure
                    }
                    try finishRemoval(at: removingURL)
                    continue
                }
                try recoverDNSRoot(
                    entry,
                    projectUUID: projectURL.lastPathComponent,
                    dnsUUID: entry.lastPathComponent
                )
            }
            try removeDirectoryIfEmpty(projectURL)
        }
    }

    private func recoverDNSRoot(
        _ dnsRoot: URL,
        projectUUID: String,
        dnsUUID: String
    ) throws {
        try Self.validatePrivateDirectory(dnsRoot, owner: owner)
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: generations.path) else {
            throw NetworkHelperError.quarantined
        }
        try Self.validatePrivateDirectory(generations, owner: owner)

        for entry in try safeDirectoryContents(at: generations)
            where entry.lastPathComponent.hasPrefix(".pending-") {
            let suffix = String(entry.lastPathComponent.dropFirst(".pending-".count))
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            let metadataURL = entry.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
            if fileManager.fileExists(atPath: metadataURL.path) {
                let metadata = try loadMetadataIfIncomplete(from: entry)
                guard metadata.identity.projectUUID == projectUUID,
                      metadata.identity.dnsUUID == dnsUUID else {
                    throw NetworkHelperError.quarantined
                }
            }
            try removeGenerationDirectory(entry)
        }

        for entry in try safeDirectoryContents(at: dnsRoot)
            where entry.lastPathComponent.hasPrefix(".current-") {
            let suffix = String(entry.lastPathComponent.dropFirst(".current-".count))
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }

        let pointerURL = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            let active = dnsRoot.appendingPathComponent(
                "active",
                isDirectory: true
            )
            try cleanActiveTemporaryFiles(at: active)
            if try safeDirectoryContents(at: generations).isEmpty,
               try safeDirectoryContents(at: active).isEmpty {
                return
            }
            throw NetworkHelperError.quarantined
        }
        let pointer: NetworkHelperCurrentPointer = try loadCanonical(
            NetworkHelperCurrentPointer.self,
            from: pointerURL
        )
        guard pointer.schemaVersion == 1,
              pointer.identity.projectUUID == projectUUID,
              pointer.identity.dnsUUID == dnsUUID else {
            throw NetworkHelperError.quarantined
        }
        _ = try pointer.identity.validated()
        try validateGeneration(
            at: generationURL(
                dnsRoot: dnsRoot,
                generation: pointer.identity.generation
            ),
            expected: pointer
        )
        try refreshActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
        try removeSupersededGenerations(
            dnsRoot: dnsRoot,
            keeping: pointer.identity.generation,
            projectUUID: projectUUID,
            dnsUUID: dnsUUID
        )
    }

    private func currentStatusLocked(
        requestedIdentity: NetworkHelperDNSIdentity,
        dnsRoot: URL
    ) throws -> NetworkHelperStatus {
        do {
            try Self.validatePrivateDirectory(dnsRoot, owner: owner)
            let pointerURL = dnsRoot.appendingPathComponent(
                "current.json",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: pointerURL.path) else {
                let generations = dnsRoot.appendingPathComponent(
                    "generations",
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: generations.path),
                   try safeDirectoryContents(at: generations).isEmpty {
                    return NetworkHelperStatus(
                        disposition: .absent,
                        identity: nil,
                        corefileSHA256: nil,
                        reason: nil
                    )
                }
                return quarantinedStatus("current generation is missing")
            }
            let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                NetworkHelperCurrentPointer.self,
                from: pointerURL
            )
            guard pointer.schemaVersion == 1 else {
                return quarantinedStatus("metadata schema is unsupported")
            }
            _ = try pointer.identity.validated()
            try validateGeneration(
                at: generationURL(
                    dnsRoot: dnsRoot,
                    generation: pointer.identity.generation
                ),
                expected: pointer
            )
            try validateActiveCorefile(
                pointer: pointer,
                dnsRoot: dnsRoot
            )
            return NetworkHelperStatus(
                disposition: pointer.identity == requestedIdentity
                    ? .active
                    : .conflict,
                identity: pointer.identity,
                corefileSHA256: pointer.corefileSHA256,
                reason: pointer.identity == requestedIdentity
                    ? nil
                    : "active DNS generation has different ownership"
            )
        } catch let error as NetworkHelperError {
            if error == .unsafePath {
                throw error
            }
            return quarantinedStatus("persisted DNS metadata is invalid")
        } catch {
            return quarantinedStatus("persisted DNS metadata is invalid")
        }
    }

    private func ensureDNSRoot(
        for identity: NetworkHelperDNSIdentity
    ) throws -> URL {
        let projectRoot = rootURL.appendingPathComponent(
            identity.projectUUID,
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            projectRoot,
            owner: owner,
            requireSafeParent: false
        )
        let dnsRoot = projectRoot.appendingPathComponent(
            identity.dnsUUID,
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            dnsRoot,
            owner: owner,
            requireSafeParent: false
        )
        try Self.preparePrivateDirectory(
            dnsRoot.appendingPathComponent("generations", isDirectory: true),
            owner: owner,
            requireSafeParent: false
        )
        try Self.preparePrivateDirectory(
            dnsRoot.appendingPathComponent("active", isDirectory: true),
            owner: owner,
            requireSafeParent: false
        )
        return dnsRoot
    }

    private func dnsRootURL(for identity: NetworkHelperDNSIdentity) -> URL {
        rootURL
            .appendingPathComponent(identity.projectUUID, isDirectory: true)
            .appendingPathComponent(identity.dnsUUID, isDirectory: true)
    }

    private func stageGeneration(
        metadata: NetworkHelperPersistedMetadata,
        corefile: Data,
        dnsRoot: URL
    ) throws {
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        let destination = generationURL(
            dnsRoot: dnsRoot,
            generation: metadata.identity.generation
        )
        if fileManager.fileExists(atPath: destination.path) {
            let pointer = NetworkHelperCurrentPointer(metadata: metadata)
            try validateGeneration(at: destination, expected: pointer)
            return
        }

        let staging = generations.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard mkdir(staging.path, S_IRWXU) == 0,
              chmod(staging.path, S_IRWXU) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        var shouldRemove = true
        defer {
            if shouldRemove {
                try? removeGenerationDirectory(staging)
            }
        }
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(metadata),
            to: staging.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        try writeExclusive(
            corefile,
            to: staging.appendingPathComponent("Corefile", isDirectory: false)
        )
        try synchronizeDirectory(staging)
        guard rename(staging.path, destination.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        shouldRemove = false
        try synchronizeDirectory(generations)
    }

    private func replaceCurrentPointer(
        _ pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let destination = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        let temporary = dnsRoot.appendingPathComponent(
            ".current-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(pointer),
            to: temporary
        )
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
    }

    private func refreshActiveCorefile(
        pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            active,
            owner: owner,
            requireSafeParent: false
        )
        try cleanActiveTemporaryFiles(at: active)

        let source = generationURL(
            dnsRoot: dnsRoot,
            generation: pointer.identity.generation
        ).appendingPathComponent("Corefile", isDirectory: false)
        let sourceData = try loadRegularFile(source)
        guard Self.sha256(sourceData) == pointer.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }

        let destination = active.appendingPathComponent(
            "Corefile",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: destination.path) {
            let currentData = try loadRegularFile(destination)
            if Self.sha256(currentData) == pointer.corefileSHA256 {
                return
            }
        }
        let temporary = active.appendingPathComponent(
            ".Corefile-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(sourceData, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(active)
        try validateActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
    }

    private func validateActiveCorefile(
        pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.validatePrivateDirectory(active, owner: owner)
        let entries = try safeDirectoryContents(at: active)
        guard Set(entries.map(\.lastPathComponent)) == Set(["Corefile"])
        else {
            throw NetworkHelperError.quarantined
        }
        let data = try loadRegularFile(
            active.appendingPathComponent("Corefile", isDirectory: false)
        )
        guard Self.sha256(data) == pointer.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }
    }

    private func cleanActiveTemporaryFiles(at active: URL) throws {
        try Self.validatePrivateDirectory(active, owner: owner)
        for entry in try safeDirectoryContents(at: active)
            where entry.lastPathComponent.hasPrefix(".Corefile-") {
            let suffix = String(
                entry.lastPathComponent.dropFirst(".Corefile-".count)
            )
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }
    }

    private func validateGeneration(
        at generationURL: URL,
        expected: NetworkHelperCurrentPointer
    ) throws {
        let metadata = try loadMetadata(from: generationURL)
        guard metadata.schemaVersion == 1,
              metadata.identity == expected.identity,
              metadata.corefileSHA256 == expected.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }
        let corefileURL = generationURL.appendingPathComponent(
            "Corefile",
            isDirectory: false
        )
        let corefile = try loadRegularFile(corefileURL)
        guard Self.sha256(corefile) == metadata.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }
    }

    private func loadMetadata(
        from generationURL: URL
    ) throws -> NetworkHelperPersistedMetadata {
        try Self.validatePrivateDirectory(generationURL, owner: owner)
        let entries = try safeDirectoryContents(at: generationURL)
        guard Set(entries.map(\.lastPathComponent))
            == Set(["metadata.json", "Corefile"]) else {
            throw NetworkHelperError.quarantined
        }
        let metadata: NetworkHelperPersistedMetadata = try loadCanonical(
            NetworkHelperPersistedMetadata.self,
            from: generationURL.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        _ = try metadata.identity.validated()
        return metadata
    }

    private func loadMetadataIfIncomplete(
        from generationURL: URL
    ) throws -> NetworkHelperPersistedMetadata {
        try Self.validatePrivateDirectory(generationURL, owner: owner)
        let entries = try safeDirectoryContents(at: generationURL)
        guard Set(entries.map(\.lastPathComponent))
            .isSubset(of: Set(["metadata.json", "Corefile"])) else {
            throw NetworkHelperError.quarantined
        }
        let metadata: NetworkHelperPersistedMetadata = try loadCanonical(
            NetworkHelperPersistedMetadata.self,
            from: generationURL.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        _ = try metadata.identity.validated()
        return metadata
    }

    private func validateGenerationDirectoryContents(
        at dnsRoot: URL,
        projectUUID: String,
        dnsUUID: String
    ) throws {
        let allowedRootEntries = Set([
            "active",
            "current.json",
            "generations"
        ])
        let rootEntries = try safeDirectoryContents(at: dnsRoot)
        guard Set(rootEntries.map(\.lastPathComponent))
            .isSubset(of: allowedRootEntries) else {
            throw NetworkHelperError.quarantined
        }
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.validatePrivateDirectory(active, owner: owner)
        try Self.validatePrivateDirectory(generations, owner: owner)
        for generation in try safeDirectoryContents(at: generations) {
            guard let generationValue = Int(generation.lastPathComponent),
                  generationValue > 0 else {
                throw NetworkHelperError.quarantined
            }
            let metadata = try loadMetadata(from: generation)
            guard metadata.identity.projectUUID == projectUUID,
                  metadata.identity.dnsUUID == dnsUUID,
                  metadata.identity.generation == generationValue else {
                throw NetworkHelperError.quarantined
            }
            let pointer = NetworkHelperCurrentPointer(metadata: metadata)
            try validateGeneration(at: generation, expected: pointer)
        }
        let pointerURL = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: pointerURL.path) {
            let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                NetworkHelperCurrentPointer.self,
                from: pointerURL
            )
            try validateActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
        } else {
            guard try safeDirectoryContents(at: active).isEmpty else {
                throw NetworkHelperError.quarantined
            }
        }
    }

    private func removeSupersededGenerations(
        dnsRoot: URL,
        keeping generation: Int,
        projectUUID: String,
        dnsUUID: String
    ) throws {
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        for entry in try safeDirectoryContents(at: generations) {
            guard let value = Int(entry.lastPathComponent), value > 0 else {
                throw NetworkHelperError.quarantined
            }
            guard value != generation else { continue }
            let metadata = try loadMetadata(from: entry)
            guard metadata.identity.projectUUID == projectUUID,
                  metadata.identity.dnsUUID == dnsUUID,
                  metadata.identity.generation == value else {
                throw NetworkHelperError.quarantined
            }
            try removeGenerationDirectory(entry)
        }
    }

    private func finishRemoval(at removalURL: URL) throws {
        try Self.validatePrivateDirectory(removalURL, owner: owner)
        let markerURL = removalURL.appendingPathComponent(
            "removal.json",
            isDirectory: false
        )
        let marker: NetworkHelperRemovalMarker = try loadCanonical(
            NetworkHelperRemovalMarker.self,
            from: markerURL
        )
        guard marker.schemaVersion == 1,
              Self.isCanonicalUUID(marker.projectUUID),
              Self.isCanonicalUUID(marker.dnsUUID),
              removalURL.deletingLastPathComponent().lastPathComponent
                == marker.projectUUID else {
            throw NetworkHelperError.quarantined
        }

        let generations = removalURL.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: generations.path) {
            try Self.validatePrivateDirectory(generations, owner: owner)
            for generation in try safeDirectoryContents(at: generations) {
                let metadata = try loadMetadata(from: generation)
                guard metadata.identity.projectUUID == marker.projectUUID,
                      metadata.identity.dnsUUID == marker.dnsUUID else {
                    throw NetworkHelperError.quarantined
                }
                try removeGenerationDirectory(generation)
            }
            guard rmdir(generations.path) == 0 else {
                throw NetworkHelperError.ioFailure
            }
        }
        let active = removalURL.appendingPathComponent(
            "active",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: active.path) {
            try Self.validatePrivateDirectory(active, owner: owner)
            let activeEntries = try safeDirectoryContents(at: active)
            guard Set(activeEntries.map(\.lastPathComponent))
                .isSubset(of: Set(["Corefile"])) else {
                throw NetworkHelperError.quarantined
            }
            for entry in activeEntries {
                try removeRegularFileIfPresent(entry)
            }
            guard rmdir(active.path) == 0 else {
                throw NetworkHelperError.ioFailure
            }
        }
        try removeRegularFileIfPresent(
            removalURL.appendingPathComponent(
                "current.json",
                isDirectory: false
            )
        )
        try removeRegularFileIfPresent(markerURL)
        guard rmdir(removalURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeGenerationDirectory(_ directoryURL: URL) throws {
        try Self.validatePrivateDirectory(directoryURL, owner: owner)
        let entries = try safeDirectoryContents(at: directoryURL)
        let allowed = Set(["metadata.json", "Corefile"])
        guard Set(entries.map(\.lastPathComponent)).isSubset(of: allowed) else {
            throw NetworkHelperError.quarantined
        }
        for entry in entries {
            try removeRegularFileIfPresent(entry)
        }
        guard rmdir(directoryURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeRegularFileIfPresent(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw NetworkHelperError.ioFailure
            }
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & networkHelperPermissionBits
                == S_IRUSR | S_IWUSR else {
            throw NetworkHelperError.unsafePath
        }
        guard unlink(url.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func loadCanonical<Value: Codable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try NetworkHelperCanonicalJSON.decode(
            type,
            from: loadRegularFile(url)
        )
    }

    private func loadRegularFile(_ url: URL) throws -> Data {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NetworkHelperError.unsafePath
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & networkHelperPermissionBits
                == S_IRUSR | S_IWUSR,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.unsafePath
        }
        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(max(Int(metadata.st_size), 1), 64 * 1_024)
        )
        while result.count < Int(metadata.st_size) {
            let count = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, Int(metadata.st_size) - result.count)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NetworkHelperError.ioFailure
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NetworkHelperError.ioFailure
        }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded {
                _ = unlink(url.path)
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw NetworkHelperError.ioFailure
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        succeeded = true
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NetworkHelperError.ioFailure
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func safeDirectoryContents(at url: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard try safeDirectoryContents(at: url).isEmpty else { return }
        if rmdir(url.path) != 0, errno != ENOENT {
            throw NetworkHelperError.ioFailure
        }
    }

    private func generationURL(
        dnsRoot: URL,
        generation: Int
    ) -> URL {
        dnsRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(String(generation), isDirectory: true)
    }

    private func quarantinedStatus(_ reason: String) -> NetworkHelperStatus {
        NetworkHelperStatus(
            disposition: .quarantined,
            identity: nil,
            corefileSHA256: nil,
            reason: reason
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        owner: uid_t,
        requireSafeParent: Bool
    ) throws {
        guard isLexicallyNormalizedAbsolutePath(url.path) else {
            throw NetworkHelperError.unsafePath
        }
        if requireSafeParent {
            try validatePrivateDirectory(
                url.deletingLastPathComponent(),
                owner: owner
            )
        }

        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT,
                  mkdir(url.path, S_IRWXU) == 0,
                  chmod(url.path, S_IRWXU) == 0 else {
                throw NetworkHelperError.unsafePath
            }
        }
        try validatePrivateDirectory(url, owner: owner)
    }

    private static func validatePrivateDirectory(
        _ url: URL,
        owner: uid_t
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & networkHelperPermissionBits == S_IRWXU else {
            throw NetworkHelperError.unsafePath
        }
    }

    private static func isLexicallyNormalizedAbsolutePath(
        _ path: String
    ) -> Bool {
        guard path.first == "/",
              path == "/" || !path.hasSuffix("/") else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else {
            return false
        }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
