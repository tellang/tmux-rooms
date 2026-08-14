import Testing
@testable import TmuxRoomsCore

@Test("terminal policy is implemented by the T6 managed supervisor lane")
func terminalPolicyIsImplemented() {
    #expect(TerminalScaffold.policyImplemented)
}
