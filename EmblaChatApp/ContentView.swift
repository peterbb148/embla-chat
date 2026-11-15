import EmblaCore
import EmblaPresentation
import SwiftUI
import UIKit

/// Single conversational screen backed by the real local Embla runtime.
struct ContentView: View {
    @State private var model = LocalInferenceModel()
    @State private var sheet: Sheet?
    @State private var confirmNewChat = false
    @State private var followingOutput = true
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private enum Sheet: String, Identifiable {
        case settings
        var id: String { rawValue }
    }

    private struct Viewport: Equatable {
        let height: CGFloat
        let nearBottom: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.messages) { message in
                                ChatMessageRow(message: message)
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
                            nearBottom: geometry.contentOffset.y + geometry.containerSize.height
                                >= geometry.contentSize.height - 100)
                    } action: { old, new in
                        if old.height != new.height && followingOutput {
                            reader.scrollTo("latest-message", anchor: .bottom)
                        } else {
                            followingOutput = new.nearBottom
                        }
                    }
                    .onChange(of: model.messages.last?.text) { _, _ in
                        if followingOutput { reader.scrollTo("latest-message", anchor: .bottom) }
                    }
                    .onChange(of: model.messages.last?.reasoning) { _, _ in
                        if followingOutput { reader.scrollTo("latest-message", anchor: .bottom) }
                    }
                    .onChange(of: model.messages.count) { _, _ in
                        followingOutput = true
                        reader.scrollTo("latest-message", anchor: .bottom)
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
                        model.resetting || (model.busy && !model.running)
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
                composerFocused = true
            }
            .onChange(of: model.busy) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, phase in
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
                    .disabled(model.resetting || !model.chatRestored)
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
private struct ChatMessageRow: View {
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
                            Text(.init(message.text))
                        }
                    }
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .accessibilityIdentifier(message.role == .user ? "user-message" : "answer")
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
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    Text(model.storageStatus)
                        .accessibilityIdentifier("chat-storage-status")
                    Text("iCloud synchronization is not enabled. Chats are saved on this device.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.storageError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("Retry chat storage") { model.retryChatStorage() }
                            .disabled(model.busy)
                    }
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
                            .disabled(model.busy || model.manifest == nil)
                    }
                    Button("Check model files") { model.check() }
                        .disabled(model.busy || model.manifest == nil)
                    if model.storedBytes > 0 {
                        Button("Delete model", role: .destructive) { confirmDelete = true }
                            .disabled(model.busy)
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
            .alert("Delete downloaded model files?", isPresented: $confirmDelete) {
                Button("Delete model", role: .destructive) { model.delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "You will need to download the model again. This does not clear your conversation."
                )
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private func milliseconds(_ time: Double) -> String { String(format: "%.0f ms", time) }
}
