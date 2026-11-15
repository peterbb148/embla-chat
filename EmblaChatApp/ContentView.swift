import EmblaCore
import EmblaPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Single conversational screen backed by the real local Embla runtime.
struct ContentView: View {
    @State private var model = LocalInferenceModel()
    @State private var sheet: Sheet?
    @State private var confirmNewChat = false
    @State private var followingOutput = true
    @State private var readerScrolling = false
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private enum Sheet: String, Identifiable {
        case settings
        var id: String { rawValue }
    }

    private struct Viewport: Equatable {
        let height: CGFloat
        let contentHeight: CGFloat
        let nearBottom: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.messages) { message in
                                ChatMessageRow(message: message).equatable()
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
                        Viewport(
                            height: geometry.containerSize.height,
                            contentHeight: geometry.contentSize.height,
                            nearBottom: geometry.contentOffset.y + geometry.containerSize.height
                                >= geometry.contentSize.height - 100)
                    } action: { old, new in
                        if readerScrolling {
                            followingOutput = new.nearBottom
                        } else if followingOutput && (
                            old.height != new.height || old.contentHeight != new.contentHeight
                        ) {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        readerScrolling = phase == .tracking || phase == .interacting
                            || phase == .decelerating
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followingOutput {
                            Button {
                                followingOutput = true
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
                        if followingOutput { reader.scrollTo("latest-message", anchor: .bottom) }
                    }
                    .onChange(of: model.messages.last?.reasoning) { _, _ in
                        if followingOutput { reader.scrollTo("latest-message", anchor: .bottom) }
                    }
                    .onChange(of: model.messages.count) { oldCount, _ in
                        if model.messages.isEmpty || model.messages.dropFirst(oldCount).contains(
                            where: { $0.role == .user }
                        ) {
                            followingOutput = true
                        }
                        if followingOutput { reader.scrollTo("latest-message", anchor: .bottom) }
                    }
                    composer
                }
            }
            .navigationTitle("Embla Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Embla")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        composerFocused = false
                        sheet = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmNewChat = true
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(
                        model.resetting || model.cloud.resolving || (model.busy && !model.running)
                            || (model.messages.isEmpty && model.prompt.isEmpty))
                }
            }
            .sheet(item: $sheet) { _ in ModelSettingsView(model: model) }
            .alert("Start a new chat?", isPresented: $confirmNewChat) {
                Button("Start new chat", role: .destructive) {
                    composerFocused = false
                    model.newChat()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the current conversation after any active response stops.")
            }
            .task { model.check() }
            .onChange(of: model.resetting) { _, resetting in
                composerFocused = !resetting
            }
            .onChange(of: model.conversationID) { _, _ in
                followingOutput = true
                composerFocused = true
            }
            .onChange(of: model.busy) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.becameActive() }
                if phase == .inactive { model.becameInactive() }
                if phase == .background { model.enteredBackground() }
                updateIdleTimer()
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                if message.role == .assistant {
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
                    CopyTextButton(text: message.text, label: "Copy message")
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

/// Model administration and measurements stay out of the conversation screen.
private struct ModelSettingsView: View {
    @Bindable var model: LocalInferenceModel
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
            .fileImporter(isPresented: $chooseCloudFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(folder): Task { await model.cloud.enable(folder: folder) }
                case let .failure(error): model.cloud.folderSelectionFailed(error)
                }
            }
            .alert(activeAlert?.title ?? "Settings", isPresented: Binding(
                get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } }
            ), presenting: activeAlert) { selection in
                switch selection {
                case .cloudConsent:
                    Button("Choose folder") { chooseCloudFolder = true }
                case .deleteModel:
                    Button("Delete model", role: .destructive) { model.delete() }
                case let .cloudChoice(choice):
                    Button(choice.label, role: .destructive) { model.cloud.resolve(choiceID: choice.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { selection in Text(selection.message) }

        }
    }

    private enum SettingsAlert {
        case deleteModel, cloudConsent
        case cloudChoice(CloudChatChoice)

        var title: String {
            switch self {
            case .deleteModel: return "Delete downloaded model files?"
            case .cloudConsent: return "Enable iCloud Drive?"
            case .cloudChoice: return "Use selected chat?"
            }
        }
        var message: String {
            switch self {
            case .deleteModel:
                return "You will need to download the model again. This does not clear your conversation."
            case .cloudConsent:
                return "Your chat and summary will be stored in iCloud Drive/EmblaChat/Chats. "
                    + "Select the EmblaChat folder; Skills is reserved for portable skills. "
                    + "Your draft and model stay on this device. Choose or create EmblaChat in Files."
            case .cloudChoice:
                return "This replaces the active chat in the chosen location. Using an iCloud copy "
                    + "also replaces this device’s chat and unsent draft. Other conflicting copies "
                    + "will be marked resolved."
            }
        }
    }

    private var cloudSection: some View {
        Section("iCloud") {
            Toggle("Store chats in iCloud Drive", isOn: Binding(
                get: { model.cloud.enabled },
                set: { enabled in
                    if enabled { activeAlert = .cloudConsent } else { model.cloud.disable() }
                }))
                .disabled(!model.chatRestored || model.busy || model.cloud.resolving)
                .accessibilityIdentifier("icloud-toggle")
            Text("Off by default. This setting applies to all chats.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.cloud.status).accessibilityIdentifier("icloud-status")
            if let error = model.cloud.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("icloud-error")
            }
            if model.cloud.enabled {
                Button("Sync now") { model.cloud.refresh() }
                    .disabled(model.cloud.syncing || model.busy)
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
                        Text("\(choice.snapshot.messages.count) messages")
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
                                    Text(language ?? "Code").font(.caption).foregroundStyle(.secondary)
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
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: .rect(cornerRadius: 14))
                        case .heading(let level):
                            Text(block.text)
                                .font(level == 1 ? .title2.bold() : .headline)
                                .accessibilityAddTraits(.isHeader)
                        case .listItem(let marker):
                            HStack(alignment: .top, spacing: 10) {
                                Text(marker).foregroundStyle(.secondary)
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
