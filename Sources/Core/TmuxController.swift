import Foundation
import Observation

public enum TmuxControllerPhase: Sendable, Hashable {
    case idle
    case refreshing
    case acting
    case reconciling
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingRefresh = false

    public init(socketURL: URL, loader: any TmuxSnapshotLoading, deleter: any TmuxDeleting, initialSnapshot: RoomSnapshot = .noServer) {
        self.socketURL = socketURL
        self.loader = loader
        self.deleter = deleter
        self.snapshot = initialSnapshot
    }

    public func requestRefresh() {
        guard phase == .idle else {
            pendingRefresh = true
            return
        }
        startRefresh()
    }

    @discardableResult
    public func delete(_ token: SessionToken) -> Bool {
        guard phase == .idle || phase == .refreshing else { return false }
        generation += 1
        let actionGeneration = generation
        phase = .acting
        Task { [weak self, deleter] in
            let result = await deleter.delete(token)
            await self?.finishAction(result, generation: actionGeneration)
        }
        return true
    }

    private func startRefresh() {
        phase = .refreshing
        let refreshGeneration = generation
        Task { [weak self, loader, socketURL] in
            let result: Result<RoomSnapshot, Error>
            do { result = .success(try await loader.load(socketURL: socketURL)) }
            catch { result = .failure(error) }
            await self?.finishRefresh(result, generation: refreshGeneration)
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
            await self?.finishReconcile(loaded, generation: actionGeneration)
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
