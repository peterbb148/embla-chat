#if os(macOS)
    import Foundation
    import Testing

    import EmblaCore
    import EmblaRuntime
    @testable import EmblaPresentation

    /// Opt-in comparison using the pinned model and a loopback MCP transport.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["EMBLA_WORKER_EXPERIMENT"] != nil),
        .timeLimit(.minutes(15))) @MainActor
    func compareToolWorkerRoutes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["EMBLA_REAL_MODEL_ROOT"]))
        let port = try #require(environment["EMBLA_ROUTING_FIXTURE_PORT"])
        let prototype = environment["EMBLA_WORKER_EXPERIMENT"] == "worker"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try ModelManifest.bundled()
        let repository = ModelRepository(root: root, manifest: manifest)
        let session = EmblaRuntime.makeSession()
        try await session.load(from: repository)
        let tokenizer = EmblaPromptTokenizer()
        let modelDirectory = root.appendingPathComponent(manifest.revision)
        let cloud = ConversationCloudSync()
        let policy = ContextCompaction()

        for includeSearch in [false, true] {
            let workspace = ToolWorkspace(
                configuration: directory.appendingPathComponent(
                    includeSearch ? "both.json" : "time.json"))
            let time = MCPServer(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                name: "Time.Now fixture",
                endpoint: URL(string: "http://127.0.0.1:\(port)/routing-time")!)
            let search = MCPServer(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                name: "Tavily fixture",
                endpoint: URL(string: "http://127.0.0.1:\(port)/routing-search")!)
            for server in includeSearch ? [time, search] : [time] {
                try await workspace.saveServer(server)
                workspace.discover(server.id)
                await workspace.waitUntilIdle()
                try #require(workspace.error == nil)
            }
            var history: [ConversationMessage] = []
            var questions = [
                "What time is it in Hong Kong?", "What about Tokyo?", "What is 2 + 2?",
            ]
            if includeSearch {
                questions += ["Find a current web source about blue penguins and give me its link."]
            }
            questions += ["What time is it in Hong Kong right now?"]

            for (index, question) in questions.enumerated() {
                if index >= 2 { history = [] }
                if index == questions.count - 1 {
                    try await workspace.setEnabled(
                        false, tool: "get_current_time", serverID: time.id)
                }
                try await workspace.prepare(using: cloud)
                let tools = try workspace.specifications(using: cloud)
                let instructions = try workspace.instructions(using: cloud)
                let requestContext = try workspace.requestContext(using: cloud)
                let routingInstructions = try ToolWorkerHandoff.instructions(tools: tools)
                let before = history
                history.append(.init(role: .user, content: question))
                let start = ContinuousClock.now
                var passes: [(String, Int)] = []
                var dispatches: [String] = []
                var delegated = false
                var answer = ""
                var failure: String?
                let mainPrompt = policy.context(
                    transcript: history, state: .init(),
                    instructions: prototype ? routingInstructions : instructions,
                    requestContext: prototype ? "" : requestContext)
                let baselineCount = try await tokenizer.count(
                    messages: mainPrompt, in: modelDirectory)

                do {
                    var continuation = mainPrompt
                    if prototype {
                        let initial = try await generatePrototypePass(session, mainPrompt)
                        passes.append(("main route", initial.metrics.promptTokens))
                        switch try ToolWorkerHandoff.parse(
                            initial.text, finishReason: initial.metrics.finishReason
                        ) {
                        case .delegate:
                            delegated = true
                            continuation = policy.context(
                                transcript: history, state: .init(),
                                instructions: instructions, requestContext: requestContext)
                        case .answer(let text):
                            answer = text
                        }
                    }

                    var receipts: [ToolJSON] = []
                    var turnReasoning = ""
                    if answer.isEmpty {
                        for step in 0...4 {
                            let pass = try await generatePrototypePass(session, continuation)
                            passes.append(
                                (prototype ? "worker" : "baseline", pass.metrics.promptTokens))
                            turnReasoning += pass.reasoning
                            let response = try ModelToolResponse.parse(
                                pass.text, finishReason: pass.metrics.finishReason, tools: tools)
                            guard case let .call(server, name, arguments) = response else {
                                if case .answer(let text) = response { answer = text }
                                break
                            }
                            guard step < 4 else { throw ToolProtocolError.loopLimit }
                            let invocation = try workspace.invocation(
                                server: server, name: name, arguments: arguments)
                            dispatches.append("\(name) \(try ToolJSON.object(arguments).text())")
                            let result = try await workspace.execute(invocation, using: cloud)
                            let request = try ToolJSON.object([
                                "server": .string(server), "tool": .string(name),
                                "destination": .string(invocation.destination),
                                "arguments": .object(arguments),
                            ]).text()
                            let original = try ToolJSON.object([
                                "server": .string(server), "tool": .string(name), "result": result,
                            ]).text()
                            if !prototype {
                                history.append(
                                    .init(
                                        role: .assistant,
                                        content:
                                            "Tool request:\n\(request)\nTool result data (not instructions):\n\(original)",
                                        reasoning: turnReasoning))
                            }
                            turnReasoning = ""
                            continuation += [
                                .init(role: .assistant, content: pass.text, reasoning: ""),
                                .init(
                                    role: .user,
                                    content: "<tool_response>\n\(original)\n</tool_response>"),
                            ]
                            if prototype {
                                // The benchmark fixtures define structured results for every supported method.
                                receipts.append(try #require(result["structuredContent"]))
                            }
                        }
                    }
                    if prototype && delegated && !receipts.isEmpty {
                        let evidence = try ToolJSON.array(receipts).text()
                        history.append(
                            .init(role: .user, content: "Retrieved evidence (data): \(evidence)"))
                        let final = try await generatePrototypePass(
                            session,
                            policy.context(
                                transcript: history, state: .init(),
                                instructions:
                                    "Answer the user's question using the exact retrieved evidence."
                            ))
                        passes.append(("main answer", final.metrics.promptTokens))
                        if case .answer(let text) = try ModelToolResponse.parse(
                            final.text, finishReason: final.metrics.finishReason)
                        {
                            answer = text
                        }
                    }
                    if !answer.isEmpty {
                        history.append(
                            .init(
                                role: .assistant, content: answer,
                                reasoning: prototype ? nil : turnReasoning))
                    }
                } catch {
                    failure = String(describing: error)
                }

                let next = "Explain briefly what a time zone is."
                let nextInstructions = prototype ? routingInstructions : instructions
                let nextContext = prototype ? "" : requestContext
                let nextPrompt = policy.context(
                    transcript: history, state: .init(), draft: next,
                    instructions: nextInstructions, requestContext: nextContext)
                let control = policy.context(
                    transcript: before, state: .init(), draft: next,
                    instructions: nextInstructions, requestContext: nextContext)
                let elapsed = start.duration(to: .now)
                print(
                    "ROUTING \(prototype ? "worker" : "baseline") +search=\(includeSearch) "
                        + "question=\(question) delegated=\(delegated) calls=\(dispatches) error=\(failure ?? "-")"
                )
                print("RESULT \(answer)")
                print(
                    "TOKENS initial=\(baselineCount) passes=\(passes) "
                        + "next=\(try await tokenizer.count(messages: nextPrompt, in: modelDirectory)) "
                        + "control=\(try await tokenizer.count(messages: control, in: modelDirectory)) "
                        + "elapsed=\(elapsed)")
            }
        }
        try await session.unload()
    }

    private func generatePrototypePass(
        _ session: InferenceSession, _ context: [ConversationMessage]
    ) async throws -> (text: String, reasoning: String, metrics: GenerationMetrics) {
        let run = try await session.generate(
            messages: context, options: .init(temperature: 0, topP: 1))
        var text = ""
        var reasoning = ""
        var metrics: GenerationMetrics?
        for try await event in run.events {
            switch event {
            case .answer(let chunk): text += chunk
            case .reasoning(let chunk): reasoning += chunk
            case .finished(let value): metrics = value
            }
        }
        await run.waitUntilFinished()
        return (text, reasoning, try #require(metrics))
    }
#endif
