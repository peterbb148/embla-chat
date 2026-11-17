import CryptoKit
import Foundation

import EmblaCore

/// Portable credentials are deliberately readable in the user-selected iCloud folder.
struct SharedCredential: Codable, Equatable, Sendable {
    var endpoint: URL
    var bearerToken: String
}

/// Derived discovery schemas stay local; only explicit configuration and grants transfer.
struct SharedServer: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var endpoint: URL
    var enabledTools: [String]
    var enableToolsOnFirstDiscovery: Bool
    var credential: SharedCredential?

    init(_ server: MCPServer, token: String?) {
        id = server.id
        name = server.name
        endpoint = server.endpoint
        enabledTools = server.enabledTools.sorted()
        enableToolsOnFirstDiscovery = server.enableToolsOnFirstDiscovery
        credential = token.map { SharedCredential(endpoint: server.endpoint, bearerToken: $0) }
    }

    var connectionFingerprint: String {
        get throws {
            var connection = self
            connection.name = ""
            connection.enabledTools = []
            connection.enableToolsOnFirstDiscovery = false
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(connection))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    var registration: MCPServer {
        MCPServer(
            id: id, name: name, endpoint: endpoint, enabledTools: Set(enabledTools),
            enableToolsOnFirstDiscovery: enableToolsOnFirstDiscovery)
    }
}

struct SharedSettings: Codable, Equatable, Sendable {
    var formatVersion = 1
    var servers: [SharedServer] = []
    var selectedSkill: String?

    func validate() throws {
        guard formatVersion == 1, servers.count <= 64,
            Set(servers.map(\.id)).count == servers.count,
            selectedSkill.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true
        else { throw SharedSettingsError.invalid }
        for server in servers {
            try server.registration.validate()
            guard server.enabledTools.count <= 64,
                Set(server.enabledTools).count == server.enabledTools.count,
                server.enabledTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 })
            else { throw SharedSettingsError.invalid }
            if let credential = server.credential {
                guard credential.endpoint == server.endpoint, !credential.bearerToken.isEmpty,
                    credential.bearerToken.utf8.allSatisfy({ (33...126).contains($0) })
                else { throw SharedSettingsError.credential }
            }
        }
    }

    func encoded() throws -> Data {
        try validate()
        var normalized = self
        for index in normalized.servers.indices {
            normalized.servers[index].enabledTools.sort()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let bytes = try encoder.encode(normalized)
        guard bytes.count <= 1_048_576 else { throw SharedSettingsError.invalid }
        return bytes
    }

    var fingerprint: String {
        get throws {
            SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
        }
    }
}

struct SharedSettingsRead: Equatable, Sendable {
    var current: SharedSettings?
    var conflicts: [SharedSettings] = []
}

/// Synchronous coordinated transactions also make checking-and-writing one indivisible operation.
protocol SharedSettingsStoring: Sendable {
    var identity: String { get }
    func read() throws -> SharedSettingsRead
    func write(_ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool) throws
}

struct SharedSettingsFile: SharedSettingsStoring {
    let bookmark: Data
    var identity: String { SHA256.hash(data: bookmark).map { String(format: "%02x", $0) }.joined() }

    func read() throws -> SharedSettingsRead {
        try withAccess { try CoordinatedSettingsFile.read($0) }
    }

    func write(_ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool) throws {
        try withAccess {
            try CoordinatedSettingsFile.write(
                value, at: $0, replacing: replacing,
                resolve: resolve)
        }
    }

    private func withAccess<T>(_ action: (URL) throws -> T) throws -> T {
        var stale = false
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkResolutionOptions = []
        #endif
        let root = try URL(
            resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
            bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else {
            throw CloudConversationError.permission
        }
        defer { root.stopAccessingSecurityScopedResource() }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
        guard root.lastPathComponent == "EmblaChat", values.isDirectory == true,
            values.isUbiquitousItem == true
        else { throw CloudConversationError.notICloudFolder }
        let folder = root.appendingPathComponent("Settings", isDirectory: true)
        try CoordinatedSettingsFile.rejectLink(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try action(folder.appendingPathComponent("settings.json"))
    }
}

enum CoordinatedSettingsFile {
    static func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SharedSettingsError.invalid
        }
    }

    static func read(_ file: URL) throws -> SharedSettingsRead {
        var result: Result<SharedSettingsRead, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) {
            url in result = Result { try contents(url).0 }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        return try result.get()
    }

    static func write(
        _ value: SharedSettings, at file: URL, replacing: SharedSettingsRead,
        resolve: Bool = false
    ) throws {
        let bytes = try value.encoded()
        var result: Result<Void, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &failure)
        {
            url in
            result = Result {
                let (current, versions) = try contents(url)
                guard current == replacing else { throw SharedSettingsError.changed }
                guard resolve || versions.isEmpty else { throw SharedSettingsError.conflict }
                try bytes.write(to: url, options: .atomic)
                if resolve { for version in versions { version.isResolved = true } }
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        try result.get()
    }

    private static func decode(_ file: URL) throws -> SharedSettings {
        try rejectLink(file)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw SharedSettingsError.invalid }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_048_576 else { throw SharedSettingsError.invalid }
        let settings = try JSONDecoder().decode(SharedSettings.self, from: data)
        try settings.validate()
        return settings
    }

    private static func contents(_ file: URL) throws -> (SharedSettingsRead, [NSFileVersion]) {
        let current: SharedSettings
        do { current = try decode(file) } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return (SharedSettingsRead(), [])
            }
            throw error
        }
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        let conflicts = try versions.map { try decode($0.url) }
        let values = try file.resourceValues(forKeys: [
            .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingErrorKey,
        ])
        if let error = values.ubiquitousItemUploadingError { throw error }
        if let error = values.ubiquitousItemDownloadingError { throw error }
        return (SharedSettingsRead(current: current, conflicts: conflicts), versions)
    }
}

/// Local receipts contain only hashes, never copied cloud credentials.
private struct SettingsMigrationReceipt: Codable {
    var source: String
    var localFingerprint: String
}

/// Writes go directly to the selected shared document; no hidden offline write queue exists.
actor SharedSettingsSession {
    let storage: any SharedSettingsStoring
    nonisolated let receipt: URL
    private(set) var current: SharedSettings?
    private(set) var choices: [SharedSettings] = []
    private var read = SharedSettingsRead()
    private var local = SharedSettings()

    init(storage: any SharedSettingsStoring, receipt: URL) {
        self.storage = storage
        self.receipt = receipt
    }

    func refresh(local: SharedSettings) throws -> SharedSettings {
        try Task.checkCancellation()
        self.local = local
        let remote = try storage.read()
        let saved: SettingsMigrationReceipt?
        if FileManager.default.fileExists(atPath: receipt.path) {
            saved = try JSONDecoder().decode(
                SettingsMigrationReceipt.self,
                from: Data(contentsOf: receipt))
        } else {
            saved = nil
        }
        let knownSource = saved?.source == storage.identity
        let migrated = try knownSource && saved?.localFingerprint == local.fingerprint
        let changedLocal = knownSource && !migrated
        read = remote
        choices = []
        if !remote.conflicts.isEmpty
            || (remote.current == nil && (current != nil || knownSource))
            || (!migrated && remote.current != nil && remote.current != local
                && (changedLocal || !local.servers.isEmpty || local.selectedSkill != nil))
        {
            let retained = migrated ? (current ?? local) : local
            choices = [retained] + [remote.current ?? SharedSettings()] + remote.conflicts
            throw SharedSettingsError.conflict
        }
        let value = remote.current ?? local
        if remote.current == nil { try storage.write(value, replacing: remote, resolve: false) }
        try saveReceipt(local)
        read = SharedSettingsRead(current: value)
        current = value
        return value
    }

    func commit(_ value: SharedSettings, replacing expected: SharedSettings) throws {
        try Task.checkCancellation()
        guard current == expected else { throw SharedSettingsError.changed }
        guard choices.isEmpty else { throw SharedSettingsError.conflict }
        try storage.write(value, replacing: read, resolve: false)
        current = value
        read = SharedSettingsRead(current: value)
    }

    func resolve(_ index: Int, expected: SharedSettings) throws -> SharedSettings {
        try Task.checkCancellation()
        guard choices.indices.contains(index), choices[index] == expected else {
            throw SharedSettingsError.changed
        }
        let value = choices[index]
        try storage.write(value, replacing: read, resolve: true)
        try saveReceipt(local)
        read = SharedSettingsRead(current: value)
        current = value
        choices = []
        return value
    }

    private func saveReceipt(_ local: SharedSettings) throws {
        let saved = try SettingsMigrationReceipt(
            source: storage.identity,
            localFingerprint: local.fingerprint)
        try JSONEncoder().encode(saved).write(to: receipt, options: .atomic)
    }
}

enum SharedSettingsError: Error, LocalizedError {
    case invalid, credential, changed, conflict, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid:
            return "Invalid Settings/settings.json. Check its version, servers and skill."
        case .credential: return "Invalid MCP credential or credential endpoint does not match."
        case .changed: return "Shared settings changed. Reload settings before saving again."
        case .conflict: return "Settings differ or were deleted. Choose which settings to keep."
        case .unavailable:
            return "Shared settings are unavailable. Check iCloud consent and reload."
        }
    }
}
