import Foundation
import Network
import Synchronization

public enum NetworkPathState: String, Sendable {
    case unknown, satisfied, requiresConnection, unsatisfied
}

public enum NetworkAccessFailure: Error, LocalizedError, Sendable, Equatable {
    case offline, checking, connectionRequired, interrupted, requestPaused

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "Unavailable in privacy mode; this operation requires a network connection."
        case .checking:
            return "Checking connectivity. Retry this operation when the connection is ready."
        case .connectionRequired:
            return "A network connection is required. Connect and retry this operation."
        case .interrupted:
            return "The connection changed during this operation. Check its result before retrying."
        case .requestPaused:
            return "Network features were paused for this request. Submit again to use them."
        }
    }
}

/// Admission is synchronous with URLSessionTask.resume; path loss cancels admitted requests.
/// A satisfied path permits an attempt, never certifies that a server is reachable.
public final class NetworkAccess: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let path: NetworkPathState
        public let allowsRequests: Bool
        public let revision: UInt64
        public var localOnly: Bool { path == .unsatisfied }
    }

    public static let shared = NetworkAccess(monitoring: true)
    private struct State {
        var path: NetworkPathState
        var ready: Bool
        var revision: UInt64 = 0
        var requests: [UUID: (URLSessionTask, NetworkRequestLease)] = [:]
        var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]
        var snapshot: Snapshot {
            Snapshot(path: path, allowsRequests: ready, revision: revision)
        }
    }

    private let state: Mutex<State>
    private let monitor: NWPathMonitor?

    /// Explicit injected state for clients/tests without a UI lifecycle. Production uses shared.
    public init(initialState: NetworkPathState) {
        state = Mutex(
            State(
                path: initialState,
                ready: initialState == .satisfied || initialState == .requiresConnection))
        monitor = nil
    }

    private init(monitoring: Bool) {
        state = Mutex(State(path: .unknown, ready: false))
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            let value: NetworkPathState
            switch path.status {
            case .satisfied: value = .satisfied
            case .unsatisfied: value = .unsatisfied
            case .requiresConnection: value = .requiresConnection
            @unknown default: value = .unknown
            }
            self?.updatePath(value)
        }
        monitor?.start(queue: DispatchQueue(label: "EmblaChat.NetworkPath"))
    }

    deinit { monitor?.cancel() }

    public var snapshot: Snapshot { state.withLock { $0.snapshot } }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        let id = UUID()
        let current = state.withLock { value in
            value.observers[id] = observer
            return value.snapshot
        }
        observer(current)
        return id
    }

    public func removeObserver(_ id: UUID) { state.withLock { $0.observers[id] = nil } }

    /// Foreground refresh uses the monitor's path, without sending a third-party probe.
    public func refresh() {
        guard let monitor else { return }
        switch monitor.currentPath.status {
        case .satisfied: updatePath(.satisfied)
        case .unsatisfied: updatePath(.unsatisfied)
        case .requiresConnection: updatePath(.requiresConnection)
        @unknown default: updatePath(.unknown)
        }
    }

    /// Online transitions stay closed until the app removes its privacy indicator.
    public func updatePath(_ path: NetworkPathState) {
        let change = state.withLock {
            value -> (Snapshot, [URLSessionTask], [@Sendable (Snapshot) -> Void])? in
            guard path != value.path else { return nil }
            value.path = path
            value.ready = false
            value.revision += 1
            let failure = Self.failure(for: value.snapshot)
            let tasks = value.requests.values.map { task, lease in
                lease.revoke(failure)
                return task
            }
            value.requests = [:]
            return (value.snapshot, tasks, Array(value.observers.values))
        }
        guard let (snapshot, tasks, observers) = change else { return }
        for task in tasks { task.cancel() }
        for observer in observers { observer(snapshot) }
    }

    /// The UI acknowledges the precise transition after hiding the border; stale acks fail.
    public func activateRequests(after revision: UInt64) {
        let change = state.withLock { value -> (Snapshot, [@Sendable (Snapshot) -> Void])? in
            guard value.path == .satisfied || value.path == .requiresConnection,
                !value.ready, value.revision == revision
            else {
                return nil
            }
            value.ready = true
            value.revision += 1
            return (value.snapshot, Array(value.observers.values))
        }
        if let (snapshot, observers) = change {
            for observer in observers { observer(snapshot) }
        }
    }

    public func check() throws {
        try state.withLock {
            guard $0.ready else { throw Self.failure(for: $0.snapshot) }
        }
    }

    func start(
        _ task: URLSessionTask, registering: (NetworkRequestLease) throws -> Void
    ) throws {
        try state.withLock { value in
            guard value.ready else { throw Self.failure(for: value.snapshot) }
            let lease = NetworkRequestLease()
            try registering(lease)
            value.requests[lease.id] = (task, lease)
            task.resume()
        }
    }

    func finish(_ lease: NetworkRequestLease) {
        state.withLock { $0.requests[lease.id] = nil }
    }

    private static func failure(for snapshot: Snapshot) -> NetworkAccessFailure {
        switch snapshot.path {
        case .unsatisfied: .offline
        case .requiresConnection: .connectionRequired
        case .unknown: .checking
        case .satisfied: snapshot.allowsRequests ? .interrupted : .checking
        }
    }
}

final class NetworkRequestLease: Sendable {
    let id = UUID()
    private let failure = Mutex<NetworkAccessFailure?>(nil)
    func revoke(_ error: NetworkAccessFailure) { failure.withLock { $0 = error } }
    func check() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }
}
