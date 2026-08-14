import AppKit
import SwiftUI
import TmuxRoomsCore

private enum Palette {
    static let canvas = Color(red: 0.045, green: 0.055, blue: 0.065)
    static let raised = Color(red: 0.085, green: 0.098, blue: 0.11)
    static let line = Color.white.opacity(0.10)
    static let mint = Color(red: 0.39, green: 0.94, blue: 0.70)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.30)
    static let red = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let ink = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.60)
}

struct RoomsRootView: View {
    @ObservedObject var store: RoomsStore
    @State private var fixtureKeyMonitor: Any?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.line)
                content
                Divider().overlay(Palette.line)
                footer
            }
            if let context = store.chooser {
                modalBackdrop
                ClientChooserSheet(store: store, context: context)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            } else if let context = store.deleteConfirmation {
                modalBackdrop
                DeleteConfirmationSheet(store: store, context: context)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .frame(width: 480, height: 660)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.16), value: store.chooser?.id)
        .animation(.easeOut(duration: 0.16), value: store.deleteConfirmation?.id)
        .onAppear { installFixtureKeyMonitorIfNeeded() }
        .onDisappear { removeFixtureKeyMonitor() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.mint.opacity(0.15))
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.mint)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("TMUX ROOMS")
                    .font(.custom("Avenir Next Demi Bold", size: 15))
                    .tracking(1.4)
                Text("Existing sessions on the default local server")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if store.phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing rooms")
                    .accessibilityIdentifier("refresh.progress")
            }
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(QuietIconButtonStyle())
            .disabled(store.phase != .idle)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Refresh tmux rooms")
            .accessibilityIdentifier("refresh")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let issue = store.issue {
                    IssueBanner(store: store, issue: issue)
                }

                if store.phase == .loading && store.snapshot.rooms.isEmpty {
                    LoadingState()
                } else if store.snapshot.rooms.isEmpty {
                    EmptyRoomsState(hasServer: store.snapshot.server != nil)
                } else {
                    ForEach(store.snapshot.rooms, id: \.token) { room in
                        RoomRow(store: store, room: room)
                    }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.visible)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Open reuses an existing room", systemImage: "checkmark.shield")
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quit")
            }
            .font(.custom("Avenir Next Medium", size: 10))
            .foregroundStyle(Palette.muted)
            Text("Open never creates a tmux session")
                .font(.custom("Avenir Next Medium", size: 10))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            #if DEBUG
            if store.isFixture {
                HStack(spacing: 6) {
                    Text("FIXTURE v1")
                        .foregroundStyle(Palette.amber)
                    Spacer()
                    Text("\(store.fixtureActionCount)")
                        .accessibilityIdentifier("fixture.action.count")
                    Text(store.fixtureLastAction)
                        .lineLimit(1)
                        .accessibilityIdentifier("fixture.action.last")
                    Text("\(store.fixtureMaxConcurrentActions)")
                        .accessibilityLabel("Maximum concurrent actions \(store.fixtureMaxConcurrentActions)")
                        .accessibilityIdentifier("fixture.action.max-concurrent")
                }
                .font(.custom("SF Mono Medium", size: 10))
                if store.fixtureActionPending {
                    HStack {
                        Text("pending")
                            .accessibilityIdentifier("fixture.action.pending")
                        Spacer()
                        Button("Complete fixture action") { store.completeFixtureAction() }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("fixture.action.complete")
                    }
                    .font(.custom("SF Mono Medium", size: 10))
                } else {
                    Text("idle")
                        .font(.custom("SF Mono Medium", size: 10))
                        .accessibilityIdentifier("fixture.action.pending")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            #endif
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var modalBackdrop: some View {
        Rectangle()
            .fill(Color.black.opacity(0.62))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private func installFixtureKeyMonitorIfNeeded() {
        guard store.isFixture, fixtureKeyMonitor == nil else { return }
        fixtureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 36, modifiers.isEmpty,
                  store.phase == .idle, let room = store.snapshot.rooms.first else { return event }
            store.open(room)
            return nil
        }
    }

    private func removeFixtureKeyMonitor() {
        guard let fixtureKeyMonitor else { return }
        NSEvent.removeMonitor(fixtureKeyMonitor)
        self.fixtureKeyMonitor = nil
    }
}

private struct RoomRow: View {
    @ObservedObject var store: RoomsStore
    let room: SessionRoom
    @State private var showsMore = false

    private var roomID: String { room.uiIdentifier }
    private var activePane: SessionRoom.Pane? { room.panes.first(where: \.isActive) ?? room.panes.first }
    private var attached: Bool { room.clients.contains { !$0.isControlMode } }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(attached ? Palette.mint : Palette.muted)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(room.name)
                    .font(.custom("Avenir Next Demi Bold", size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(room.name)
                    .accessibilityIdentifier("room.\(roomID)")
                Spacer(minLength: 6)
                Text(statusText)
                    .font(.custom("SF Mono Medium", size: 10))
                    .foregroundStyle(attached ? Palette.mint : Palette.muted)
                    .lineLimit(1)
                    .accessibilityLabel(statusText)
                    .accessibilityIdentifier("room.\(roomID).status")
            }

            if let pane = activePane {
                HStack(spacing: 7) {
                    Label("\(room.panes.count) pane\(room.panes.count == 1 ? "" : "s")", systemImage: "square.split.2x1")
                        .accessibilityLabel("\(room.panes.count) panes")
                        .accessibilityIdentifier("room.\(roomID).pane-count")
                    Text("·").foregroundStyle(Palette.line)
                    Text(pane.currentCommand.isEmpty ? "unknown" : pane.currentCommand)
                        .accessibilityLabel("Active command \(pane.currentCommand.isEmpty ? "unknown" : pane.currentCommand)")
                        .accessibilityIdentifier("room.\(roomID).active-command")
                    Text("·").foregroundStyle(Palette.line)
                    Text(pane.currentPath.isEmpty ? "Path unavailable" : pane.currentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Active path \(pane.currentPath.isEmpty ? "unavailable" : pane.currentPath)")
                        .accessibilityIdentifier("room.\(roomID).active-path")
                }
                .font(.custom("SF Mono", size: 10))
                .foregroundStyle(Palette.muted)
            }

            if room.interactiveClients.count == 1, let client = room.interactiveClients.first {
                clientStatus(client)
            }

            if !room.readOnlyClients.isEmpty {
                Label("READ ONLY Preview active", systemImage: "eye")
                    .font(.custom("Avenir Next Demi Bold", size: 10))
                    .foregroundStyle(Palette.amber)
                    .accessibilityIdentifier("room.\(roomID).preview-status")
            }

            HStack(spacing: 8) {
                Button("Open") { store.open(room) }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityLabel("Open existing room \(room.name)")
                    .accessibilityHint(openHint)
                    .accessibilityIdentifier("room.\(roomID).open")
                    .focusable()
                    .disabled(store.phase != .idle)
                Button("Preview") { store.preview(room) }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityLabel("Preview \(room.name) read only")
                    .accessibilityIdentifier("room.\(roomID).preview")
                    .focusable()
                    .disabled(store.phase != .idle)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showsMore.toggle() }
                } label: {
                    Label("More", systemImage: showsMore ? "chevron.up" : "ellipsis")
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("room.\(roomID).more")
                .focusable()
                .disabled(store.phase != .idle)
            }

            if showsMore || store.isFixture {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duplicate adds another view of this room. Edits are shared; no session is cloned.")
                        .font(.custom("Avenir Next Medium", size: 10))
                        .foregroundStyle(Palette.muted)
                    HStack(spacing: 8) {
                        Button("Duplicate Window") { store.duplicate(room) }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .accessibilityIdentifier("room.\(roomID).duplicate")
                            .focusable()
                            .disabled(store.phase != .idle)
                        Button("Delete…", role: .destructive) { store.requestDelete(room) }
                            .buttonStyle(DangerButtonStyle())
                            .accessibilityLabel("Delete room \(room.name)")
                            .accessibilityIdentifier("room.\(roomID).delete")
                            .focusable()
                            .disabled(store.phase != .idle)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Palette.raised)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        )
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func clientStatus(_ client: SessionRoom.Client) -> some View {
        switch store.focusability(for: client) {
        case .focusable:
            Label("One client · exact iTerm target ready", systemImage: "scope")
                .foregroundStyle(Palette.mint)
        case .unavailable(let reason):
            Label("One client · cannot focus: \(reason)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.amber)
        }
    }

    private var statusText: String {
        let count = room.interactiveClients.count
        return attached ? "Attached · \(count) interactive" : "Detached"
    }

    private var openHint: String {
        switch room.interactiveClients.count {
        case 0: "Reuse the managed Primary client or create exactly one terminal client. No tmux session is created."
        case 1: "Focus the exact existing client when available."
        default: "Choose the exact client to focus. No client is selected automatically."
        }
    }
}

private struct ClientChooserSheet: View {
    @ObservedObject var store: RoomsStore
    let context: ClientChooserContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CHOOSE A CLIENT")
                .font(.custom("Avenir Next Demi Bold", size: 16))
                .tracking(1.2)
                .accessibilityIdentifier("client-chooser.title")
            Text("\(context.room.interactiveClients.count) interactive clients are attached to “\(context.room.name)”. Tmux Rooms never chooses one arbitrarily.")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(Palette.muted)

            ForEach(context.room.interactiveClients, id: \.key) { client in
                let state = store.focusability(for: client)
                Button {
                    store.select(client, in: context.room)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(client.clientName)
                                .font(.custom("SF Mono Medium", size: 12))
                            Text(client.tty ?? "TTY unavailable")
                                .font(.custom("SF Mono", size: 10))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Text(state.isFocusable ? "FOCUS" : "UNAVAILABLE")
                            .font(.custom("Avenir Next Demi Bold", size: 9))
                            .foregroundStyle(state.isFocusable ? Palette.mint : Palette.amber)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ClientChoiceButtonStyle())
                .disabled(!state.isFocusable)
                .accessibilityLabel("Client \(client.clientName), \(client.tty ?? "TTY unavailable"), \(state.isFocusable ? "focusable" : "unavailable")")
                .accessibilityIdentifier("client.\(client.clientName).select")
            }

            HStack {
                Spacer()
                Button("Cancel") { store.cancelChooser() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier("client-chooser.cancel")
            }
        }
        .padding(22)
        .frame(width: 410)
        .background(Palette.canvas)
    }
}

private struct DeleteConfirmationSheet: View {
    @ObservedObject var store: RoomsStore
    let context: DeleteContext

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Delete this tmux session?", systemImage: "trash")
                .font(.custom("Avenir Next Demi Bold", size: 17))
                .foregroundStyle(Palette.red)
                .accessibilityIdentifier("delete-confirmation.title")
            Text("Session: \(context.room.name)")
                .font(.custom("SF Mono Medium", size: 12))
                .lineLimit(2)
                .accessibilityIdentifier("delete-confirmation.name")
            Text("\(context.room.interactiveClients.count) interactive client\(context.room.interactiveClients.count == 1 ? " is" : "s are") currently attached.")
                .font(.custom("Avenir Next Medium", size: 12))
                .accessibilityIdentifier("delete-confirmation.clients")
            Text("This ends the exact server-scoped session. It does not delete project files.")
                .font(.custom("Avenir Next Medium", size: 11))
                .foregroundStyle(Palette.muted)
            HStack {
                Button("Cancel") { store.cancelDelete() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier("delete-confirmation.cancel")
                Spacer()
                Button("Delete Session", role: .destructive) { store.confirmDelete() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DangerButtonStyle())
                    .accessibilityIdentifier("delete-confirmation.confirm")
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Palette.canvas)
    }
}

private struct IssueBanner: View {
    @ObservedObject var store: RoomsStore
    let issue: AppIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: issue.kind == .automationDenied ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .accessibilityIdentifier("issue.\(issue.kind.rawValue)")
                    Text(issue.message)
                        .font(.custom("Avenir Next Medium", size: 11))
                        .foregroundStyle(Palette.muted)
                        .accessibilityIdentifier(messageIdentifier)
                    if let diagnostics = issue.diagnostics {
                        Text(diagnostics)
                            .font(.custom("SF Mono", size: 9))
                            .foregroundStyle(Palette.muted.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            }

            recoveryControls
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.amber.opacity(0.28)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var recoveryControls: some View {
        if issue.kind == .ambiguousManaged {
            HStack(spacing: 7) {
                Button("Use as Primary") { store.resolve(.choosePrimary) }
                    .accessibilityIdentifier("recovery.choose-primary")
                Button("Use as Preview") { store.resolve(.choosePreview) }
                    .accessibilityIdentifier("recovery.choose-preview")
                Button("Clean Up") { store.resolve(.cleanUp) }
                    .accessibilityIdentifier("recovery.clean-up")
            }
            .buttonStyle(QuietButtonStyle())
        } else {
            switch issue.retry {
            case .none:
                EmptyView()
            case .enabled(let intent):
                Button(issue.kind == .staleTarget ? "Refresh" : "Retry") { store.retry(intent) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier(issue.kind == .staleTarget ? "issue.refresh" : "issue.retry")
            case .blockedWhileRunning:
                Button("Retry") {}
                    .buttonStyle(QuietButtonStyle())
                    .disabled(true)
                    .accessibilityHint("Retry is disabled while the underlying request is still running")
                    .accessibilityIdentifier("issue.retry")
            }
        }
    }

    private var messageIdentifier: String {
        switch issue.kind {
        case .automationDenied: "issue.automation-denied.guidance"
        case .timeout: "issue.timeout.running"
        default: "issue.\(issue.kind.rawValue).message"
        }
    }
}

private struct EmptyRoomsState: View {
    let hasServer: Bool
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: hasServer ? "rectangle.stack.badge.minus" : "powerplug")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Palette.muted)
            Text(hasServer ? "No rooms on this server" : "No tmux server is running")
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .accessibilityIdentifier(hasServer ? "empty.rooms.title" : "empty.no-server.title")
            Text(hasServer ? "Refresh after creating a session in your terminal." : "Tmux Rooms will not start a server or create a session. Start tmux in your terminal, then Refresh.")
                .font(.custom("Avenir Next Medium", size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.muted)
                .accessibilityIdentifier(hasServer ? "empty.rooms.intent" : "empty.no-server.intent")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

private struct LoadingState: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading existing tmux rooms…")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(Palette.muted)
                .accessibilityIdentifier("loading.title")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

private extension SessionRoom {
    var uiIdentifier: String {
        let sessionID = token.sessionID.drop(while: { $0 == "$" })
        return "session-\(sessionID)-\(token.createdAtUnixSeconds)"
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(Color.black.opacity(0.82))
            .background(Palette.mint.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Palette.ink)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.07), in: Capsule())
            .overlay(Capsule().stroke(Palette.line))
    }
}

private struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Palette.red)
            .background(Palette.red.opacity(configuration.isPressed ? 0.18 : 0.09), in: Capsule())
            .overlay(Capsule().stroke(Palette.red.opacity(0.35)))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .foregroundStyle(Palette.ink.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.ink.opacity(configuration.isPressed ? 0.55 : 0.9))
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClientChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.raised.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
