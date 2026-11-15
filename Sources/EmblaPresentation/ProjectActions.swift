import Foundation

extension LocalInferenceModel {
    public var canEditProjects: Bool {
        chatRestored && storageError == nil && !busy && !resetting && !cloud.resolving
    }

    private func editableProjectLibrary() throws -> ConversationLibrary {
        guard canEditProjects else { throw ProjectError.busy }
        return ConversationLibrary(chats: savedChats.map(\.snapshot), projects: projects)
    }

    public func createProject(name: String) async throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        var library = try editableProjectLibrary()
        let project = ChatProject(name: name)
        library.projects.append(project)
        try await commitProjectLibrary(library)
        return project.id
    }

    public func renameProject(_ id: UUID, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        var library = try editableProjectLibrary()
        guard let index = library.projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.missingProject
        }
        library.projects[index].name = name
        try await commitProjectLibrary(library)
    }

    public func moveChat(_ id: UUID, to projectID: UUID?) async throws {
        var library = try editableProjectLibrary()
        guard projectID == nil || library.projects.contains(where: { $0.id == projectID }) else {
            throw ProjectError.missingProject
        }
        guard let index = library.chats.firstIndex(where: { $0.conversationID == id }) else {
            throw ProjectError.missingSource
        }
        library.chats[index].projectID = projectID
        library.chats[index].revision = UUID()
        try await commitProjectLibrary(library)
    }

    public func saveProjectMemory(
        projectID: UUID, text: String, sourceChatID: UUID, sourceMessageID: UUID
    ) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectError.emptyMemory
        }
        var library = try editableProjectLibrary()
        guard let index = library.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectError.missingProject
        }
        guard let source = library.chats.first(where: { $0.conversationID == sourceChatID }),
            source.projectID == projectID,
            source.messages.contains(where: {
                $0.id == sourceMessageID && $0.state != .streaming && !$0.text.isEmpty
            })
        else { throw ProjectError.missingSource }
        library.projects[index].memory.append(
            ProjectMemoryEntry(
                text: text, sourceConversationID: sourceChatID, sourceMessageID: sourceMessageID))
        try await commitProjectLibrary(library)
    }

    public func editProjectMemory(projectID: UUID, entryID: UUID, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectError.emptyMemory
        }
        var library = try editableProjectLibrary()
        guard let project = library.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectError.missingProject
        }
        guard let entry = library.projects[project].memory.firstIndex(where: { $0.id == entryID })
        else {
            throw ProjectError.missingSource
        }
        library.projects[project].memory[entry].text = text
        try await commitProjectLibrary(library)
    }

    public func removeProjectMemory(projectID: UUID, entryID: UUID? = nil) async throws {
        var library = try editableProjectLibrary()
        guard let index = library.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectError.missingProject
        }
        if let entryID {
            library.projects[index].memory.removeAll { $0.id == entryID }
        } else {
            library.projects[index].memory.removeAll()
        }
        try await commitProjectLibrary(library)
    }
}
