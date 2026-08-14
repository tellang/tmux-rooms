import Foundation
import Observation

public enum TmuxControllerPhase: Sendable, Hashable {
    case idle
    case refreshing
    case acting
    case reconciling
}

public enum TmuxOpenRoute: Sendable, Hashable {
    case detached
    case sole(ClientKey)
    case chosen(ClientKey)
}

public struct TerminalActionPolling: Sendable, Hashable {
    public let interval: Duration
    public let deadline: Duration

    public init(interval: Duration = .milliseconds(100), deadline: Duration = .seconds(5)) {
        self.interval = interval
        self.deadline = deadline
    }
}

@MainActor
@Observable
public final class TmuxController {
    public private(set) var snapshot: RoomSnapshot
    public private(set) var phase: TmuxControllerPhase = .idle
    public private(set) var refreshError: TmuxFailure?
    public private(set) var lastActionResult: RoomActionResult?

    @ObservationIgnored private let socketURL: URL
    @ObservationIgnored private let loader: any TmuxSnapshotLoading
    @ObservationIgnored private let deleter: any TmuxDeleting
    @ObservationIgnored private let terminal: (any TerminalControlling)?
    @ObservationIgnored private let terminalPolling: TerminalActionPolling
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingRefresh = false

    public init(
        socketURL: URL,
        loader: any TmuxSnapshotLoading,
        deleter: any TmuxDeleting,
        terminal: (any TerminalControlling)? = nil,
        terminalPolling: TerminalActionPolling = .init(),
        initialSnapshot: RoomSnapshot = .noServer
    ) {
        self.socketURL = socketURL
        self.loader = loader
        self.deleter = deleter
        self.terminal = terminal
        self.terminalPolling = terminalPolling
        self.snapshot = initialSnapshot
    }

    public func requestRefresh() {
        guard phase == .idle else {
            pendingRefresh = true
            return
        }
        startRefresh()
    }

    public func focusableClientKeys() async -> Set<ClientKey> {
        guard let terminal else { return [] }
        return (try? await terminal.focusableClientKeys(snapshot: snapshot)) ?? []
    }

    @discardableResult
    public func delete(_ token: SessionToken) -> Bool {
        guard phase == .idle || phase == .refreshing else { return false }
        generation += 1
        let actionGeneration = generation
        phase = .acting
        Task { [weak self, deleter] in
            let result = await deleter.delete(token)
            self?.finishAction(result, generation: actionGeneration)
        }
        return true
    }

    @discardableResult
    public func open(_ token: SessionToken, route: TmuxOpenRoute, softDeadline: Duration = .seconds(5)) -> Bool {
        startTerminalAction(token: token, softDeadline: softDeadline) { terminal, room, fresh in
            let interactive = room.interactiveClients
            switch route {
            case .detached:
                guard interactive.isEmpty else { return .final(.staleTarget) }
                return Self.managedProgress(
                    try await terminal.ensureManaged(role: .primary, destination: token, readOnly: false, snapshot: fresh, softDeadline: softDeadline),
                    focusWhenReady: true
                )
            case .sole(let clientKey):
                guard interactive.count == 1, interactive[0].key == clientKey else { return .final(.staleTarget) }
                _ = try await terminal.focus(clientKey: clientKey, snapshot: fresh)
                return .final(.succeeded)
            case .chosen(let clientKey):
                guard interactive.count >= 2, interactive.contains(where: { $0.key == clientKey }) else { return .final(.staleTarget) }
                _ = try await terminal.focus(clientKey: clientKey, snapshot: fresh)
                return .final(.succeeded)
            }
        }
    }

    @discardableResult
    public func preview(_ token: SessionToken, softDeadline: Duration = .seconds(5)) -> Bool {
        startTerminalAction(token: token, softDeadline: softDeadline) { terminal, _, fresh in
            Self.managedProgress(
                try await terminal.ensureManaged(role: .preview, destination: token, readOnly: true, snapshot: fresh, softDeadline: softDeadline),
                focusWhenReady: true
            )
        }
    }

    @discardableResult
    public func duplicateWindow(_ token: SessionToken, softDeadline: Duration = .seconds(5)) -> Bool {
        startTerminalAction(token: token, softDeadline: softDeadline) { terminal, _, fresh in
            Self.managedProgress(
                try await terminal.launchDuplicate(destination: token, readOnly: false, snapshot: fresh, softDeadline: softDeadline),
                focusWhenReady: false
            )
        }
    }

    private func startRefresh() {
        phase = .refreshing
        let refreshGeneration = generation
        Task { [weak self, loader, socketURL] in
            let result: Result<RoomSnapshot, Error>
            do { result = .success(try await loader.load(socketURL: socketURL)) }
            catch { result = .failure(error) }
            self?.finishRefresh(result, generation: refreshGeneration)
        }
    }

    // UI actions own one generation from fresh route validation through terminal work
    // and the post-action snapshot. Refresh ticks coalesce behind that whole flight.
    private func startTerminalAction(
        token: SessionToken,
        softDeadline: Duration,
        operation: @escaping @MainActor (any TerminalControlling, SessionRoom, RoomSnapshot) async throws -> TerminalActionProgress
    ) -> Bool {
        guard phase == .idle || phase == .refreshing else { return false }
        guard let terminal else {
            lastActionResult = .terminalFailure(.invalidReply)
            return false
        }
        generation += 1
        let actionGeneration = generation
        phase = .acting
        Task { [weak self, loader, socketURL, terminal] in
            let progress: TerminalActionProgress
            do {
                let fresh = try await loader.load(socketURL: socketURL)
                guard let room = fresh.rooms.first(where: { $0.token == token }) else {
                    self?.finishTerminalAction(.final(.staleTarget), terminal: terminal, generation: actionGeneration)
                    return
                }
                progress = try await operation(terminal, room, fresh)
            } catch {
                progress = .final(Self.roomFailure(error))
            }
            self?.finishTerminalAction(progress, terminal: terminal, generation: actionGeneration)
        }
        return true
    }

    private func finishTerminalAction(_ progress: TerminalActionProgress, terminal: any TerminalControlling, generation actionGeneration: Int) {
        guard generation == actionGeneration, phase == .acting else { return }
        phase = .reconciling
        let polling = terminalPolling
        Task { [weak self, loader, socketURL, terminal, polling] in
            do {
                let snapshot = try await loader.load(socketURL: socketURL)
                let result: RoomActionResult
                do {
                    switch progress {
                    case .final(let final):
                        if final == .succeeded {
                            _ = try await terminal.reconcile(snapshot: snapshot)
                        }
                        result = final
                    case let .managed(nonce, focusWhenReady):
                        let initial = try await Self.resolveManaged(nonce: nonce, focusWhenReady: focusWhenReady, terminal: terminal, snapshot: snapshot)
                        if initial == .terminalFailure(.operationPending) {
                            await terminal.waitForPendingOperation(nonce: nonce)
                            let polled = try await Self.pollManagedResolution(
                                nonce: nonce,
                                focusWhenReady: focusWhenReady,
                                terminal: terminal,
                                loader: loader,
                                socketURL: socketURL,
                                policy: polling
                            )
                            self?.finishTerminalReconcile(.success(polled.snapshot), result: polled.result, generation: actionGeneration)
                            return
                        }
                        result = initial
                    }
                } catch {
                    result = Self.roomFailure(error)
                }
                self?.finishTerminalReconcile(.success(snapshot), result: result, generation: actionGeneration)
            } catch {
                self?.finishTerminalReconcile(.failure(error), result: Self.roomFailure(error), generation: actionGeneration)
            }
        }
    }

    private func finishTerminalReconcile(_ loaded: Result<RoomSnapshot, Error>, result: RoomActionResult, generation actionGeneration: Int) {
        guard generation == actionGeneration, phase == .reconciling else { return }
        lastActionResult = result
        publish(loaded)
        phase = .idle
        startPendingRefreshIfNeeded()
    }

    private static func managedProgress(_ outcome: ManagedTerminalOutcome, focusWhenReady: Bool) -> TerminalActionProgress {
        switch outcome {
        case .ready(let record):
            return .managed(nonce: record.nonce, focusWhenReady: focusWhenReady)
        case .pending(let record):
            return .managed(nonce: record.nonce, focusWhenReady: focusWhenReady)
        case .failed:
            return .final(.terminalFailure(.notFound))
        case .ambiguous:
            return .final(.terminalFailure(.ambiguous))
        }
    }

    private static func resolveManaged(
        nonce: String,
        focusWhenReady: Bool,
        terminal: any TerminalControlling,
        snapshot: RoomSnapshot
    ) async throws -> RoomActionResult {
        let records = try await terminal.reconcile(snapshot: snapshot)
        guard let record = records.first(where: { $0.nonce == nonce }) else {
            return .terminalFailure(.notFound)
        }
        switch record.state {
        case .complete, .recovered:
            if focusWhenReady, let key = record.liveClientKey {
                _ = try await terminal.focus(clientKey: key, snapshot: snapshot)
            }
            return .succeeded
        case .ambiguous:
            return .terminalFailure(.ambiguous)
        case .failed:
            return .terminalFailure(.notFound)
        case .provisional, .launching, .timedOutButRunning, .completedNeedsReconcile:
            return .terminalFailure(.operationPending)
        }
    }

    private static func pollManagedResolution(
        nonce: String,
        focusWhenReady: Bool,
        terminal: any TerminalControlling,
        loader: any TmuxSnapshotLoading,
        socketURL: URL,
        policy: TerminalActionPolling
    ) async throws -> (snapshot: RoomSnapshot, result: RoomActionResult) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.deadline)
        var latest = try await loader.load(socketURL: socketURL)
        var result = try await resolveManaged(nonce: nonce, focusWhenReady: focusWhenReady, terminal: terminal, snapshot: latest)
        while result == .terminalFailure(.operationPending), clock.now < deadline {
            try await Task.sleep(for: policy.interval)
            latest = try await loader.load(socketURL: socketURL)
            result = try await resolveManaged(nonce: nonce, focusWhenReady: focusWhenReady, terminal: terminal, snapshot: latest)
        }
        return (latest, result)
    }

    private static func roomFailure(_ error: Error) -> RoomActionResult {
        if let failure = error as? TmuxFailure { return .tmuxFailure(failure) }
        guard let failure = error as? ManagedTerminalError else {
            return .terminalFailure(.invalidReply)
        }
        switch failure {
        case .automation(let automation):
            switch automation {
            case .permissionDenied: return .terminalFailure(.permissionDenied)
            case .timeout: return .terminalFailure(.timeout)
            case .staleTarget: return .terminalFailure(.staleTarget)
            case .notFound: return .terminalFailure(.notFound)
            case .ambiguous: return .terminalFailure(.ambiguous)
            case .activationNotVerified, .invalidReply: return .terminalFailure(.invalidReply)
            case .scriptFailure(let number): return .terminalFailure(.scriptFailure(number: number))
            }
        case .notFound: return .terminalFailure(.notFound)
        case .ambiguous: return .terminalFailure(.ambiguous)
        case .staleOwnership: return .terminalFailure(.staleTarget)
        case .invalidNonce, .invalidRecord, .journal, .corruptRecord: return .terminalFailure(.invalidReply)
        }
    }

    private func finishRefresh(_ result: Result<RoomSnapshot, Error>, generation refreshGeneration: Int) {
        guard generation == refreshGeneration, phase == .refreshing else { return }
        publish(result)
        phase = .idle
        startPendingRefreshIfNeeded()
    }

    private func finishAction(_ result: RoomActionResult, generation actionGeneration: Int) {
        guard generation == actionGeneration, phase == .acting else { return }
        lastActionResult = result
        phase = .reconciling
        Task { [weak self, loader, socketURL] in
            let loaded: Result<RoomSnapshot, Error>
            do { loaded = .success(try await loader.load(socketURL: socketURL)) }
            catch { loaded = .failure(error) }
            self?.finishReconcile(loaded, generation: actionGeneration)
        }
    }

    private func finishReconcile(_ result: Result<RoomSnapshot, Error>, generation actionGeneration: Int) {
        guard generation == actionGeneration, phase == .reconciling else { return }
        publish(result)
        phase = .idle
        startPendingRefreshIfNeeded()
    }

    private func publish(_ result: Result<RoomSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            refreshError = nil
        case .failure(let error):
            refreshError = (error as? TmuxFailure) ?? .launchFailed(String(describing: error))
        }
    }

    private func startPendingRefreshIfNeeded() {
        guard pendingRefresh else { return }
        pendingRefresh = false
        startRefresh()
    }
}

private enum TerminalActionProgress: Sendable {
    case final(RoomActionResult)
    case managed(nonce: String, focusWhenReady: Bool)
}
