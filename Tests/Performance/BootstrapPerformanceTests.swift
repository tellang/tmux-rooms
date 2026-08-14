import Testing
@testable import TmuxRoomsCore

@Test("bootstrap marker is available without runtime work")
func bootstrapMarkerIsImmediate() {
    #expect(!TmuxRoomsCore.bootstrapMarker.isEmpty)
}
