import Foundation
import Testing

import EmblaCore

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
