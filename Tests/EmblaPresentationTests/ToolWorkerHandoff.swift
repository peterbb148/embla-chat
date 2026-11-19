import Foundation
import Testing

import EmblaCore

/// Interprets the prototype router output before any text is shown or added to history.
enum ToolWorkerHandoff: Equatable {
    case delegate
    case answer(String)

    static func parse(_ output: String, finishReason: String?) throws -> Self {
        guard finishReason == "stop" else { throw ToolProtocolError.invalidResponse }
        let segments = output.components(separatedBy: "</think>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if segments == ["DELEGATE"] || segments == ["DELEGATE", "DELEGATE"] {
            return .delegate
        }

        // A router signal embedded in an otherwise ambiguous output is never a direct answer.
        guard segments.count == 1, !output.contains("<think"),
            output.range(of: #"\bDELEGATE\b"#, options: .regularExpression) == nil,
            case .answer(let text) = try ModelToolResponse.parse(output, finishReason: finishReason)
        else { throw ToolProtocolError.invalidResponse }
        return .answer(text)
    }
}

@Test func workerHandoffConsumesTheRepeatedSignalObservedOnIPhone() throws {
    #expect(
        try ToolWorkerHandoff.parse("DELEGATE\n</think>\n\nDELEGATE", finishReason: "stop")
            == .delegate)
    #expect(try ToolWorkerHandoff.parse("DELEGATE", finishReason: "stop") == .delegate)
    #expect(
        try ToolWorkerHandoff.parse("2 + 2 is 4.", finishReason: "stop") == .answer("2 + 2 is 4."))
}

@Test func workerHandoffRejectsIncompleteOrAmbiguousOutput() {
    for output in [
        "DELEGATE\nHere is an answer.", "DELEGATE\n</think>\n4", "<think>DELEGATE",
        "DELEGATE.", "(DELEGATE)", "`DELEGATE`",
    ] {
        #expect(throws: ToolProtocolError.self) {
            try ToolWorkerHandoff.parse(output, finishReason: "stop")
        }
    }
    #expect(throws: ToolProtocolError.self) {
        try ToolWorkerHandoff.parse("DELEGATE", finishReason: "length")
    }
}
