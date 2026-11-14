import SwiftUI

/// Model setup for the first local-inference milestone.
struct ContentView: View {
    @State private var model = ModelSetupModel()
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Model setup") {
                    Text("Embla 1")
                        .font(.headline)
                    if let manifest = model.manifest {
                        LabeledContent("Download", value: size(manifest.totalBytes))
                        Text("Keep additional free space for filesystem overhead.")
                            .font(.caption)
                        Text("Source: \(manifest.repository). License: MIT.")
                            .font(.caption)
                    }
                    LabeledContent("Local model storage", value: size(model.storedBytes))
                    Text(model.status)
                        .accessibilityIdentifier("model-status")
                    if model.downloading, let total = model.manifest?.totalBytes {
                        ProgressView(value: Double(model.downloadedBytes), total: Double(total))
                        Text("\(size(model.downloadedBytes)) of \(size(total)) received")
                            .font(.caption)
                    } else if model.busy {
                        ProgressView("Verifying model files…")
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.busy {
                        Button("Cancel operation") { model.cancel() }
                    } else {
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
                Section {
                    Text(
                        "Weights stay on this device and are excluded from iCloud backup. Chat is coming in the next step."
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Embla Chat")
            .task { model.check() }
            .confirmationDialog("Delete downloaded model files?", isPresented: $confirmDelete) {
                Button("Delete model", role: .destructive) { model.delete() }
            } message: {
                Text("You will need to download the model again. This does not delete chat data.")
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
