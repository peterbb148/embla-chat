import CryptoKit
import Foundation

import Yams

/// A portable skill's validated metadata and instructions. Selection is always explicit.
public struct SkillDocument: Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let compatibility: String?
    public let allowedTools: String?
    public let instructions: String
    public let fingerprint: String
    public var id: String { name }

    public static func decode(_ data: Data, directoryName: String) throws -> Self {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw SkillFailure.invalid("SKILL.md must be UTF-8 text of at most 64 KiB.")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw SkillFailure.invalid("SKILL.md needs YAML frontmatter between --- lines.")
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        guard yaml.utf8.count <= 16_384 else {
            throw SkillFailure.invalid("Skill metadata exceeds 16 KiB.")
        }
        guard let node = try Yams.compose(yaml: yaml), let mapping = node.mapping,
            Set(mapping.map { $0.key.string }).count == mapping.count
        else { throw SkillFailure.invalid("Skill metadata must be a mapping with unique keys.") }
        let metadata = try YAMLDecoder().decode(Metadata.self, from: node)
        let name = metadata.name
        guard (1...64).contains(name.count), name == directoryName,
            !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--"),
            name.unicodeScalars.allSatisfy({
                CharacterSet.lowercaseLetters.contains($0)
                    || CharacterSet.decimalDigits.contains($0) || $0 == "-"
            }), (1...1_024).contains(metadata.description.count),
            !metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SkillFailure.invalid("Invalid skill name/description, or folder name mismatch.")
        }
        if let compatibility = metadata.compatibility, !(1...500).contains(compatibility.count) {
            throw SkillFailure.invalid("Skill compatibility must be 1–500 characters.")
        }
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillFailure.invalid("Skill instructions are empty.")
        }
        return Self(
            name: name, description: metadata.description,
            compatibility: metadata.compatibility, allowedTools: metadata.allowedTools,
            instructions: body,
            fingerprint: SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined())
    }

    public var context: String {
        "User-selected skill '\(name)' instructions (no script runtime is available):\n"
            + instructions
    }

    private struct Metadata: Decodable {
        let name: String
        let description: String
        let compatibility: String?
        let allowedTools: String?
        let license: String?
        let metadata: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, description, compatibility, license, metadata
            case allowedTools = "allowed-tools"
        }
    }
}

public struct SkillEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let document: SkillDocument?
    public let error: String?
}

public enum SkillFailure: Error, LocalizedError, Sendable {
    case invalid(String), changed, unsupportedResource, unavailable

    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .changed: return "The skill or its source changed. Reload and select it again."
        case .unsupportedResource:
            return
                "Only UTF-8 supporting files inside the selected skill can be read. Scripts cannot be run."
        case .unavailable: return "Confirm the iCloud preference and folder before reading Skills."
        }
    }
}
