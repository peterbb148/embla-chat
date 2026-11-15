/// Distinguishes reader movement from output growth, including a stationary touch/hold.
public struct TranscriptScrollState {
    public private(set) var followingOutput = true
    public private(set) var readerScrolling = false
    private var lastOffset: Double?

    public init() {}

    public var shouldScrollAutomatically: Bool { followingOutput && !readerScrolling }

    /// Call with phase-context geometry, including the final offset before ending a gesture.
    public mutating func phaseChanged(scrolling: Bool, offset: Double, nearBottom: Bool) {
        geometryChanged(offset: offset, nearBottom: nearBottom)
        readerScrolling = scrolling
        lastOffset = offset
    }

    /// Only actual offset movement during a reader gesture changes the follow preference.
    public mutating func geometryChanged(offset: Double, nearBottom: Bool) {
        if readerScrolling, let lastOffset {
            if offset < lastOffset { followingOutput = false }
            if offset > lastOffset && nearBottom { followingOutput = true }
        }
        lastOffset = offset
    }

    /// Send and Jump to latest explicitly request following without interrupting a gesture.
    public mutating func resumeFollowing() {
        followingOutput = true
        lastOffset = nil
    }
}
