import Testing
@testable import EmblaCore

@Test func compactionKeepsTwoExchangesAndIncorporatesPreviousSummary() throws {
    let policy = ContextCompaction()
    let transcript = (0..<9).map {
        ConversationMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "turn \($0)")
    }
    let previous = CompactionState(summary: "Earlier decisions", summarizedMessageCount: 2)
    let plan = try policy.plan(transcript: transcript, state: previous)
    #expect(plan.boundary == 4)
    #expect(plan.messages.first?.content.contains("Earlier decisions") == true)
    #expect(plan.messages[1].content == "turn 2")
    let candidate = try policy.candidate(text: " New summary ", finishReason: "stop", plan: plan)
    let context = policy.context(transcript: transcript, state: candidate)
    #expect(context.count == 6)
    #expect(context[1].content == "turn 4")
    #expect(candidate.summary == "New summary")
    #expect(previous.summary == "Earlier decisions")
}

@Test func truncatedOrEmptySummariesAreRejected() throws {
    let policy = ContextCompaction()
    let transcript = (0..<7).map {
        ConversationMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "turn \($0)")
    }
    let plan = try policy.plan(transcript: transcript, state: CompactionState())
    #expect(throws: CompactionError.self) {
        try policy.candidate(text: "Partial", finishReason: "length", plan: plan)
    }
    #expect(throws: CompactionError.self) {
        try policy.candidate(text: "  ", finishReason: "stop", plan: plan)
    }
}

@Test func recentOnlyHistoryIsNotSilentlyDiscarded() {
    let policy = ContextCompaction()
    #expect(policy.triggerTokens + policy.summaryTokens + policy.responseTokens < policy.contextSize)
    #expect(throws: CompactionError.self) {
        try policy.plan(
            transcript: [ConversationMessage(role: .user, content: "Large first message")],
            state: CompactionState())
    }
}
