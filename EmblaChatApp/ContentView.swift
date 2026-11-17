import EmblaCore
import EmblaPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Single conversational screen backed by the real local Embla runtime.
struct ContentView: View {
    @State private var model = LocalInferenceModel()
    @State private var sheet: Sheet?
    @State private var confirmation: ChatConfirmation?
    @State private var quickActions = QuickActionsModel()
    @State private var actionError: String?
    @State private var showHistory = false
    @State private var transcriptScroll = TranscriptScrollState()
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private enum Sheet: Identifiable {
        case settings, context, newProject
        case project(UUID), moveChat(UUID), memory(UUID, UUID, ChatMessage)
        var id: String {
            switch self {
            case .settings: return "settings"
            case .context: return "context"
            case .newProject: return "new-project"
            case .project(let id): return "project-" + id.uuidString
            case .moveChat(let id): return "move-" + id.uuidString
            case .memory(_, _, let message): return "memory-" + message.id.uuidString
            }
        }
    }

    private enum ChatConfirmation {
        case replaceDraft(QuickAction)
        var title: String {
            switch self {
            case .replaceDraft: return "Replace draft?"
            }
        }
        var message: String {
            switch self {
            case .replaceDraft:
                return "Replace the current draft with this action's prompt? "
                    + "You can edit it before sending."
            }
        }
    }

    private struct Viewport: Equatable {
        let height: CGFloat
        let contentHeight: CGFloat
        let offset: Double
        let bounds: ClosedRange<Double>
        let nearBottom: Bool

        init(_ geometry: ScrollGeometry) {
            height = geometry.containerSize.height
            contentHeight = geometry.contentSize.height
            offset = geometry.contentOffset.y
            bounds = TranscriptScrollState.scrollBounds(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
            nearBottom =
                TranscriptScrollState.boundedOffset(offset, within: bounds)
                >= bounds.upperBound - 100
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.messages) { message in
                                ChatMessageRow(
                                    message: message,
                                    canSaveMemory: model.activeProjectID != nil, model: model
                                ) {
                                    guard let projectID = model.activeProjectID else { return }
                                    composerFocused = false
                                    sheet = .memory(projectID, model.conversationID, message)
                                }.equatable()
                            }
                            Color.clear.frame(height: 1).id("latest-message")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: Viewport.self) { geometry in
                        Viewport(geometry)
                    } action: { old, new in
                        transcriptScroll.geometryChanged(
                            offset: new.offset, nearBottom: new.nearBottom, bounds: new.bounds)
                        if transcriptScroll.shouldScrollAutomatically
                            && (old.height != new.height || old.contentHeight != new.contentHeight)
                        {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    .onScrollPhaseChange { _, phase, context in
                        let viewport = Viewport(context.geometry)
                        transcriptScroll.phaseChanged(
                            scrolling: phase == .tracking || phase == .interacting
                                || phase == .decelerating,
                            offset: viewport.offset, nearBottom: viewport.nearBottom,
                            bounds: viewport.bounds)
                        if phase == .idle && transcriptScroll.shouldScrollAutomatically {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !transcriptScroll.followingOutput {
                            Button {
                                transcriptScroll.resumeFollowing()
                                reader.scrollTo("latest-message", anchor: .bottom)
                            } label: {
                                Label("Jump to latest", systemImage: "arrow.down")
                                    .font(.callout)
                                    .padding(12)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .padding(12)
                        }
                    }
                    .onChange(of: model.messages.last?.text) { _, _ in
                        if transcriptScroll.shouldScrollAutomatically {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    .onChange(of: model.messages.last?.reasoning) { _, _ in
                        if transcriptScroll.shouldScrollAutomatically {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    .onChange(of: model.messages.count) { oldCount, _ in
                        if model.messages.isEmpty
                            || model.messages.dropFirst(oldCount).contains(
                                where: { $0.role == .user }
                            )
                        {
                            transcriptScroll.resumeFollowing()
                        }
                        if transcriptScroll.shouldScrollAutomatically {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    composer
                }
                .onChange(of: model.conversationID) { _, _ in
                    transcriptScroll = TranscriptScrollState()
                    reader.scrollTo("latest-message", anchor: .bottom)
                }
            }
            .navigationTitle("Embla Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(model.activeProject?.name ?? "Embla")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        composerFocused = false
                        withAnimation(.easeInOut(duration: 0.2)) { showHistory = true }
                    } label: {
                        Label("Chat history", systemImage: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composerFocused = false
                        model.newChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(
                        model.resetting || model.cloud.resolving || (model.busy && !model.running)
                            || (model.messages.isEmpty && model.prompt.isEmpty))
                }
            }
            .sheet(item: $sheet) { destination in
                switch destination {
                case .settings: ModelSettingsView(model: model, actions: quickActions)
                case .context: ContextUsageView(model: model)
                case .newProject: ProjectNameEditor(model: model, projectID: nil, name: "")
                case .project(let id): ProjectDetailView(model: model, projectID: id)
                case .moveChat(let id): MoveChatView(model: model, chatID: id)
                case .memory(let projectID, let chatID, let message):
                    ProjectMemoryEditor(
                        model: model, projectID: projectID,
                        sourceChatID: chatID, message: message)
                }
            }
            .alert(
                confirmation?.title ?? "Chat",
                isPresented: Binding(
                    get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
                )
            ) {
                switch confirmation {
                case .replaceDraft(let action):
                    Button("Replace draft") { selectAction(action, replacing: true) }
                case nil: EmptyView()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmation?.message ?? "")
            }
            .task { model.check() }
            .task(id: QuickActionsModel.sourceKey(for: model.cloud)) {
                quickActions.reload(using: model.cloud)
                model.tools.reloadSkills(using: model.cloud)
            }
            .onChange(of: model.tools.revision) { _, _ in model.toolConfigurationChanged() }
            .onChange(of: model.resetting) { _, resetting in
                composerFocused = !resetting
            }
            .onChange(of: model.conversationID) { _, _ in
                composerFocused = true
            }
            .onChange(of: model.busy) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.becameActive()
                    quickActions.resume(using: model.cloud)
                    model.tools.reloadSkills(using: model.cloud)
                }
                if phase == .inactive {
                    model.becameInactive()
                    quickActions.pause()
                    model.tools.pause()
                }
                if phase == .background {
                    model.enteredBackground()
                    quickActions.pause()
                    model.tools.pause()
                }
                updateIdleTimer()
            }
        }
        .allowsHitTesting(!showHistory)
        .accessibilityHidden(showHistory)
        .overlay(alignment: .leading) {
            if showHistory {
                historySidebar.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    private var historySidebar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showHistory = false }
                } label: {
                    Color.black.opacity(0.25).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close chat history")
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Chats").font(.title2.bold())
                        Spacer()
                        Button {
                            showHistory = false
                            composerFocused = false
                            model.newChat()
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("sidebar-new-chat")
                        .disabled(
                            !model.canNavigateChats
                                || (model.messages.isEmpty && model.prompt.isEmpty))
                    }
                    .padding(.horizontal, 20)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Projects").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("New project", systemImage: "plus") {
                                    showHistory = false
                                    sheet = .newProject
                                }
                                .labelStyle(.iconOnly)
                                .disabled(!model.canEditProjects)
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                            ForEach(model.projects) { project in
                                Button {
                                    showHistory = false
                                    sheet = .project(project.id)
                                } label: {
                                    Label(project.name, systemImage: "folder")
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("All chats").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 12)
                            ForEach(model.savedChats) { chat in
                                Button {
                                    model.selectChat(chat.id)
                                    withAnimation(.easeInOut(duration: 0.2)) { showHistory = false }
                                } label: {
                                    HStack {
                                        Text(chat.title).lineLimit(2).multilineTextAlignment(
                                            .leading)
                                        Spacer(minLength: 8)
                                        if chat.id == model.conversationID {
                                            Image(systemName: "checkmark").accessibilityLabel(
                                                "Current chat")
                                        }
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        chat.id == model.conversationID
                                            ? Color(uiColor: .tertiarySystemFill) : .clear,
                                        in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.canNavigateChats)
                                .contextMenu {
                                    Button("Move to project", systemImage: "folder") {
                                        showHistory = false
                                        sheet = .moveChat(chat.id)
                                    }.disabled(!model.canEditProjects)
                                }
                                .accessibilityLabel(chat.title)
                                .accessibilityValue(
                                    chat.id == model.conversationID ? "Current chat" : "Saved chat"
                                )
                                .accessibilityIdentifier("history-\(chat.id.uuidString)")
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    Divider()
                    Button {
                        showHistory = false
                        sheet = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .padding(.top, 16)
                .frame(width: min(geometry.size.width * 0.86, 360))
                .frame(maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private func selectAction(_ action: QuickAction, replacing: Bool = false) {
        actionError = nil
        do {
            _ = try quickActions.validatedAction(action, using: model.cloud)
            let prompt =
                action.type == .prompt
                ? try quickActions.prompt(for: action, using: model.cloud)
                : action.prompt ?? model.prompt
            if !replacing && !model.prompt.isEmpty && model.prompt != prompt {
                confirmation = .replaceDraft(action)
                return
            }
            if action.type == .skill {
                guard let name = action.skill else { throw SkillFailure.changed }
                try model.tools.selectSkill(name, using: model.cloud)
            }
            model.prompt = prompt
            composerFocused = true
        } catch { actionError = error.localizedDescription }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.messages.isEmpty {
                if quickActions.loadedSourceKey == QuickActionsModel.sourceKey(for: model.cloud) {
                    QuickActionCards(
                        actions: quickActions.actions,
                        enabled: model.chatRestored && !model.resetting && !model.cloud.resolving,
                        select: { selectAction($0) })
                }
                if let error = actionError ?? quickActions.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("quick-action-error")
                }
            }
            if model.readyDirectory == nil {
                Button {
                    composerFocused = false
                    sheet = .settings
                } label: {
                    Label("Set up the model in Settings", systemImage: "arrow.down.circle")
                }
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("model-status")
            }
            if let error = model.storageError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("chat-storage-error")
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("chat-error")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let skill = model.tools.selectedSkill {
                    HStack {
                        Label(skill.name, systemImage: "sparkles").font(.caption)
                        Button("Remove skill", systemImage: "xmark.circle") {
                            model.tools.clearSkill()
                        }
                        .labelStyle(.iconOnly).disabled(model.busy)
                    }.accessibilityIdentifier("composer-skill")
                }
                TextField("Message", text: $model.prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .disabled(model.resetting || !model.chatRestored || model.cloud.resolving)
                    .frame(minHeight: 24, alignment: .topLeading)
                    .accessibilityIdentifier("prompt")
                    .accessibilityLabel("Message")
                HStack {
                    Button {
                        composerFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.secondary)
                    .opacity(composerFocused ? 1 : 0)
                    .disabled(!composerFocused)
                    .accessibilityHidden(!composerFocused)
                    .accessibilityLabel("Hide keyboard")
                    ContextUsageButton(state: model.contextUsage) {
                        composerFocused = false
                        sheet = .context
                    }
                    Spacer()
                    Button {
                        if model.running { model.stop() } else { model.run() }
                    } label: {
                        Image(systemName: model.running ? "stop.fill" : "arrow.up")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                model.running || model.canRun
                                    ? Color(red: 0.20, green: 0.40, blue: 0.92)
                                    : Color(uiColor: .tertiaryLabel), in: Circle())
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .disabled(!model.running && !model.canRun)
                    .accessibilityLabel(model.running ? "Stop" : "Send")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 28)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.04), radius: 10, y: 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.busy && scenePhase == .active
    }
}

/// A stable transcript row; interrupted and limited output remain visibly identified.
private struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    let canSaveMemory: Bool
    let model: LocalInferenceModel
    let saveMemory: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.canSaveMemory == rhs.canSaveMemory
            && lhs.model === rhs.model
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                if message.role == .assistant {
                    if let toolName = message.toolName {
                        Label(toolName, systemImage: "wrench.and.screwdriver")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !message.reasoning.isEmpty {
                        DisclosureGroup("Thoughts") {
                            Text(message.reasoning).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                        .tint(.secondary)
                        .foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    Group {
                        if message.role == .user {
                            Text(message.text)
                        } else {
                            MessageMarkdownView(source: message.text)
                        }
                    }
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .accessibilityIdentifier(message.role == .user ? "user-message" : "answer")
                }
                if !message.text.isEmpty && message.state != .streaming {
                    HStack(spacing: 20) {
                        CopyTextButton(text: message.text, label: "Copy message")
                        if canSaveMemory {
                            ProjectMemoryAction(model: model, save: saveMemory)
                        }
                    }
                }
                switch message.state {
                case .streaming:
                    if message.text.isEmpty { ProgressView().controlSize(.small) }
                case .interrupted: Text("Stopped").font(.caption).foregroundStyle(.secondary)
                case .failed: Text("Response failed").font(.caption).foregroundStyle(.red)
                case .limited:
                    Text("Response limit reached").font(.caption).foregroundStyle(.secondary)
                case .complete: EmptyView()
                }
            }
            .padding(message.role == .user ? 14 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
            }
            if message.role == .assistant { Spacer(minLength: 12) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// Observe edit availability separately so unchanged Markdown rows stay cached.
private struct ProjectMemoryAction: View {
    let model: LocalInferenceModel
    let save: () -> Void

    var body: some View {
        Button("Save to project memory", systemImage: "bookmark", action: save)
            .labelStyle(.iconOnly).font(.caption).tint(.secondary)
            .disabled(!model.canEditProjects)
    }
}

/// Model administration and measurements stay out of the conversation screen.
private struct ModelSettingsView: View {
    @Bindable var model: LocalInferenceModel
    let actions: QuickActionsModel
    @State private var activeAlert: SettingsAlert?
    @State private var chooseCloudFolder = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    Text(model.storageStatus)
                        .accessibilityIdentifier("chat-storage-status")
                    Text("Chats and drafts are saved on this device. iCloud is optional.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.storageError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("Retry chat storage") { model.retryChatStorage() }
                            .disabled(model.busy || model.cloud.resolving)
                    }
                }
                cloudSection
                Section("Actions") {
                    NavigationLink("Manage quick actions") {
                        QuickActionSettingsView(actions: actions, cloud: model.cloud)
                    }
                }
                Section("Skills") {
                    NavigationLink("Manage skills") { SkillsView(model: model) }
                    Text("Manage available skills and choose the active skill.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("MCP Servers") {
                    NavigationLink("MCP Servers") { MCPSettingsView(model: model) }
                }
                Section("Model") {
                    Text("Embla 1").font(.headline)
                    if let manifest = model.manifest {
                        LabeledContent("Download size", value: size(manifest.totalBytes))
                        Text("Source: \(manifest.repository). License: MIT.").font(.caption)
                    }
                    LabeledContent("Local model storage", value: size(model.storedBytes))
                    if model.downloading, let total = model.manifest?.totalBytes {
                        ProgressView(value: Double(model.downloadedBytes), total: Double(total))
                        Text("\(size(model.downloadedBytes)) of \(size(total)) received")
                            .font(.caption)
                        Button("Stop download") { model.stop() }
                    }
                    if model.readyDirectory == nil {
                        Button("Download model") { model.download() }
                            .disabled(model.busy || model.cloud.resolving || model.manifest == nil)
                    }
                    Button("Check model files") { model.check() }
                        .disabled(model.busy || model.cloud.resolving || model.manifest == nil)
                    if model.storedBytes > 0 {
                        Button("Delete model", role: .destructive) { activeAlert = .deleteModel }
                            .disabled(model.busy || model.cloud.resolving)
                    }
                    Text(model.status).accessibilityIdentifier("model-status")
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if model.loadMilliseconds != nil || model.metrics != nil {
                    Section("Last response measurements") {
                        if let time = model.loadMilliseconds {
                            LabeledContent("Verified load", value: milliseconds(time))
                        }
                        if let metrics = model.metrics {
                            LabeledContent("Prompt tokens", value: "\(metrics.promptTokens)")
                            LabeledContent("Generated tokens", value: "\(metrics.completionTokens)")
                            LabeledContent(
                                "Prompt time", value: milliseconds(metrics.promptMilliseconds))
                            LabeledContent(
                                "Decode time", value: milliseconds(metrics.decodeMilliseconds))
                            if metrics.decodeMilliseconds > 0 {
                                LabeledContent(
                                    "Decode tokens/s",
                                    value: String(
                                        format: "%.1f",
                                        Double(max(0, metrics.completionTokens - 1)) * 1_000
                                            / metrics.decodeMilliseconds))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $chooseCloudFolder, allowedContentTypes: [.folder]) {
                result in
                switch result {
                case let .success(folder): Task { await model.cloud.enable(folder: folder) }
                case let .failure(error): model.cloud.folderSelectionFailed(error)
                }
            }
            .alert(
                activeAlert?.title ?? "Settings",
                isPresented: Binding(
                    get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } }
                ), presenting: activeAlert
            ) { selection in
                switch selection {
                case .cloudConsent:
                    Button("Choose folder") { chooseCloudFolder = true }
                case .deleteModel:
                    Button("Delete model", role: .destructive) { model.delete() }
                case let .cloudChoice(choice):
                    Button(choice.label, role: .destructive) {
                        model.cloud.resolve(choiceID: choice.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { selection in
                Text(selection.message)
            }

        }
    }

    private enum SettingsAlert {
        case deleteModel, cloudConsent
        case cloudChoice(CloudChatChoice)

        var title: String {
            switch self {
            case .deleteModel: return "Delete downloaded model files?"
            case .cloudConsent: return "Enable iCloud Drive?"
            case .cloudChoice: return "Use selected chat library?"
            }
        }
        var message: String {
            switch self {
            case .deleteModel:
                return
                    "You will need to download the model again. This does not clear your conversation."
            case .cloudConsent:
                return "All saved chats, their summaries and project memory will be stored in "
                    + "iCloud Drive/EmblaChat/Chats. "
                    + "Select the EmblaChat folder; Skills contains portable skills you can select. "
                    + "Quick actions uses Actions/actions.json in the same folder. "
                    + "Your drafts and model stay on this device. Choose or create EmblaChat in Files."
            case .cloudChoice:
                return "This replaces all chats and project memory in the chosen location. "
                    + "Using an iCloud copy "
                    + "also replaces all this device’s chats, project memory and unsent drafts. "
                    + "Other conflicting copies "
                    + "will be marked resolved."
            }
        }
    }

    private var cloudSection: some View {
        Section("iCloud") {
            Toggle(
                "Store chats and project memory in iCloud Drive",
                isOn: Binding(
                    get: { model.cloud.enabled },
                    set: { enabled in
                        if enabled { activeAlert = .cloudConsent } else { model.cloud.disable() }
                    })
            )
            .disabled(!model.chatRestored || model.busy || model.cloud.resolving)
            .accessibilityIdentifier("icloud-toggle")
            Text("Off by default. This setting applies to all chats and project memory.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.cloud.status).accessibilityIdentifier("icloud-status")
            if let error = model.cloud.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("icloud-error")
            }
            if model.cloud.enabled {
                Button("Sync now") { model.cloud.refresh() }
                    .disabled(model.cloud.syncing || model.busy || model.cloud.requiresScopeConsent)
                Button("Choose iCloud folder…") { activeAlert = .cloudConsent }
                    .disabled(model.cloud.syncing || model.busy)
                Text(
                    "Turning this off stops new app writes and keeps existing cloud files. "
                        + "iCloud Drive may finish transfers already queued."
                ).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.cloud.choices) { choice in
                Button {
                    activeAlert = .cloudChoice(choice)
                } label: {
                    VStack(alignment: .leading) {
                        Text(choice.label)
                        Text(
                            "\(choice.snapshot.chats.count) chats · \(choice.snapshot.chats.reduce(0) { $0 + $1.messages.count }) messages"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.cloud.syncing || model.busy)
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private func milliseconds(_ time: Double) -> String { String(format: "%.0f ms", time) }
}

/// Renders Foundation Markdown blocks using native selectable text and semantic fonts.
private struct MessageMarkdownView: View {
    let document: Result<MessageMarkdown, Error>

    init(source: String) {
        document = Result { try MessageMarkdown(source) }
    }

    var body: some View {
        switch document {
        case .success(let document):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(document.blocks) { block in
                    Group {
                        switch block.style {
                        case .code(let language):
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(language ?? "Code").font(.caption).foregroundStyle(
                                        .secondary)
                                    Spacer()
                                    CopyTextButton(text: block.plainText, label: "Copy code")
                                }
                                ScrollView(.horizontal) {
                                    Text(block.plainText)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .padding(12)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: .rect(cornerRadius: 14))
                        case .heading(let level):
                            Text(block.text)
                                .font(level == 1 ? .title2.bold() : .headline)
                                .accessibilityAddTraits(.isHeader)
                        case .listItem(let marker, let showsMarker):
                            HStack(alignment: .top, spacing: 10) {
                                Text(marker).foregroundStyle(.secondary)
                                    .opacity(showsMarker ? 1 : 0)
                                    .accessibilityHidden(!showsMarker)
                                Text(block.text)
                            }
                        case .quote:
                            HStack(alignment: .top, spacing: 10) {
                                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                                Text(block.text).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        case .prose:
                            Text(block.text)
                        }
                    }
                    .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 12)
                }
            }
            .textSelection(.enabled)
        case .failure(let error):
            Text("Unable to render Markdown: \(error.localizedDescription)")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

/// Copies the exact source text; code copying retains indentation and line breaks.
private struct CopyTextButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .accessibilityValue(copied ? "Copied" : "")
        .onChange(of: text) { _, _ in copied = false }
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
    }
}

/// The context indicator is a button; opening details never starts compaction implicitly.
private struct ContextUsageButton: View {
    let state: ContextUsageState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
                switch state {
                case .ready(let usage):
                    Circle().trim(from: 0, to: min(1, max(0, usage.fraction)))
                        .stroke(
                            usage.fraction >= 1 ? Color.red : Color.secondary,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(usage.percentage)%").font(.system(size: 9, weight: .medium))
                case .counting:
                    ProgressView().controlSize(.mini)
                case .failed:
                    Image(systemName: "exclamationmark").font(.caption)
                case .unavailable:
                    Image(systemName: "chart.pie").font(.caption)
                }
            }
            .frame(width: 30, height: 30)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Context usage")
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        switch state {
        case .ready(let usage): return "\(usage.inputTokens) of \(usage.capacity) tokens"
        case .counting: return "Counting"
        case .unavailable(let reason), .failed(let reason): return reason
        }
    }
}

/// Shows exact next-message usage and an explicit action through the real compaction path.
private struct ContextUsageView: View {
    @Bindable var model: LocalInferenceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Next message context") {
                    switch model.contextUsage {
                    case .ready(let usage):
                        LabeledContent("Used", value: "\(usage.inputTokens) tokens")
                            .accessibilityIdentifier("context-used")
                        LabeledContent("Capacity", value: "\(usage.capacity) tokens")
                        LabeledContent("Reply reserve", value: "\(usage.replyReserve) tokens")
                        LabeledContent(
                            "Auto-compaction threshold",
                            value:
                                "\(usage.automaticThreshold) tokens")
                        Text(
                            "Summary generation reserves \(usage.summaryReserve) tokens, with "
                                + "\(usage.headroom) tokens of headroom."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    case .counting:
                        ProgressView("Counting context…")
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.secondary)
                    case .failed(let reason):
                        Text("Could not count context: \(reason)").foregroundStyle(.red)
                        Button("Retry count") { model.retryContextUsage() }
                            .disabled(model.busy)
                    }
                    Text(
                        "Includes saved tool definitions, summary, retained turns, current draft "
                            + "and model template. Send reconnects tools when needed "
                            + "and rechecks the budget. "
                            + "Earlier assistant reasoning follows the model’s template rules."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Compaction") {
                    Button("Compact now") {
                        model.compactNow()
                        dismiss()
                    }
                    .disabled(model.manualCompactionUnavailableReason != nil)
                    if let reason = model.manualCompactionUnavailableReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(
                        "Summarizes older turns on this device, keeping the visible chat and "
                            + "latest two exchanges. Summaries can lose details. Use Stop during generation "
                            + "to keep the previous committed summary."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
