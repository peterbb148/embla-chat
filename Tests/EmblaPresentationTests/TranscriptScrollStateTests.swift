import Testing

@testable import EmblaPresentation

@Test func toolAndAnswerGrowthOnlyFollowAfterOverflow() {
    let state = TranscriptScrollState()
    let viewportHeight = 700.0
    for contentHeight in [90.0, 250, 460, 700] {
        let bounds = TranscriptScrollState.scrollBounds(
            contentHeight: contentHeight, viewportHeight: viewportHeight)
        #expect(!state.needsBottomAlignment(offset: 0, bounds: bounds))
    }

    let overflowing = TranscriptScrollState.scrollBounds(
        contentHeight: 750, viewportHeight: viewportHeight)
    #expect(state.needsBottomAlignment(offset: 0, bounds: overflowing))
    #expect(!state.needsBottomAlignment(offset: 49.5, bounds: overflowing))
    #expect(!state.needsBottomAlignment(offset: 52, bounds: overflowing))
}

@Test func growthDoesNotMoveTranscriptDuringAHoldOrToolInspection() {
    var state = TranscriptScrollState()
    let bounds = 0.0...650.0
    state.phaseChanged(scrolling: true, offset: 200, nearBottom: false, bounds: bounds)
    #expect(!state.needsBottomAlignment(offset: 200, bounds: bounds))

    state.phaseChanged(scrolling: false, offset: 200, nearBottom: false, bounds: bounds)
    #expect(state.needsBottomAlignment(offset: 200, bounds: bounds))

    state.pauseFollowing()
    #expect(!state.needsBottomAlignment(offset: 200, bounds: bounds))
}
@Test func holdingTranscriptWhileOutputGrowsDoesNotDisableFollowing() {
    var state = TranscriptScrollState()
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true)
    state.geometryChanged(offset: 500, nearBottom: false)
    #expect(state.followingOutput)
    #expect(!state.shouldScrollAutomatically)
    state.phaseChanged(scrolling: false, offset: 500, nearBottom: false)
    #expect(state.shouldScrollAutomatically)
}

@Test func draggingUpPausesImmediatelyAndReturningToBottomResumesAfterGesture() {
    var state = TranscriptScrollState()
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true)
    state.phaseChanged(scrolling: true, offset: 480, nearBottom: true)
    #expect(!state.followingOutput)
    state.geometryChanged(offset: 400, nearBottom: false)
    state.phaseChanged(scrolling: false, offset: 350, nearBottom: false)
    #expect(!state.shouldScrollAutomatically)
    state.phaseChanged(scrolling: true, offset: 350, nearBottom: false)
    state.geometryChanged(offset: 450, nearBottom: false)
    #expect(!state.followingOutput)
    state.geometryChanged(offset: 700, nearBottom: true)
    #expect(state.followingOutput)
    #expect(!state.shouldScrollAutomatically)
    state.phaseChanged(scrolling: false, offset: 700, nearBottom: true)
    #expect(state.shouldScrollAutomatically)
}

@Test func explicitFollowResumesAfterAScrollWithoutDependingOnContentChanges() {
    var state = TranscriptScrollState()
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true)
    state.phaseChanged(scrolling: false, offset: 200, nearBottom: false)
    #expect(!state.shouldScrollAutomatically)
    state.resumeFollowing()
    #expect(state.shouldScrollAutomatically)
    state = TranscriptScrollState()
    #expect(state.shouldScrollAutomatically)
}

@Test func bottomRubberBandRecoveryDoesNotLookLikeAnUpwardDrag() {
    let bounds = TranscriptScrollState.scrollBounds(contentHeight: 900, viewportHeight: 400)
    var state = TranscriptScrollState()
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true, bounds: bounds)
    state.geometryChanged(offset: 540, nearBottom: true, bounds: bounds)
    state.geometryChanged(offset: 500, nearBottom: true, bounds: bounds)
    state.phaseChanged(scrolling: false, offset: 500, nearBottom: true, bounds: bounds)
    #expect(state.shouldScrollAutomatically)
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true, bounds: bounds)
    state.geometryChanged(offset: 480, nearBottom: true, bounds: bounds)
    #expect(!state.followingOutput)
    let short = TranscriptScrollState.scrollBounds(
        contentHeight: 100, viewportHeight: 400, topInset: 20)
    #expect(TranscriptScrollState.boundedOffset(-100, within: short) == -20)
}

@Test func shrinkingContentDuringAHoldUsesCurrentBoundsForBothOffsets() {
    let oldBounds = TranscriptScrollState.scrollBounds(contentHeight: 900, viewportHeight: 400)
    let newBounds = TranscriptScrollState.scrollBounds(contentHeight: 860, viewportHeight: 400)
    var state = TranscriptScrollState()
    state.phaseChanged(scrolling: true, offset: 500, nearBottom: true, bounds: oldBounds)
    state.geometryChanged(offset: 500, nearBottom: true, bounds: newBounds)
    #expect(state.followingOutput)
    state.phaseChanged(scrolling: false, offset: 460, nearBottom: true, bounds: newBounds)
    #expect(state.shouldScrollAutomatically)
    state.phaseChanged(scrolling: true, offset: 460, nearBottom: true, bounds: newBounds)
    state.geometryChanged(offset: 450, nearBottom: true, bounds: newBounds)
    #expect(!state.followingOutput)
}

@Test func inspectingExpandedContentPausesFollowingUntilExplicitResume() {
    var state = TranscriptScrollState()
    state.geometryChanged(offset: 0, nearBottom: true)
    state.pauseFollowing()
    // A tall result grows below the current position without a reader scroll gesture.
    state.geometryChanged(offset: 0, nearBottom: false)
    state.phaseChanged(scrolling: false, offset: 0, nearBottom: false)
    #expect(!state.followingOutput && !state.shouldScrollAutomatically)
    state.resumeFollowing()
    #expect(state.shouldScrollAutomatically)
}
