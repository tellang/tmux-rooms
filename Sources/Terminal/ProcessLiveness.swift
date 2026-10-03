import Darwin
import Foundation

/// Answers whether a PID recorded in the managed-client journal can still be
/// backing a live supervisor or tmux client.
///
/// Journal records outlive the processes they name: a supervisor and its tmux
/// child die with their terminal, with the tmux server, or with a reboot, while
/// `records/` and `handshake-*.json` survive on disk. Recovery must be able to
/// tell "this PID is gone" from "this PID is still working", otherwise it waits
/// for a reply nobody is left to write.
public protocol ProcessLivenessProbing: Sendable {
    /// `true` only when the process is proven gone.
    ///
    /// Anything uncertain must answer `false`, including a PID that exists but
    /// is owned by another user and therefore may be a reuse of the recorded
    /// number, so the caller keeps taking the ownership-verifying slow path.
    func isDefinitelyDead(_ pid: Int32) -> Bool
}

public struct POSIXProcessLiveness: ProcessLivenessProbing {
    public init() {}

    public func isDefinitelyDead(_ pid: Int32) -> Bool {
        guard pid > 0 else { return true }
        if Darwin.kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }
}
