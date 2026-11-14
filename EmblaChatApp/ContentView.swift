import SwiftUI
import UIKit

import EmblaCore
import EmblaPresentation

/// Minimal local inference screen; all generation uses the shared production API.
struct ContentView: View {
    @State private var model = LocalInferenceModel()
    @State private var confirmDelete = false
    @State private var confirmNewChat = false
    @FocusState private var promptFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Model setup") {
                    Text("Embla 1").font(.headline)
                    if let manifest = model.manifest {
                        LabeledContent("Download", value: size(manifest.totalBytes))
                        Text("Source: \(manifest.repository). License: MIT.").font(.caption)
                    }
                    LabeledContent("Local model storage", value: size(model.storedBytes))
                    if model.downloading, let total = model.manifest?.totalBytes {
                        ProgressView(value: Double(model.downloadedBytes), total: Double(total))
                        Text("\(size(model.downloadedBytes)) of \(size(total)) received").font(
                            .caption)
                    }
                    if !model.busy {
                        if model.readyDirectory == nil {
                            Button("Download model") { model.download() }
                                .disabled(model.manifest == nil)
                        }
                        Button("Check model files") { model.check() }
                            .disabled(model.manifest == nil)
                        if model.storedBytes > 0 {
                            Button("Delete model", role: .destructive) { confirmDelete = true }
                        }
                    }
                }
                Section("Local inference") {
                    TextField("Prompt", text: $model.prompt, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($promptFocused)
                        .accessibilityIdentifier("prompt")
                        .disabled(model.busy)
                    HStack {
                        Button("Run") {
                            promptFocused = false; model.run()
                        }
                        .disabled(!model.canRun)
                        Button("Stop") { model.stop() }
                            .disabled(!model.busy)
                        Button("New Chat") {
                            promptFocused = false; confirmNewChat = true
                        }
                        .disabled(
                            (model.busy && !model.running)
                                || (model.prompt.isEmpty && model.reasoning.isEmpty
                                    && model.answer.isEmpty)
                        )
                    }
                    .buttonStyle(.borderless)
                    Text(model.status).accessibilityIdentifier("model-status")
                    if model.busy && !model.downloading { ProgressView() }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text(
                        "Each Run submits one prompt. Conversation history and compaction come later."
                    )
                    .font(.caption)
                }
                if !model.reasoning.isEmpty {
                    Section("Reasoning") {
                        Text(model.reasoning).textSelection(.enabled).accessibilityIdentifier(
                            "reasoning")
                    }
                }
                if !model.answer.isEmpty {
                    Section("Answer") {
                        Text(model.answer).textSelection(.enabled).accessibilityIdentifier("answer")
                    }
                }
                if model.loadMilliseconds != nil || model.metrics != nil {
                    Section("Measured results") {
                        if let time = model.loadMilliseconds {
                            LabeledContent("Last verified load", value: milliseconds(time))
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
            .navigationTitle("Embla Chat")
            .task { model.check() }
            .onChange(of: model.busy) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .inactive { model.becameInactive() }
                if phase == .background { model.enteredBackground() }
                updateIdleTimer()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { promptFocused = false }
                }
            }
            .alert("Delete downloaded model files?", isPresented: $confirmDelete) {
                Button("Delete model", role: .destructive) { model.delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to download the model again. This does not delete chat data.")
            }
            .alert("Start a new chat?", isPresented: $confirmNewChat) {
                Button("Start new chat", role: .destructive) { model.newChat() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The current prompt and output will be cleared after any active generation stops."
                )
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.busy && scenePhase == .active
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private func milliseconds(_ time: Double) -> String { String(format: "%.0f ms", time) }
}
