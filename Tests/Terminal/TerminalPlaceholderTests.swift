import Testing
@testable import TmuxRoomsCore

@Test("terminal policy is intentionally not implemented in T2")
func terminalPolicyRemainsPlaceholder() {
    #expect(TerminalScaffold.policyImplemented == false)
}
