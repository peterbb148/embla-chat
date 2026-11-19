import Foundation

import EmblaCore

/// A compact projection stored once on the last result row of a completed worker task.
struct ToolWorkerReceipt: Codable, Sendable, Equatable {
    let resultIDs: [UUID]
    let data: String

    var promptData: String { "Previously retrieved tool evidence (JSON data):\n" + data }
}
