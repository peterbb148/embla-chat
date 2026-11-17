import Darwin
import Foundation

import EmblaCore

/// Shares the global source contract with Actions; neither chat sync nor reset modifies skills.
actor SkillStore {
    let localRoot: URL

    private let network: NetworkAccess
    private let cache: SyncedResourceCache

    init(localRoot: URL, network: NetworkAccess = .shared, cacheRoot: URL? = nil) {
        self.localRoot = localRoot
        self.network = network
        cache = SyncedResourceCache(
            root: cacheRoot
                ?? localRoot.deletingLastPathComponent()
                .appendingPathComponent(".synced-skills"))
    }

    struct Listing: Codable {
        var documents: [String: Data] = [:]
        var errors: [String: String] = [:]

        /// Keep a previous successful document only for an unreadable provider result.
        /// Online callers still receive the error; malformed or deleted content is invalidated.
        mutating func record(_ result: Result<Data, Error>, name: String, previous: Listing)
            -> SkillEntry
        {
            let data: Data
            do {
                data = try result.get()
            } catch {
                let failure = error as NSError
                let deleted =
                    (failure.domain == NSCocoaErrorDomain
                        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
                if !(error is SkillFailure) && !deleted, let retained = previous.documents[name] {
                    documents[name] = retained
                } else {
                    errors[name] = error.localizedDescription
                }
                return SkillEntry(id: name, document: nil, error: error.localizedDescription)
            }
            do {
                let document = try SkillDocument.decode(data, directoryName: name)
                documents[name] = data
                return SkillEntry(id: name, document: document, error: nil)
            } catch {
                // These bytes were read successfully: every decoding failure invalidates them.
                errors[name] = error.localizedDescription
                return SkillEntry(id: name, document: nil, error: error.localizedDescription)
            }
        }

        func entries() throws -> [SkillEntry] {
            guard documents.count + errors.count <= 256,
                Set(documents.keys).isDisjoint(with: errors.keys)
            else { throw SyncedResourceFailure.invalid }
            let valid = try documents.map { name, data in
                SkillEntry(
                    id: name, document: try SkillDocument.decode(data, directoryName: name),
                    error: nil)
            }
            return (valid + errors.map { SkillEntry(id: $0.key, document: nil, error: $0.value) })
                .sorted { $0.id < $1.id }
        }
    }

    nonisolated func entries(_ source: QuickActionSource) async throws -> [SkillEntry] {
        try Task.checkCancellation()
        if case .cachedCloud(let bookmark) = source {
            return try cachedListing(bookmark).entries()
        }
        return try await providerEntries(source)
    }

    private nonisolated func cachedListing(_ bookmark: Data) throws -> Listing {
        try JSONDecoder().decode(Listing.self, from: cache.read("listing", bookmark: bookmark))
    }

    private func providerEntries(_ source: QuickActionSource) throws -> [SkillEntry] {
        let previous: Listing
        if case .cloud(let bookmark) = source {
            do { previous = try cachedListing(bookmark) } catch SyncedResourceFailure.notCached {
                previous = Listing()
            }
        } else {
            previous = Listing()
        }
        var listing = Listing()
        let entries = try withRoot(source) { root, descriptor in
            let folders = try Self.names(in: descriptor).sorted()
            return try folders.map { name in
                try Task.checkCancellation()
                let read = Result {
                    try readFile(
                        "SKILL.md", folder: name, root: root, descriptor: descriptor,
                        source: source)
                }
                if case .failure(let error) = read, error is CancellationError {
                    throw CancellationError()
                }
                return listing.record(read, name: name, previous: previous)
            }
        }
        if case .cloud(let bookmark) = source {
            try network.check()
            try cache.write(JSONEncoder().encode(listing), name: "listing", bookmark: bookmark)
        }
        return entries
    }

    nonisolated func resource(_ path: String, skill: SkillDocument, source: QuickActionSource)
        async throws -> String
    {
        try Task.checkCancellation()
        if case .cachedCloud(let bookmark) = source {
            let listing = try cachedListing(bookmark).entries()
            guard listing.first(where: { $0.id == skill.name })?.document == skill else {
                throw SkillFailure.changed
            }
            return try cachedResource(path, skill: skill, bookmark: bookmark)
        }
        return try await providerResource(path, skill: skill, source: source)
    }

    /// A prepared turn pins validated instructions; later reloads cannot revoke that snapshot.
    nonisolated func cachedResource(_ path: String, skill: SkillDocument, bookmark: Data) throws
        -> String
    {
        try Task.checkCancellation()
        guard path.split(separator: "/").first != "scripts",
            path.components(separatedBy: "/").allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") })
        else { throw SkillFailure.unsupportedResource }
        let key = "resource:" + skill.name + ":" + skill.fingerprint + ":" + path
        let data = try cache.read(key, bookmark: bookmark)
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw SkillFailure.unsupportedResource
        }
        return text
    }

    private func providerResource(_ path: String, skill: SkillDocument, source: QuickActionSource)
        throws -> String
    {
        guard path.split(separator: "/").first != "scripts" else {
            throw SkillFailure.unsupportedResource
        }
        let key = "resource:" + skill.name + ":" + skill.fingerprint + ":" + path
        let text = try withRoot(source) { root, descriptor in
            let current = try SkillDocument.decode(
                readFile(
                    "SKILL.md", folder: skill.name, root: root, descriptor: descriptor,
                    source: source),
                directoryName: skill.name)
            guard current == skill else { throw SkillFailure.changed }
            let data = try readFile(
                path, folder: skill.name, root: root, descriptor: descriptor, source: source)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SkillFailure.unsupportedResource
            }
            return text
        }
        if case .cloud(let bookmark) = source {
            try network.check()
            try cache.write(Data(text.utf8), name: key, bookmark: bookmark)
        }
        return text
    }

    private func readFile(
        _ path: String, folder: String, root: URL, descriptor: Int32, source: QuickActionSource
    ) throws
        -> Data
    {
        try Task.checkCancellation()
        let parts = [folder] + path.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }) else {
            throw SkillFailure.unsupportedResource
        }
        if case .cloud = source { try network.check() }
        let file = parts.reduce(root) { $0.appendingPathComponent($1) }
        var result: Result<Data, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) { _ in
            // Coordination materializes cloud files. The opened root remains authoritative:
            // never reopen an absolute URL after a path component may have been replaced.
            result = Result {
                if case .cloud = source { try network.check() }
                return try Self.readRelativeFile(parts, descriptor: descriptor)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        return try result.get()
    }

    /// Directory descriptors pin the selected tree; O_NOFOLLOW makes each traversal atomic.
    static func openDirectory(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SkillFailure.unsupportedResource }
        return descriptor
    }

    /// Enumerate the pinned directory, rather than resolving its possibly replaced URL.
    private static func names(in descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw SkillFailure.unsupportedResource }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw SkillFailure.unsupportedResource
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw SkillFailure.unsupportedResource }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            guard !name.hasPrefix(".") else { continue }
            names.append(name)
            guard names.count <= 256 else {
                throw SkillFailure.invalid("The Skills folder exceeds the 256-entry limit.")
            }
        }
        return names
    }

    /// Distinguish confirmed path changes from transient provider I/O failures.
    static func readFailure(_ code: Int32) -> Error {
        if [ENOENT, ENOTDIR, ELOOP].contains(code) { return SkillFailure.unsupportedResource }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Read only regular files through the pinned directory, never following a symbolic link.
    static func readRelativeFile(_ parts: [String], descriptor: Int32) throws -> Data {
        guard !parts.isEmpty,
            parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") })
        else { throw SkillFailure.unsupportedResource }
        var directory = dup(descriptor)
        guard directory >= 0 else { throw readFailure(errno) }
        defer { close(directory) }
        for component in parts.dropLast() {
            try Task.checkCancellation()
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw readFailure(errno) }
            close(directory)
            directory = next
        }
        let file = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw readFailure(errno) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw readFailure(errno) }
        guard info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= 65_536
        else { throw SkillFailure.unsupportedResource }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw readFailure(errno) }
            if count == 0 { break }
            guard data.count + count <= 65_536 else { throw SkillFailure.unsupportedResource }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func withRoot<T>(
        _ source: QuickActionSource, _ action: (URL, Int32) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        switch source {
        case .device:
            try FileManager.default.createDirectory(
                at: localRoot, withIntermediateDirectories: true)
            let descriptor = try Self.openDirectory(localRoot.path)
            defer { close(descriptor) }
            var root = localRoot
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            return try action(root, descriptor)
        case .cloud(let bookmark):
            try network.check()
            var stale = false
            #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
                let options: URL.BookmarkResolutionOptions = []
            #endif
            let root = try URL(
                resolvingBookmarkData: bookmark, options: options,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, root.startAccessingSecurityScopedResource() else {
                throw CloudConversationError.permission
            }
            defer { root.stopAccessingSecurityScopedResource() }
            let descriptor = try Self.openDirectory(root.path)
            defer { close(descriptor) }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
            guard root.lastPathComponent == "EmblaChat", values.isDirectory == true,
                values.isUbiquitousItem == true
            else { throw CloudConversationError.notICloudFolder }
            let skills = openat(
                descriptor, "Skills", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard skills >= 0 else { throw SkillFailure.unsupportedResource }
            defer { close(skills) }
            try network.check()
            return try action(root.appendingPathComponent("Skills", isDirectory: true), skills)
        case .cachedCloud:
            throw SyncedResourceFailure.notCached
        }
    }
}
