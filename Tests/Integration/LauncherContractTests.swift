import Foundation
import Testing
@testable import TmuxRoomsCore

@Test("launcher keeps its fixed executable name")
func launcherExecutableNameIsStable() {
    #expect(LauncherContract.executableName == "tmuxrooms-launch")
}
