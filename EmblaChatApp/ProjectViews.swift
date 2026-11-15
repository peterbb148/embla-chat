import SwiftUI

import EmblaPresentation

/// Project navigation and manually retained notes; no automatic memory extraction.
struct ProjectDetailView: View {
    let model: LocalInferenceModel
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editor: Editor?
    @State private var confirmClear = false
    @State private var failure: String?

    private enum Editor: Identifiable {
        case rename(String)
        case memory(ProjectMemoryEntry)
        var id: String {
            switch self {
            case .rename: return "rename"
            case .memory(let entry): return entry.id.uuidString
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let project = model.projects.first(where: { $0.id == projectID }) {
                    Section("Chats") {
                        Button("New chat in project", systemImage: "square.and.pencil") {
                            model.newChat(in: projectID)
                            dismiss()
                        }
                        .disabled(!model.canNavigateChats)
                        ForEach(model.savedChats.filter { $0.snapshot.projectID == projectID }) {
                            chat in
                            Button(chat.title) {
                                model.selectChat(chat.id)
                                dismiss()
                            }
                            .disabled(!model.canNavigateChats)
                        }
                    }
                    Section("Project memory") {
                        Text(
                            "Only notes you explicitly save are shared with other chats in this project. "
                                + "Edit a note when a fact changes; nothing updates automatically."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        if project.memory.isEmpty {
                            Text("No saved notes.").foregroundStyle(.secondary)
                        }
                        ForEach(project.memory) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(entry.text).textSelection(.enabled)
                                Button("Edit note") { editor = .memory(entry) }
                                    .disabled(!model.canEditProjects)
                                Button("Open source: \(sourceTitle(entry))") {
                                    model.selectChat(entry.sourceConversationID)
                                    dismiss()
                                }
                                .font(.caption)
                                .disabled(!model.canNavigateChats)
                            }.padding(.vertical, 6)
                        }
                        if !project.memory.isEmpty {
                            Button("Clear project memory", role: .destructive) {
                                confirmClear = true
                            }
                            .disabled(!model.canEditProjects)
                        }
                        Text(
                            "The global iCloud setting covers chats and project memory after consent. "
                                + "Off keeps them on this device."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Rename project") { editor = .rename(project.name) }
                            .disabled(!model.canEditProjects)
                    }
                } else {
                    Text("This project is no longer available.").foregroundStyle(.red)
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle(model.projects.first(where: { $0.id == projectID })?.name ?? "Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editor) { destination in
                switch destination {
                case .rename(let name):
                    ProjectNameEditor(model: model, projectID: projectID, name: name)
                case .memory(let entry):
                    ProjectMemoryEditor(model: model, projectID: projectID, entry: entry)
                }
            }
            .alert("Clear project memory?", isPresented: $confirmClear) {
                Button("Clear notes", role: .destructive) {
                    Task {
                        do { try await model.removeProjectMemory(projectID: projectID) } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes saved notes from this project. Source chats are kept.")
            }
        }
    }

    private func sourceTitle(_ entry: ProjectMemoryEntry) -> String {
        model.savedChats.first(where: { $0.id == entry.sourceConversationID })?.title
            ?? "Source unavailable"
    }
}

struct ProjectNameEditor: View {
    let model: LocalInferenceModel
    let projectID: UUID?
    @State var name: String
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project name", text: $name).accessibilityIdentifier("project-name")
                    .disabled(saving)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(projectID == nil ? "New project" : "Rename project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            do {
                                if let projectID {
                                    try await model.renameProject(projectID, name: name)
                                } else {
                                    _ = try await model.createProject(name: name)
                                }
                                dismiss()
                            } catch { failure = error.localizedDescription }
                            saving = false
                        }
                    }
                    .disabled(
                        saving || !model.canEditProjects
                            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct MoveChatView: View {
    let model: LocalInferenceModel
    let chatID: UUID
    @State private var failure: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Button("No project") { move(to: nil) }.disabled(!model.canEditProjects)
                ForEach(model.projects) { project in
                    Button(project.name) { move(to: project.id) }.disabled(!model.canEditProjects)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Move chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func move(to projectID: UUID?) {
        saving = true
        Task {
            do {
                try await model.moveChat(chatID, to: projectID)
                dismiss()
            } catch { failure = error.localizedDescription }
            saving = false
        }
    }
}

/// The editor lets the user retain only useful text; the original message link remains intact.
struct ProjectMemoryEditor: View {
    let model: LocalInferenceModel
    let projectID: UUID
    private let entryID: UUID?
    private let sourceChatID: UUID
    private let sourceMessageID: UUID
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(model: LocalInferenceModel, projectID: UUID, sourceChatID: UUID, message: ChatMessage) {
        self.model = model
        self.projectID = projectID
        entryID = nil
        self.sourceChatID = sourceChatID
        sourceMessageID = message.id
        _text = State(initialValue: message.text)
    }

    init(model: LocalInferenceModel, projectID: UUID, entry: ProjectMemoryEntry) {
        self.model = model
        self.projectID = projectID
        entryID = entry.id
        sourceChatID = entry.sourceConversationID
        sourceMessageID = entry.sourceMessageID
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Keep useful text") {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier(
                        "memory-text")
                        .disabled(saving)
                    Text(
                        "You can edit this note. It will be included in other chats in this project "
                            + "and counts toward their context limit."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Text(
                        "Source: \(sourceTitle)"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle(entryID == nil ? "Save to project memory" : "Edit project memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(
                            saving || !model.canEditProjects
                                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var sourceTitle: String {
        model.savedChats.first(where: { $0.id == sourceChatID })?.title ?? "Unavailable"
    }

    private func save() {
        saving = true
        Task {
            do {
                if let entryID {
                    try await model.editProjectMemory(
                        projectID: projectID, entryID: entryID, text: text)
                } else {
                    try await model.saveProjectMemory(
                        projectID: projectID, text: text,
                        sourceChatID: sourceChatID, sourceMessageID: sourceMessageID)
                }
                dismiss()
            } catch { failure = error.localizedDescription }
            saving = false
        }
    }
}
