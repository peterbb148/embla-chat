import CryptoKit
import Foundation
import Security

import EmblaCore

/// A token belongs to one exact server endpoint, even if a metadata save fails partway through.
struct MCPCredentialID: Sendable, Hashable {
    let serverID: UUID
    let endpointHash: String

    init(server: MCPServer) {
        serverID = server.id
        endpointHash = SHA256.hash(data: Data(server.endpoint.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Allows failure regressions to use an isolated in-memory vault, never the real Keychain.
protocol MCPCredentialStoring: Sendable {
    func read(_ id: MCPCredentialID) throws -> String?
    func write(_ value: String, id: MCPCredentialID) throws
    func deleteEndpoint(_ id: MCPCredentialID) throws
    func deleteAll(_ serverID: UUID) throws
}

/// Non-synchronizing endpoint-bound entries stay on-device and outside copied/chat files.
struct MCPCredentials: MCPCredentialStoring {
    private func base(_ serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dk.peterbb148.embla-chat.mcp",
            kSecAttrGeneric as String: Data(("EmblaChat MCP:" + serverID.uuidString).utf8),
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func query(_ id: MCPCredentialID) -> [String: Any] {
        var query = base(id.serverID)
        query[kSecAttrAccount as String] = id.serverID.uuidString + ":" + id.endpointHash
        return query
    }

    func read(_ id: MCPCredentialID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw MCPFailure.credentialUnavailable }
        return value
    }

    func write(_ value: String, id: MCPCredentialID) throws {
        guard !value.isEmpty, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw MCPFailure.credential
        }
        let base = query(id)
        let status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw MCPFailure.credentialUnavailable
            }
        } else if status != errSecSuccess {
            throw MCPFailure.credentialUnavailable
        }
    }

    func deleteEndpoint(_ id: MCPCredentialID) throws { try delete(query(id)) }
    func deleteAll(_ serverID: UUID) throws { try delete(base(serverID)) }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPFailure.credentialUnavailable
        }
    }
}
