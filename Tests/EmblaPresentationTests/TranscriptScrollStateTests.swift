import Testing
@testable import EmblaPresentation

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
