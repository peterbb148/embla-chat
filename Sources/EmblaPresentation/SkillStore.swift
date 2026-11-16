import Foundation

/// Shares the global source contract with Actions; neither chat sync nor reset modifies skills.
actor SkillStore {
    let localRoot: URL

    init(localRoot: URL) { self.localRoot = localRoot }

    func entries(_ source: QuickActionSource) throws -> [SkillEntry] {
        try withRoot(source) { root in
            let folders = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard folders.count <= 256 else {
                throw SkillFailure.invalid("The Skills folder exceeds the 256-entry limit.")
            }
            return try folders.map { folder in
                try Task.checkCancellation()
                do {
                    let values = try folder.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey,
                    ])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw SkillFailure.invalid(
                            "Each skill must be a real folder, not a symbolic link.")
                    }
                    let document = try SkillDocument.decode(
                        readFile("SKILL.md", root: folder), directoryName: folder.lastPathComponent)
                    return SkillEntry(id: folder.lastPathComponent, document: document, error: nil)
                } catch is CancellationError { throw CancellationError() } catch {
                    return SkillEntry(
                        id: folder.lastPathComponent, document: nil,
                        error: error.localizedDescription)
                }
            }
        }
    }

    func resource(_ path: String, skill: SkillDocument, source: QuickActionSource) throws -> String
    {
        try withRoot(source) { root in
            let folder = root.appendingPathComponent(skill.name, isDirectory: true)
            let current = try SkillDocument.decode(
                readFile("SKILL.md", root: folder),
                directoryName: skill.name)
            guard current == skill else { throw SkillFailure.changed }
            guard path.split(separator: "/").first != "scripts" else {
                throw SkillFailure.unsupportedResource
            }
            let data = try readFile(path, root: folder)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SkillFailure.unsupportedResource
            }
            return text
        }
    }

    private func readFile(_ path: String, root: URL) throws -> Data {
        try Task.checkCancellation()
        let parts = path.components(separatedBy: "/")
        guard !parts.isEmpty,
            parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
            })
        else { throw SkillFailure.unsupportedResource }
        var file = root
        // Refuse symlinks at every path component, including the selected skill root.
        for part in [""] + parts {
            if !part.isEmpty { file.appendPathComponent(part) }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SkillFailure.unsupportedResource }
        }
        var result: Result<Data, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) { file in
            result = Result {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536
                else {
                    throw SkillFailure.unsupportedResource
                }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count <= 65_536 else { throw SkillFailure.unsupportedResource }
                return data
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudConversationError.coordination }
        return try result.get()
    }

    /// Apply before either source is enumerated, including the Skills folder under a cloud root.
    static func validateRoot(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SkillFailure.invalid(
                "The Skills storage root must be a real folder, not a symbolic link.")
        }
    }

    private func withRoot<T>(_ source: QuickActionSource, _ action: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        switch source {
        case .device:
            try FileManager.default.createDirectory(
                at: localRoot, withIntermediateDirectories: true)
            try Self.validateRoot(localRoot)
            var root = localRoot
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            return try action(root)
        case .cloud(let bookmark):
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
            try Self.validateRoot(root)
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
            guard root.lastPathComponent == "EmblaChat", values.isDirectory == true,
                values.isUbiquitousItem == true
            else { throw CloudConversationError.notICloudFolder }
            let skills = root.appendingPathComponent("Skills", isDirectory: true)
            try Self.validateRoot(skills)
            return try action(skills)
        }
    }
}
