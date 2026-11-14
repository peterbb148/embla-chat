import Foundation

/// Immutable model provenance and the files required by the runtime.
public struct ModelManifest: Codable, Sendable {
    public let repository: String
    public let revision: String
    public let files: [Asset]

    public struct Asset: Codable, Sendable {
        public let path: String
        public let sizeBytes: Int64
        public let sha256: String

        enum CodingKeys: String, CodingKey {
            case path, sha256
            case sizeBytes = "size_bytes"
        }
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    public static func bundled() throws -> ModelManifest {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json")
        else {
            throw ModelStorageError.invalidManifest
        }
        return try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }

    public func url(for asset: Asset) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(asset.path)")!
    }
}

public enum ModelStorageError: Error, LocalizedError, Sendable, Equatable {
    case invalidManifest
    case busy
    case insufficientStorage(required: Int64, available: Int64)
    case capacityUnavailable
    case httpStatus(Int)
    case invalidAsset(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "The bundled model manifest is missing or invalid."
        case .busy: return "Wait for the current model operation to finish."
        case .capacityUnavailable: return "Could not check free storage. Try again."
        case let .insufficientStorage(required, available):
            return
                "The model needs \(required) free bytes; \(available) bytes are available. Free space and retry."
        case let .httpStatus(code):
            return "The model server returned HTTP \(code). Check your connection and retry."
        case let .invalidAsset(name):
            return "Model file \(name) failed verification. Delete the model and download it again."
        }
    }
}
