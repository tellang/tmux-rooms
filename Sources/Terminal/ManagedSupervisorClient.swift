import Foundation

public protocol ManagedSupervisorRequesting: Sendable {
    func send(_ request: ManagedSupervisorRequest, deadline: Duration) async throws -> ManagedSupervisorResponse
}

public struct ManagedSupervisorClient: ManagedSupervisorRequesting {
    private let journal: ManagedClientJournal
    public init(journal: ManagedClientJournal = .init()) { self.journal = journal }

    public func send(_ request: ManagedSupervisorRequest, deadline: Duration = .seconds(3)) async throws -> ManagedSupervisorResponse {
        guard ManagedNonce.isValid(request.nonce) else { throw ManagedTerminalError.invalidNonce }
        let responseURL = journal.responsesDirectory.appending(path: "\(request.id.uuidString).json")
        if let existing = try decodeIfPresent(responseURL) { return existing }
        try journal.atomicWrite(request, to: journal.requestsDirectory.appending(path: "\(request.id.uuidString).json"))
        let end = ContinuousClock.now.advanced(by: deadline)
        while ContinuousClock.now < end {
            if let response = try decodeIfPresent(responseURL) { return response }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ManagedTerminalError.automation(.timeout)
    }

    private func decodeIfPresent(_ url: URL) throws -> ManagedSupervisorResponse? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ManagedSupervisorResponse.self, from: Data(contentsOf: url))
    }
}
