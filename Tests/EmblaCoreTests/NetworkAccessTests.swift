import Foundation
import Testing

@testable import EmblaCore

@Test func privacyAdmissionWaitsForTheExactUITransitionAndDoesNotMislabelPathStates() throws {
    let access = NetworkAccess(initialState: .unknown)
    #expect(!access.snapshot.localOnly && !access.snapshot.allowsRequests)
    #expect(throws: NetworkAccessFailure.checking) { try access.check() }
    access.updatePath(.satisfied)
    let first = access.snapshot.revision
    #expect(!access.snapshot.allowsRequests && !access.snapshot.localOnly)
    access.updatePath(.unsatisfied)
    access.activateRequests(after: first)
    #expect(access.snapshot.localOnly && !access.snapshot.allowsRequests)
    #expect(throws: NetworkAccessFailure.offline) { try access.check() }
    access.updatePath(.requiresConnection)
    #expect(!access.snapshot.localOnly)
    access.activateRequests(after: access.snapshot.revision)
    try access.check()  // A connection attempt can activate an on-demand path.
    access.updatePath(.satisfied)
    #expect(!access.snapshot.allowsRequests)
    access.activateRequests(after: access.snapshot.revision)
    try access.check()
}

@Test func offlineModelDownloadRejectsBeforeDispatch() async throws {
    let downloader = HTTPAssetDownloader(network: .init(initialState: .unsatisfied))
    await #expect(throws: NetworkAccessFailure.offline) {
        try await downloader.download(from: URL(string: "https://example.invalid/model")!) { _ in
            Issue.record("An offline request must not report downloaded bytes.")
        }
    }
}
