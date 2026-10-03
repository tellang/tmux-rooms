import Foundation
import Testing
import TmuxRoomsCore

@Test("external consumers can construct frozen public value models")
func publicModelInitializersRemainAccessible() {
    let server = ServerIdentity(canonicalSocketPath: "/private/tmp/tmux.sock", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
    let token = SessionToken(server: server, sessionID: "$0", createdAtUnixSeconds: 5)
    let key = ClientKey(server: server, clientName: "client", tty: "/dev/ttys001", clientPID: 6, createdAtUnixSeconds: 7)
    let pane = SessionRoom.Pane(windowID: "@0", paneID: "%0", panePID: 8, currentPath: "/tmp", title: "title", currentCommand: "zsh", isActive: true, isDead: false, windowIndex: 0, paneIndex: 0)
    let client = SessionRoom.Client(key: key, lastActivityAtUnixSeconds: 9, flags: ["attached"], isReadOnly: false, terminalName: "xterm-256color", isControlMode: false)
    let room = SessionRoom(token: token, name: "room", lastActivityAtUnixSeconds: 10, panes: [pane], clients: [client])
    let snapshot = RoomSnapshot(server: server, rooms: [room])
    let invocation = TmuxCommandInvocation(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"), arguments: ["-V"])
    let output = TmuxCommandOutput(exitCode: 0, termination: .exit, stdout: Data(), stderr: Data())
    #expect(snapshot.rooms == [room]); #expect(invocation.arguments == ["-V"]); #expect(output.exitCode == 0)
}
