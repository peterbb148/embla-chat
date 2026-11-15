import Foundation

/// Source selection follows the global cloud preference, never a failure-driven substitute.
enum QuickActionSource: Sendable, Equatable {
    case device
    case cloud(Data)
}

protocol QuickActionsStoring: Sendable {
    func read(_ source: QuickActionSource) async throws -> QuickActionConfiguration
    func createStarter(_ source: QuickActionSource) async throws
}

/// Coordinates user-editable files; no chat, model or skill contents are read here.
actor QuickActionStore: QuickActionsStoring {
    let localRoot: URL
    let stateRoot: URL

    init(localRoot: URL, stateRoot: URL) {
        self.localRoot = localRoot
        self.stateRoot = stateRoot
    }

    func read(_ source: QuickActionSource) throws -> QuickActionConfiguration {
        try Task.checkCancellation()
        switch source {
        case .device:
            try initializeDeviceOnce()
            return try CoordinatedActionFile.read(
                at: localRoot.appendingPathComponent("actions.json"))
        case .cloud(let bookmark):
            return try withCloudAccess(bookmark) { root in
                try CoordinatedActionFile.read(
                    at: root.appendingPathComponent("Actions/actions.json"))
            }
        }
    }

    func createStarter(_ source: QuickActionSource) throws {
        try Task.checkCancellation()
        switch source {
        case .device:
            try prepareLocalDirectory(localRoot)
            try CoordinatedActionFile.create(at: localRoot.appendingPathComponent("actions.json"))
        case .cloud(let bookmark):
            try withCloudAccess(bookmark) { root in
                let actions = root.appendingPathComponent("Actions", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: actions, withIntermediateDirectories: true)
                try CoordinatedActionFile.create(at: actions.appendingPathComponent("actions.json"))
            }
        }
    }

    private func initializeDeviceOnce() throws {
        let marker = stateRoot.appendingPathComponent("initialized-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepareLocalDirectory(localRoot)
        let file = localRoot.appendingPathComponent("actions.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try CoordinatedActionFile.create(at: file)
        }
        try prepareLocalDirectory(stateRoot)
        try Data([1]).write(to: marker, options: .atomic)
    }

    private func prepareLocalDirectory(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func withCloudAccess<T>(_ bookmark: Data, _ action: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
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
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
        guard root.lastPathComponent == "EmblaChat", values.isDirectory == true,
            values.isUbiquitousItem == true
        else { throw CloudConversationError.notICloudFolder }
        try Task.checkCancellation()
        return try action(root)
    }
}

/// Local coordinated-file tests exercise this code without claiming iCloud authentication/transfer.
enum CoordinatedActionFile {
    static func read(at file: URL) throws -> QuickActionConfiguration {
        var result: Result<QuickActionConfiguration, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) { url in
            result = Result {
                try Task.checkCancellation()
                let data: Data
                do { data = try Data(contentsOf: url) } catch {
                    let error = error as NSError
                    if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
                    {
                        throw QuickActionError.missingConfiguration
                    }
                    throw error
                }
                return try QuickActionConfiguration.decode(data)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        return try result.get()
    }

    /// Never overwrite an existing user configuration, including a malformed one.
    static func create(at file: URL) throws {
        let data = try QuickActionConfiguration.starter.encoded()
        var result: Result<Void, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &failure) { url in
            result = Result {
                try Task.checkCancellation()
                do { try data.write(to: url, options: .withoutOverwriting) } catch {
                    let error = error as NSError
                    if error.domain == NSCocoaErrorDomain
                        && error.code == NSFileWriteFileExistsError
                    {
                        throw QuickActionError.existingConfiguration
                    }
                    throw error
                }
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        try result.get()
    }
}
