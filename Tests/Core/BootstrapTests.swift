import Testing
@testable import TmuxRoomsCore

@Test("core scaffold exposes a stable bootstrap marker")
func bootstrapMarkerIsStable() {
    #expect(TmuxRoomsCore.bootstrapMarker == "tmux-rooms-core-v1")
}
