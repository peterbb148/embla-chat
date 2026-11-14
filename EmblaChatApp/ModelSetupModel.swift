import Foundation
import Observation

import EmblaCore

/// Main-actor presentation of the repository's asynchronous model operations.
@MainActor @Observable
final class ModelSetupModel {
    private(set) var manifest: ModelManifest?
    private(set) var readyDirectory: URL?
    private(set) var storedBytes: Int64 = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var status = "Checking model storage…"
    private(set) var busy = false
    private(set) var downloading = false
    private(set) var error: String?
    @ObservationIgnored private var repository: ModelRepository?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?

    init() {
        do {
            let manifest = try ModelManifest.bundled()
            self.manifest = manifest
            repository = ModelRepository(
                root: try ModelRepository.defaultRoot(), manifest: manifest)
        } catch {
            self.error = error.localizedDescription
            status = "Model setup is unavailable."
        }
    }

    func check() { start(.check) }
    func download() { start(.download) }
    func delete() { start(.delete) }
    func cancel() { task?.cancel() }

    private enum Operation { case check, download, delete }

    private func start(_ operation: Operation) {
        guard !busy, let repository else { return }
        busy = true
        downloading = operation == .download
        error = nil
        downloadedBytes = 0
        let id = UUID()
        operationID = id
        status = downloading ? "Downloading and verifying model…" : "Checking model storage…"
        task = Task {
            do {
                switch operation {
                case .check:
                    readyDirectory = try await repository.installedDirectory()
                case .download:
                    readyDirectory = try await repository.install { [weak self] bytes in
                        Task { @MainActor in
                            guard self?.operationID == id else { return }
                            if let self { self.downloadedBytes = max(self.downloadedBytes, bytes) }
                        }
                    }
                case .delete:
                    try await repository.delete()
                    readyDirectory = nil
                }
                status =
                    readyDirectory == nil ? "Model not downloaded." : "Model verified and ready."
            } catch {
                readyDirectory = nil
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    status = "Operation cancelled. You can retry the download."
                } else {
                    self.error = error.localizedDescription
                    status = "Model setup failed."
                }
            }
            do { storedBytes = try await repository.storedBytes() } catch {
                self.error = "Could not read model storage usage: \(error.localizedDescription)"
            }
            operationID = nil
            downloading = false
            busy = false
            task = nil
        }
    }
}
