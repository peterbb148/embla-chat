/// Distinguishes reader movement from output growth, including a stationary touch/hold.
public struct TranscriptScrollState {
    public private(set) var followingOutput = true
    public private(set) var readerScrolling = false
    private var lastRawOffset: Double?

    public init() {}

    /// Shared legal bounds let both compared raw offsets use the same layout dimensions.
    public static func scrollBounds(
        contentHeight: Double, viewportHeight: Double,
        topInset: Double = 0, bottomInset: Double = 0
    ) -> ClosedRange<Double> {
        let lower = -topInset
        return lower...max(lower, contentHeight - viewportHeight + bottomInset)
    }

    public static func boundedOffset(_ offset: Double, within bounds: ClosedRange<Double>) -> Double {
        min(max(offset, bounds.lowerBound), bounds.upperBound)
    }

    public var shouldScrollAutomatically: Bool { followingOutput && !readerScrolling }

    /// Call with phase-context geometry, including the final offset before ending a gesture.
    public mutating func phaseChanged(
        scrolling: Bool, offset: Double, nearBottom: Bool,
        bounds: ClosedRange<Double> = (-Double.infinity)...Double.infinity
    ) {
        geometryChanged(offset: offset, nearBottom: nearBottom, bounds: bounds)
        readerScrolling = scrolling
        lastRawOffset = offset
    }

    /// Only actual offset movement during a reader gesture changes the follow preference.
    public mutating func geometryChanged(
        offset: Double, nearBottom: Bool,
        bounds: ClosedRange<Double> = (-Double.infinity)...Double.infinity
    ) {
        if readerScrolling, let lastRawOffset {
            let previous = Self.boundedOffset(lastRawOffset, within: bounds)
            let current = Self.boundedOffset(offset, within: bounds)
            if current < previous { followingOutput = false }
            if current > previous && nearBottom { followingOutput = true }
        }
        lastRawOffset = offset
    }

    /// Inspecting existing content pauses following before its layout can grow.
    public mutating func pauseFollowing() {
        followingOutput = false
        lastRawOffset = nil
    }

    /// Send and Jump to latest explicitly request following without interrupting a gesture.
    public mutating func resumeFollowing() {
        followingOutput = true
        lastRawOffset = nil
    }
}
