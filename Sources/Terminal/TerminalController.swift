import Foundation
import OSLog

@MainActor
public protocol TerminalControlling: Sendable {
    func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome
    func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome
    func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult
    func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord]
    func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey>
    func waitForPendingOperation(nonce: String) async
}

@MainActor
public final class TerminalController: TerminalControlling {
    private let automation: any ManagedITermAutomating
    private let journal: ManagedClientJournal
    private let tmuxExecutablePath: String
    private let supervisorClient: any ManagedSupervisorRequesting
    private let liveness: any ProcessLivenessProbing
    private let lateFailureHandler: @MainActor @Sendable (String) -> Void
    private var launches: [String: Task<Result<ManagedTerminalReference, SmokeAutomationError>, Never>] = [:]
    private var lateCompletions: [String: Task<Void, Never>] = [:]

    public init(automation: any ManagedITermAutomating = ITermManagedAutomation(), journal: ManagedClientJournal = .init(), tmuxExecutablePath: String = "/opt/homebrew/bin/tmux", supervisorClient: (any ManagedSupervisorRequesting)? = nil, liveness: any ProcessLivenessProbing = POSIXProcessLiveness(), lateFailureHandler: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.automation = automation; self.journal = journal; self.tmuxExecutablePath = tmuxExecutablePath
        self.supervisorClient = supervisorClient ?? ManagedSupervisorClient(journal: journal)
        self.liveness = liveness
        self.lateFailureHandler = lateFailureHandler ?? { message in Logger(subsystem: "com.tellang.tmuxrooms", category: "terminal").error("\(message, privacy: .public)") }
    }

    public func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration = .seconds(5)) async throws -> ManagedTerminalOutcome {
        let readOnly = role == .preview ? true : readOnly
        let unassigned = try journal.allRecords().filter { $0.launchKind == .reusableRole && $0.role == nil }
        if !unassigned.isEmpty {
            return .ambiguous(unassigned + (try journal.reusableRecords(role: role)))
        }
        var candidates = try journal.reusableRecords(role: role)
        guard !candidates.isEmpty else {
            return try await launch(kind: .reusableRole, role: role, destination: destination, readOnly: readOnly, snapshot: snapshot, deadline: softDeadline)
        }
        if candidates.count > 1 || candidates.contains(where: { $0.state == .ambiguous }) { return .ambiguous(candidates) }
        guard let candidate = candidates.first else { throw ManagedTerminalError.invalidRecord }
        if candidate.state == .failed { return .failed(candidate) }
        if candidate.pendingSwitch == nil, [.launching, .timedOutButRunning, .provisional].contains(candidate.state) {
            return .pending(candidate)
        }
        _ = try await reconcile(snapshot: snapshot)
        candidates = try journal.reusableRecords(role: role)
        guard candidates.count == 1, let existing = candidates.first else { return .ambiguous(candidates) }
        if existing.state == .ambiguous { return .ambiguous(candidates) }
        if existing.state == .failed { return .failed(existing) }
        if existing.pendingSwitch != nil { return .pending(existing) }
        if [.launching, .timedOutButRunning, .completedNeedsReconcile, .provisional].contains(existing.state) { return .pending(existing) }
        guard existing.state == .complete || existing.state == .recovered else { return .pending(existing) }

        if existing.requestedSessionToken == destination, existing.readOnly == readOnly,
           let key = existing.liveClientKey, snapshot.rooms.flatMap(\.clients).contains(where: { $0.key == key }) { return .ready(existing) }
        let request = ManagedSupervisorRequest(nonce: existing.nonce, action: .switchSession(destination, readOnly: readOnly))
        let intent = ManagedSwitchIntent(requestID: request.id, destination: destination, readOnly: readOnly, previousSessionToken: existing.requestedSessionToken, previousReadOnly: existing.readOnly, previousChildPID: existing.childPID, previousLiveClientKey: existing.liveClientKey, previousState: existing.state)
        var switching = existing
        switching.pendingSwitch = intent; switching.requestID = request.id; switching.state = .launching; switching.updatedAt = Date()
        switching.pendingPreviewTitle = role == .preview ? Self.previewTitle(
            roomName: snapshot.rooms.first(where: { $0.token == destination })?.name ?? destination.sessionID
        ) : nil
        try journal.write(switching)
        let response = try await supervisorClient.send(request, deadline: .seconds(3))
        guard response.status == .completed else {
            let rejected = resolveRejectedSwitch(intent: intent, response: response, record: switching)
            try journal.write(rejected)
            return rejected.state == .failed ? .failed(rejected) : .pending(rejected)
        }
        var switched = switching
        switched.requestedSessionToken = destination; switched.readOnly = readOnly; switched.childPID = response.childPID
        switched.liveClientKey = nil; switched.state = .completedNeedsReconcile; switched.updatedAt = Date()
        try journal.write(switched)
        return .pending(switched)
    }

    public func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration = .seconds(5)) async throws -> ManagedTerminalOutcome {
        let unresolvedStates: [ManagedRecordState] = [.provisional, .launching, .timedOutButRunning, .completedNeedsReconcile, .ambiguous]
        let unresolved = try journal.allRecords().filter {
            $0.launchKind == .explicitDuplicate
                && $0.requestedSessionToken == destination
                && $0.readOnly == readOnly
                && unresolvedStates.contains($0.state)
        }
        if unresolved.count > 1 || unresolved.contains(where: { $0.state == .ambiguous }) {
            return .ambiguous(unresolved)
        }
        if let pending = unresolved.first {
            return .pending(pending)
        }
        return try await launch(kind: .explicitDuplicate, role: nil, destination: destination, readOnly: readOnly, snapshot: snapshot, deadline: softDeadline)
    }

    public func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult {
        _ = try await reconcile(snapshot: snapshot)
        let matches = try journal.allRecords().filter { $0.liveClientKey == clientKey && ($0.state == .complete || $0.state == .recovered) }
        if matches.isEmpty {
            guard snapshot.rooms.flatMap(\.clients).contains(where: { $0.key == clientKey }), let tty = clientKey.tty else { throw ManagedTerminalError.notFound }
            let references: [ManagedTerminalReference]
            switch await automation.enumerateSessions() { case let .success(value): references = value; case let .failure(error): throw ManagedTerminalError.automation(error) }
            let exact = references.filter { $0.tty == tty }
            guard exact.count == 1, let reference = exact.first else { throw exact.count > 1 ? ManagedTerminalError.ambiguous : ManagedTerminalError.notFound }
            switch await automation.focusExactSession(reference) { case .success: return .external(reference: reference, clientKey: clientKey); case let .failure(error): throw ManagedTerminalError.automation(error) }
        }
        guard matches.count == 1, let record = matches.first, let terminal = record.terminal else { throw matches.count > 1 ? ManagedTerminalError.ambiguous : ManagedTerminalError.notFound }
        switch await automation.focusManagedSession(terminal, nonce: record.nonce) {
        case .success: return .managed(record)
        case let .failure(error): throw ManagedTerminalError.automation(error)
        }
    }

    public func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey> {
        let records = try await reconcile(snapshot: snapshot)
        let managed: Set<ClientKey> = Set(records.compactMap { record -> ClientKey? in
            guard record.state == .complete || record.state == .recovered else { return nil }
            return record.liveClientKey
        })
        let references: [ManagedTerminalReference]
        switch await automation.enumerateSessions() {
        case let .success(value): references = value
        case let .failure(error): throw ManagedTerminalError.automation(error)
        }
        let ttyCounts = Dictionary(grouping: references, by: \.tty).mapValues(\.count)
        let local = snapshot.rooms.flatMap(\.interactiveClients).compactMap { client -> ClientKey? in
            guard let tty = client.tty, ttyCounts[tty] == 1 else { return nil }
            return client.key
        }
        return managed.union(local)
    }

    public func waitForPendingOperation(nonce: String) async {
        // The action soft deadline never cancels Automation. Its fixed AppleScript timeout
        // remains the hard bound; this task completes only after the durable late absorb.
        if let completion = lateCompletions[nonce] {
            await completion.value
        }
    }

    public func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord] {
        let evidence: [ManagedSessionEvidence]
        switch await automation.enumerateManagedSessions() {
        case let .success(value): evidence = value
        case let .failure(error): throw ManagedTerminalError.automation(error)
        }
        var reconciled: [ManagedClientRecord] = []
        for record in try journal.allRecords() {
            let recovered = try recoverPendingSwitch(record)
            if recovered.unresolved { reconciled.append(recovered.record); continue }
            var withHandshake = recovered.record
            if let handshake = try journal.readHandshake(nonce: record.nonce), handshake.destination == withHandshake.requestedSessionToken, handshake.readOnly == withHandshake.readOnly {
                withHandshake.supervisorPID = handshake.supervisorPID; withHandshake.childPID = handshake.childPID
                withHandshake.configurationState = .handshakeObserved
            }
            var resolved = try reconcile(withHandshake, evidence: evidence, snapshot: snapshot)
            if let title = resolved.pendingPreviewTitle,
               resolved.state == .complete || resolved.state == .recovered,
               let terminal = resolved.terminal {
                switch await automation.setManagedSessionTitle(terminal, nonce: resolved.nonce, title: title) {
                case .success:
                    resolved.pendingPreviewTitle = nil
                    resolved.updatedAt = Date()
                    try journal.write(resolved)
                case let .failure(error):
                    Logger(subsystem: "com.tellang.tmuxrooms", category: "terminal")
                        .error("Preview title remains pending for \(resolved.nonce, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            reconciled.append(resolved)
        }
        return reconciled
    }

    public func managedRecoveryCandidates(snapshot: RoomSnapshot) async throws -> [ManagedRecoveryCandidate] {
        let records = try await reconcile(snapshot: snapshot).filter { $0.launchKind == .reusableRole }
        let roleCounts = Dictionary(grouping: records.compactMap(\.role), by: { $0 }).mapValues(\.count)
        return records.filter { record in
            record.role == nil
                || record.state != .complete && record.state != .recovered
                || record.role.map { roleCounts[$0, default: 0] > 1 } == true
        }.map { record in
            ManagedRecoveryCandidate(
                record: record,
                roomName: snapshot.rooms.first(where: { $0.token == record.requestedSessionToken })?.name ?? "Unavailable room"
            )
        }.sorted { $0.nonce < $1.nonce }
    }

    public func resolveManagedCandidate(nonce: String, as role: ManagedRole, snapshot: RoomSnapshot) async throws -> [ManagedRecoveryCandidate] {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        let records = try await reconcile(snapshot: snapshot)
        guard var selected = records.first(where: { $0.nonce == nonce }), selected.launchKind == .reusableRole else {
            throw ManagedTerminalError.staleOwnership
        }
        guard selected.state == .complete || selected.state == .recovered,
              selected.terminal != nil,
              selected.liveClientKey != nil,
              snapshot.rooms.contains(where: { $0.token == selected.requestedSessionToken }),
              selected.readOnly == (role == .preview) else {
            throw ManagedTerminalError.staleOwnership
        }

        if role == .preview, let terminal = selected.terminal {
            let title = Self.previewTitle(roomName: snapshot.rooms.first(where: { $0.token == selected.requestedSessionToken })?.name ?? selected.requestedSessionToken.sessionID)
            selected.pendingPreviewTitle = title
            selected.updatedAt = Date()
            try journal.write(selected)
            switch await automation.setManagedSessionTitle(terminal, nonce: selected.nonce, title: title) {
            case .success: selected.pendingPreviewTitle = nil
            case let .failure(error):
                Logger(subsystem: "com.tellang.tmuxrooms", category: "terminal")
                    .error("Preview title remains pending for \(selected.nonce, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for var conflict in records where conflict.launchKind == .reusableRole && conflict.nonce != nonce && conflict.role == role {
            conflict.role = nil
            conflict.state = .ambiguous
            conflict.updatedAt = Date()
            try journal.write(conflict)
        }
        selected.role = role
        selected.state = .complete
        selected.updatedAt = Date()
        try journal.write(selected)
        return try await managedRecoveryCandidates(snapshot: snapshot)
    }

    public func cleanUpManagedCandidate(nonce: String, snapshot: RoomSnapshot) async throws -> [ManagedRecoveryCandidate] {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        let records = try await reconcile(snapshot: snapshot)
        guard let record = records.first(where: { $0.nonce == nonce }), record.launchKind == .reusableRole else {
            throw ManagedTerminalError.staleOwnership
        }
        let handshake = try journal.readHandshake(nonce: nonce)
        // A record keeps naming its supervisor, child, and iTerm session long
        // after all three are gone — the tmux server restarts, the terminal
        // quits, the machine reboots — and reconcile() re-reads those same PIDs
        // out of the handshake on every pass. Ownership therefore has to be
        // proven by live processes and a live client, never by the mere
        // presence of those fields: otherwise cleanup mails a detach request to
        // a supervisor that cannot answer, times out, leaves the record in
        // place, and the recovery panel has no exit at all.
        let supervisorGone = record.supervisorPID.map { liveness.isDefinitelyDead($0) } ?? true
        let childGone = record.childPID.map { liveness.isDefinitelyDead($0) } ?? true
        let handshakeGone = handshake.map {
            liveness.isDefinitelyDead($0.supervisorPID) && liveness.isDefinitelyDead($0.childPID)
        } ?? true
        let clientAttached = record.liveClientKey.map { key in
            snapshot.rooms.contains { $0.clients.contains { $0.key == key } }
        } ?? false
        let provenDead = (record.state == .provisional || record.state == .failed)
            && supervisorGone && childGone && handshakeGone && !clientAttached
            && launches[nonce] == nil && lateCompletions[nonce] == nil
        if provenDead {
            try journal.retire(record)
            return try await managedRecoveryCandidates(snapshot: snapshot)
        }
        guard handshake?.nonce == nonce || record.supervisorPID != nil else {
            throw ManagedTerminalError.staleOwnership
        }
        let request = ManagedSupervisorRequest(nonce: nonce, action: .detach)
        let response = try await supervisorClient.send(request, deadline: .seconds(3))
        guard response.requestID == request.id, response.status == .completed, response.childPID == nil else {
            throw ManagedTerminalError.staleOwnership
        }
        try journal.retire(record, finalRequestID: request.id)
        return try await managedRecoveryCandidates(snapshot: snapshot)
    }

    private func launch(kind: ManagedLaunchKind, role: ManagedRole?, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, deadline: Duration) async throws -> ManagedTerminalOutcome {
        let nonce = ManagedNonce.generate()
        let previewTitle = role == .preview ? Self.previewTitle(
            roomName: snapshot.rooms.first(where: { $0.token == destination })?.name ?? destination.sessionID
        ) : nil
        var record = ManagedClientRecord(
            nonce: nonce,
            launchKind: kind,
            role: role,
            requestedSessionToken: destination,
            readOnly: readOnly,
            pendingPreviewTitle: previewTitle
        )
        try journal.write(record)
        try journal.writeConfiguration(.init(nonce: nonce, tmuxExecutablePath: tmuxExecutablePath, destination: destination, readOnly: readOnly))
        record.configurationState = .written; record.state = .launching; record.updatedAt = Date(); try journal.write(record)

        let task = Task { @MainActor [automation] in await automation.createManagedSession(nonce: nonce) }
        launches[nonce] = task
        let completed = await wait(task, deadline: deadline)
        if let completed {
            launches[nonce] = nil
            return try absorb(completed, nonce: nonce, snapshot: snapshot)
        }
        record.state = .timedOutButRunning; record.updatedAt = Date(); try journal.write(record)
        let lateCompletion = Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            self.launches[nonce] = nil
            do { _ = try self.absorb(result, nonce: nonce, snapshot: snapshot) }
            catch {
                let message = "Late Automation absorption failed for \(nonce): \(String(describing: error))"
                self.persistLateFailure(nonce: nonce, message: message)
                self.lateFailureHandler(message)
            }
            self.lateCompletions[nonce] = nil
        }
        lateCompletions[nonce] = lateCompletion
        return .pending(record)
    }

    private func wait(_ task: Task<Result<ManagedTerminalReference, SmokeAutomationError>, Never>, deadline: Duration) async -> Result<ManagedTerminalReference, SmokeAutomationError>? {
        await withCheckedContinuation { continuation in
            let race = ContinuationRace(continuation)
            Task { @MainActor in race.finish(await task.value) }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                race.finish(nil)
            }
        }
    }

    private func absorb(_ result: Result<ManagedTerminalReference, SmokeAutomationError>, nonce: String, snapshot: RoomSnapshot) throws -> ManagedTerminalOutcome {
        guard var record = try journal.read(nonce: nonce) else { throw ManagedTerminalError.invalidRecord }
        switch result {
        case let .failure(error):
            record.state = .failed; record.updatedAt = Date(); try journal.write(record)
            throw ManagedTerminalError.automation(error)
        case let .success(reference):
            let priorState = record.state
            record.terminal = reference; record.state = .completedNeedsReconcile; record.updatedAt = Date(); try journal.write(record)
            let evidence = [ManagedSessionEvidence(terminal: reference, nonce: nonce)]
            if priorState == .timedOutButRunning { record.state = .timedOutButRunning }
            let resolved = try reconcile(record, evidence: evidence, snapshot: snapshot)
            return resolved.state == .complete || resolved.state == .recovered ? .ready(resolved) : .pending(resolved)
        }
    }

    private func reconcile(_ original: ManagedClientRecord, evidence: [ManagedSessionEvidence], snapshot: RoomSnapshot) throws -> ManagedClientRecord {
        var record = original
        let terminalMatches = evidence.filter { $0.nonce == record.nonce }
        guard terminalMatches.count == 1 else {
            if terminalMatches.count > 1 { record.state = .ambiguous; record.updatedAt = Date(); try journal.write(record) }
            else if record.state == .complete || record.state == .recovered { record.state = .failed; record.updatedAt = Date(); try journal.write(record) }
            return record
        }
        let observedTerminal = terminalMatches[0].terminal
        if let terminal = record.terminal, terminal != observedTerminal { record.state = .ambiguous; record.updatedAt = Date(); try journal.write(record); return record }
        record.terminal = observedTerminal
        guard original.state != .failed else { return record }
        let room = snapshot.rooms.first { $0.token == record.requestedSessionToken }
        let clients = (room?.clients ?? []).filter { $0.key.tty == observedTerminal.tty && $0.isReadOnly == record.readOnly }
        let exact = record.liveClientKey.map { key in clients.filter { $0.key == key } } ?? clients
        guard exact.count == 1 else {
            if exact.count > 1 { record.state = .ambiguous; record.updatedAt = Date(); try journal.write(record) }
            else if record.state == .provisional || record.state == .launching { record.state = .completedNeedsReconcile; record.updatedAt = Date(); try journal.write(record) }
            else if record.state == .complete || record.state == .recovered { record.state = .failed; record.updatedAt = Date(); try journal.write(record) }
            return record
        }
        record.liveClientKey = exact[0].key
        record.pendingSwitch = nil
        record.configurationState = .handshakeObserved
        record.state = [.timedOutButRunning, .launching, .provisional].contains(original.state) ? .recovered : .complete
        record.updatedAt = Date(); try journal.write(record)
        return record
    }

    private func recoverPendingSwitch(_ original: ManagedClientRecord) throws -> (record: ManagedClientRecord, unresolved: Bool) {
        guard let intent = original.pendingSwitch else { return (original, false) }
        var record = original
        if record.requestedSessionToken == intent.destination, record.readOnly == intent.readOnly, record.state == .completedNeedsReconcile { return (record, false) }
        let response = try journal.readResponse(requestID: intent.requestID)
        let handshake = try journal.readHandshake(nonce: record.nonce)
        if let response, response.status == .rejected {
            record = resolveRejectedSwitch(intent: intent, response: response, record: record)
            if record.state == .completedNeedsReconcile {
                let oldOwnerMatches = handshake?.destination == intent.previousSessionToken
                    && handshake?.readOnly == intent.previousReadOnly
                    && handshake?.childPID == intent.previousChildPID
                guard oldOwnerMatches else { try journal.write(record); return (record, true) }
                record.pendingSwitch = nil
                record.supervisorPID = handshake?.supervisorPID
                record.configurationState = .handshakeObserved
            }
            try journal.write(record)
            return (record, false)
        }
        let handshakeMatches = handshake?.destination == intent.destination && handshake?.readOnly == intent.readOnly
        guard response?.status == .completed || handshakeMatches else { return (record, true) }
        record.requestedSessionToken = intent.destination; record.readOnly = intent.readOnly
        record.liveClientKey = nil; record.requestID = intent.requestID; record.state = .completedNeedsReconcile
        record.childPID = response?.childPID ?? handshake?.childPID
        if handshakeMatches { record.supervisorPID = handshake?.supervisorPID; record.configurationState = .handshakeObserved }
        record.updatedAt = Date(); try journal.write(record)
        return (record, false)
    }

    private func resolveRejectedSwitch(intent: ManagedSwitchIntent, response: ManagedSupervisorResponse, record original: ManagedClientRecord) -> ManagedClientRecord {
        var record = original
        record.requestedSessionToken = intent.previousSessionToken; record.readOnly = intent.previousReadOnly
        record.liveClientKey = nil; record.requestID = intent.requestID; record.pendingPreviewTitle = nil
        if let previousChildPID = intent.previousChildPID, response.childPID == previousChildPID {
            record.childPID = previousChildPID
            record.state = .completedNeedsReconcile
        } else {
            record.childPID = nil; record.pendingSwitch = nil
            record.state = .failed
        }
        record.updatedAt = Date()
        return record
    }

    private func persistLateFailure(nonce: String, message: String) {
        do {
            guard var record = try journal.read(nonce: nonce) else { throw ManagedTerminalError.invalidRecord }
            record.state = .failed; record.updatedAt = Date(); try journal.write(record)
        } catch {
            Logger(subsystem: "com.tellang.tmuxrooms", category: "terminal").error("Unable to persist late failure for \(nonce, privacy: .public): \(String(describing: error), privacy: .public); original: \(message, privacy: .public)")
        }
    }

    private static func previewTitle(roomName: String) -> String {
        let singleLine = roomName
            .replacingOccurrences(of: "\0", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "READ ONLY · \(String(singleLine.prefix(512)))"
    }
}

private final class ContinuationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<ManagedTerminalReference, SmokeAutomationError>?, Never>?
    init(_ continuation: CheckedContinuation<Result<ManagedTerminalReference, SmokeAutomationError>?, Never>) { self.continuation = continuation }
    func finish(_ value: Result<ManagedTerminalReference, SmokeAutomationError>?) {
        let pending = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        pending?.resume(returning: value)
    }
}
