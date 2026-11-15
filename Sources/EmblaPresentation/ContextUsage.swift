/// Exact token usage for the next message, including the current draft's template framing.
public struct ContextUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let capacity: Int
    public let replyReserve: Int
    public let summaryReserve: Int
    public let headroom: Int

    public var automaticThreshold: Int { capacity - summaryReserve - replyReserve - headroom }
    public var fraction: Double { Double(inputTokens) / Double(capacity) }
    public var percentage: Int { Int((fraction * 100).rounded()) }
}

/// Counting errors and unavailable data never masquerade as a zero-token measurement.
public enum ContextUsageState: Sendable, Equatable {
    case unavailable(String)
    case counting
    case ready(ContextUsage)
    case failed(String)
}
