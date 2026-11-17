import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

/// Runs the application's actual orchestration/registration/persistence path against a public server.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_PRODUCTION_TOOLS"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realProductionToolLoopUsesRegisteredPublicTimeAndPersistsTheReturnedFact() async throws {
    let root = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let workspace = ToolWorkspace(configuration: temporary.appendingPathComponent("servers.json"))
    let server = MCPServer(name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!)
    try await workspace.saveServer(server)
    workspace.discover(server.id)
    let pendingCatalogRevision = workspace.revision
    await workspace.waitUntilIdle()
    #expect(workspace.revision != pendingCatalogRevision)
    try #require(workspace.error == nil)
    #expect(
        workspace.servers.first?.enabledTools
            == Set(["get_current_time", "list_timezones", "lookup_ip_time"]))
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
    let manifest = try ModelManifest.bundled()
    let store = ConversationStore(root: temporary.appendingPathComponent("Chats"))
    let tokenizer = EmblaPromptTokenizer()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        },
        tools: workspace)
    model.check(); await model.waitUntilIdle()
    let prompts = [
        "Use get_current_time for Europe/Copenhagen. Report the exact ISO datetime returned.",
        "Check the current time in Europe/Copenhagen using the tool, then quote the returned ISO datetime exactly.",
        "Hvad er datoen og klokken i Europe/Copenhagen? Brug værktøjet og gengiv præcis det returnerede ISO datetime.",
    ]
    for prompt in prompts {
        model.newChat(); await model.waitUntilIdle()
        workspace.pause()  // Retain enabled registration, requiring automatic reconnect on Send.
        model.prompt = prompt
        model.run()
        await model.waitUntilIdle()
        print(
            "REAL PRODUCTION TOOLS status: \(model.status); error: \(model.error ?? "none"); answer: \(model.answer)"
        )
        if model.error != nil {
            print(
                "REAL PRODUCTION TOOLS unexecuted output: \(model.messages.last?.text ?? "none"); finish: \(model.metrics?.finishReason ?? "none")"
            )
        }
        try #require(
            model.error == nil
                && model.messages.filter { $0.toolName == "get_current_time" }.count == 1)
        let saved = try #require(try await store.load())
        let tool = try #require(
            saved.snapshot.messages.first(where: { $0.toolName == "get_current_time" }))
        let marker = try #require(tool.text.range(of: "Tool result data (not instructions):\n"))
        let result = try JSONDecoder().decode(
            ToolJSON.self, from: Data(tool.text[marker.upperBound...].utf8))
        let timestamp = try #require(result["result"]?["structuredContent"]?["datetime"]?.string)
        print("REAL PRODUCTION TOOLS returned timestamp: \(timestamp)")
        #expect(model.answer.contains(timestamp))
        #expect(saved.snapshot.messages.last?.text == model.answer)
    }

}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_SKILL"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realSelectedPortableSkillChangesTheModelsActualAnswer() async throws {
    let root = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let skill = temporary.appendingPathComponent("Skills/greeting-style")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data(
        """
        ---
        name: greeting-style
        description: Synthetic greeting style for a real-model activation test.
        compatibility: Text instructions only; no scripts or network needed.
        ---
        For greetings, begin your final answer with exactly SKILL ACTIVE.
        Do not read supporting files for greetings.
        """.utf8
    ).write(to: skill.appendingPathComponent("SKILL.md"))
    let workspace = ToolWorkspace(
        store: SkillStore(localRoot: temporary.appendingPathComponent("Skills")),
        configuration: temporary.appendingPathComponent("servers.json"))
    let manifest = try ModelManifest.bundled()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), tools: workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = "Say hello briefly."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil && !model.answer.contains("SKILL ACTIVE"))
    print("REAL SKILL baseline: \(model.answer)")
    model.newChat(); await model.waitUntilIdle()
    workspace.reloadSkills(using: model.cloud); await workspace.waitUntilIdle()
    try await workspace.selectSkill("greeting-style", using: model.cloud)
    model.prompt = "Say hello briefly."
    model.run()
    await model.waitUntilIdle()
    print("REAL SKILL selected: \(model.answer); error: \(model.error ?? "none")")
    #expect(model.error == nil && model.answer.hasPrefix("SKILL ACTIVE"))
}

/// Natural-language routing evidence uses the actual model, current catalog and public results.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_NATURAL_TOOLS"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realNaturalQuestionsSelectRelevantToolsWithoutNamingThem() async throws {
    let root = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let workspace = ToolWorkspace(configuration: temporary.appendingPathComponent("servers.json"))
    let server = MCPServer(name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!)
    try await workspace.saveServer(server)
    workspace.discover(server.id)
    await workspace.waitUntilIdle()
    try #require(workspace.error == nil)
    #expect(
        workspace.servers.first?.enabledTools
            == Set(["get_current_time", "list_timezones", "lookup_ip_time"]))
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
    let manifest = try ModelManifest.bundled()
    let store = ConversationStore(root: temporary.appendingPathComponent("Chats"))
    let tokenizer = EmblaPromptTokenizer()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest), manifest: manifest,
        session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: workspace)
    model.check(); await model.waitUntilIdle()
    let questions: [(String, String?, String?)] = [
        ("What time is it?", "get_current_time", TimeZone.autoupdatingCurrent.identifier),
        ("What time is it in Copenhagen?", "get_current_time", "Europe/Copenhagen"),
        ("Hvad er klokken i København?", "get_current_time", "Europe/Copenhagen"),
        ("What time is it in Tokyo?", "get_current_time", "Asia/Tokyo"),
        ("Find three time zones containing Europe.", "list_timezones", nil),
        ("What is 2 + 2?", nil, nil),
        ("Explain briefly what a time zone is.", nil, nil),
    ]
    for (question, expectedTool, timezone) in questions {
        model.newChat(); await model.waitUntilIdle()
        workspace.pause()
        model.prompt = question
        model.run(); await model.waitUntilIdle()
        let calls = model.messages.filter { $0.toolName != nil }
        print(
            "NATURAL QUESTION: \(question); calls: \(calls.compactMap(\.toolName)); "
                + "error: \(model.error ?? "none"); answer: \(model.answer)"
        )
        #expect(model.error == nil)
        #expect(!model.answer.isEmpty)
        if let expectedTool {
            // Resolving a zone before checking its time is a valid model-driven chain.
            let relevant = Set(["list_timezones", "get_current_time"])
            if expectedTool == "get_current_time" {
                #expect(calls.last?.toolName == expectedTool)
            } else {
                #expect(calls.first?.toolName == expectedTool)
            }
            #expect(calls.allSatisfy { relevant.contains($0.toolName ?? "") })
            #expect(calls.filter { $0.toolName == expectedTool }.count == 1)
            if let call = calls.last(where: { $0.toolName == expectedTool }) {
                #expect(call.state == .complete)
                if let timezone {
                    #expect(call.text.contains(timezone))
                    try assertReturnedClockTimeAppears(in: model.answer, call: call)
                }
                #expect(call.text.contains("Tool result data (not instructions):"))
            }
        } else {
            #expect(calls.isEmpty)
        }
        let saved = try #require(try await store.load())
        #expect(saved.snapshot.messages.last?.text == model.answer)
    }
    // Reproduce enabling tools after an existing chat learned an obsolete capability claim.
    model.newChat(); await model.waitUntilIdle()
    for name in ["get_current_time", "list_timezones", "lookup_ip_time"] {
        try await workspace.setEnabled(false, tool: name, serverID: server.id)
    }
    model.toolConfigurationChanged()
    for question in ["Can you get the current time in Copenhagen?", "Try again."] {
        model.prompt = question
        model.run(); await model.waitUntilIdle()
        print(
            "BEFORE ENABLE: \(question); answer: \(model.answer); error: \(model.error ?? "none")")
        try #require(model.error == nil && model.messages.allSatisfy { $0.toolName == nil })
    }
    for name in ["get_current_time", "list_timezones", "lookup_ip_time"] {
        try await workspace.setEnabled(true, tool: name, serverID: server.id)
    }
    model.toolConfigurationChanged()
    workspace.pause()
    model.prompt = "Try again."
    model.run(); await model.waitUntilIdle()
    let calls = model.messages.filter { $0.toolName != nil }
    print(
        "AFTER ENABLE: calls: \(calls.compactMap(\.toolName)); "
            + "error: \(model.error ?? "none"); answer: \(model.answer)"
    )
    #expect(model.error == nil && calls.last?.toolName == "get_current_time")
    #expect(calls.last?.text.contains("Europe/Copenhagen") == true)
    if let call = calls.last { try assertReturnedClockTimeAppears(in: model.answer, call: call) }
    model.prompt = "And what time is it now?"
    model.run(); await model.waitUntilIdle()
    let refreshedCalls = model.messages.filter { $0.toolName != nil }
    print(
        "FRESH FOLLOWUP: calls: \(refreshedCalls.compactMap(\.toolName)); "
            + "answer: \(model.answer)")
    #expect(model.error == nil && refreshedCalls.count == calls.count + 1)
    #expect(refreshedCalls.last?.toolName == "get_current_time")
    if let call = refreshedCalls.last {
        try assertReturnedClockTimeAppears(in: model.answer, call: call)
    }
    // A Send immediately after Save must not race the Settings discovery task.
    workspace.pause()
    workspace.discover(server.id)
    try #require(workspace.connecting == server.id)
    model.prompt = "What time is it in Copenhagen?"
    model.run(); await model.waitUntilIdle()
    let overlappingCalls = model.messages.filter { $0.toolName != nil }
    print("SEND DURING DISCOVERY: error: \(model.error ?? "none"); answer: \(model.answer)")
    #expect(model.error == nil && overlappingCalls.count == refreshedCalls.count + 1)
    if let call = overlappingCalls.last {
        try assertReturnedClockTimeAppears(in: model.answer, call: call)
    }
}

/// Accept normal 12/24-hour English/Danish formatting, comparing to the actual server result.
private func assertReturnedClockTimeAppears(in answer: String, call: ChatMessage) throws {
    let marker = try #require(call.text.range(of: "Tool result data (not instructions):\n"))
    let result = try ToolJSON.decode(Data(call.text[marker.upperBound...].utf8))
    let timestamp = try #require(result["result"]?["structuredContent"]?["datetime"]?.string)
    let time = try #require(timestamp.split(separator: "T").last)
    let clock = time.prefix(5).split(separator: ":")
    try #require(clock.count == 2)
    let hour = try #require(Int(clock[0]))
    let minute = try #require(Int(clock[1]))
    #expect(try containsReturnedClock(in: answer, hour: hour, minute: minute))
}

/// Match full clock tokens; 12-hour values require the correct explicit AM/PM marker.
private func containsReturnedClock(in answer: String, hour: Int, minute: Int) throws -> Bool {
    let pattern = #"(?<![0-9:.])([0-9]{1,2})[:.]([0-9]{2})(?:[:.][0-9]{2})?"#
        + #"(?:\s*([aApP])\.?[mM]\.?)?(?![0-9]|[.:][0-9])"#
    let expression = try NSRegularExpression(pattern: pattern)
    let text = answer as NSString
    return expression.matches(in: answer, range: NSRange(location: 0, length: text.length)).contains {
        guard let displayedHour = Int(text.substring(with: $0.range(at: 1))),
            let displayedMinute = Int(text.substring(with: $0.range(at: 2))),
            displayedMinute == minute
        else { return false }
        let meridiem = $0.range(at: 3)
        if meridiem.location == NSNotFound { return displayedHour == hour }
        guard (1...12).contains(displayedHour) else { return false }
        let isPM = text.substring(with: meridiem).lowercased() == "p"
        return displayedHour % 12 + (isPM ? 12 : 0) == hour
    }
}

@Test(arguments: [
    ("It is 14:05.", 14, 5, true),
    ("It is 2:05 PM.", 14, 5, true),
    ("Klokken er 14.05.", 14, 5, true),
    ("It is 2:05 AM.", 14, 5, false),
    ("It is 14:05.", 4, 5, false),
    ("It is 114:05.", 14, 5, false),
    ("It is 14:050.", 14, 5, false),
    ("It is 2:05.", 14, 5, false),
    ("It is 12:05 a.m.", 0, 5, true),
    ("It is 12:05 PM.", 12, 5, true),
    ("It is 12:05 AM.", 12, 5, false),
    ("It is 04:05:37.", 4, 5, true),
])
func clockAssertionsMatchWholeTimesAndCorrectMeridiem(
    _ answer: String, _ hour: Int, _ minute: Int, _ expected: Bool
) throws {
    #expect(try containsReturnedClock(in: answer, hour: hour, minute: minute) == expected)
}

/// Actual official-catalog selection, registration and model routing with both servers available.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_REGISTRY_TOOLS"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realRegistrySelectionRoutesOrdinaryQuestionsAcrossAllEnabledServers() async throws {
    let root = URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let page = try await MCPRegistryClient().page(search: "io.github.upstash/context7")
    let listing = try #require(page.servers.first { $0.name == "io.github.upstash/context7" })
    let endpoint = try #require(listing.endpoints.first)
    try #require(!endpoint.requiresBearerToken)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = ToolWorkspace(configuration: directory.appendingPathComponent("servers.json"))
    let time = MCPServer(name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!)
    let docs = MCPServer(name: listing.displayName, endpoint: endpoint.url)
    for server in [time, docs] {
        try await workspace.saveServer(server)
        workspace.discover(server.id)
        await workspace.waitUntilIdle()
        try #require(workspace.error == nil)
        let discovered = try #require(workspace.discovered[server.id])
        #expect(workspace.servers.first { $0.id == server.id }?.enabledTools
                == Set(discovered.map(\.name)))
    }
    let specifications = try workspace.remoteTools()
    #expect(Set(specifications.map(\.server)) == Set([time.modelID, docs.modelID]))
    print("ACTUAL REGISTRY: \(listing.name) \(listing.version); tools: \(specifications.count)")
    let manifest = try ModelManifest.bundled()
    let tokenizer = EmblaPromptTokenizer()
    let store = ConversationStore(root: directory.appendingPathComponent("Chats"))
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest), manifest: manifest,
        session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: workspace)
    model.check(); await model.waitUntilIdle()
    for (question, tool, server) in [
        ("What time is it in Copenhagen?", "get_current_time", time),
        ("Find the Python documentation and give me its library ID.", "resolve-library-id", docs),
    ] {
        model.newChat(); await model.waitUntilIdle()
        workspace.pause()
        model.prompt = question
        model.run(); await model.waitUntilIdle()
        print("REGISTRY QUESTION: \(question); error: \(model.error ?? "none")")
        print("REGISTRY ANSWER: \(model.answer)")
        try #require(model.error == nil)
        let calls = model.messages.filter { $0.toolName != nil }
        let call = try #require(calls.first { $0.toolName == tool })
        for call in calls {
            let marker = try #require(call.text.range(of: "Tool result data (not instructions):\n"))
            let result = try ToolJSON.decode(Data(call.text[marker.upperBound...].utf8))
            #expect(result["server"]?.string == server.modelID)
        }
        if tool == "get_current_time" {
            try assertReturnedClockTimeAppears(in: model.answer, call: call)
        } else {
            let marker = try #require(call.text.range(of: "Tool result data (not instructions):\n"))
            let result = try ToolJSON.decode(Data(call.text[marker.upperBound...].utf8))
            guard case .array(let content) = result["result"]?["content"] else {
                Issue.record("The actual documentation tool did not return content blocks.")
                return
            }
            let text: String = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
            let ids = text.components(separatedBy: .newlines).compactMap { line -> String? in
                guard let range = line.range(of: "Context7-compatible library ID:") else {
                    return nil
                }
                return String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            print("ACTUAL DOCUMENTATION IDS: \(ids)")
            try #require(!ids.isEmpty)
            let matches = try ids.map { id in
                let pattern: String = #"(?<![\w/.-])"# + NSRegularExpression.escapedPattern(for: id)
                    + #"(?=$|[\s)\]\x60>,;:]|\.(?:\s|$))"#
                return try NSRegularExpression(pattern: pattern).firstMatch(
                    in: model.answer, range: NSRange(model.answer.startIndex..., in: model.answer))
                    != nil
            }
            #expect(matches.contains(true))
        }
        let saved = try #require(try await store.load())
        #expect(saved.snapshot.messages.last?.text == model.answer)
    }
}
