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
            #if DEBUG
            if store.fixtureActionPending {
                FixtureActionGate(store: store)
            }
            #endif
        }
        .frame(width: 480, height: 660)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.16), value: store.chooser?.id)
        .animation(.easeOut(duration: 0.16), value: store.deleteConfirmation?.id)
        #if DEBUG
        .transaction { transaction in
            if store.isFixture {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        #endif
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
            .keyboardFocusable()
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
                .buttonStyle(PlainPressButtonStyle())
                .keyboardFocusable()
                .accessibilityIdentifier("quit")
            }
            .font(.custom("Avenir Next Medium", size: 10))
            .foregroundStyle(Palette.muted)
            Text("Open never creates a tmux session")
                .font(.custom("Avenir Next Medium", size: 10))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            #if DEBUG
            // UI tests read this strip. The README demo leaves it out of the recording.
            if store.isFixture, store.fixtureIdentifier != UIFixture.readmeDemo.rawValue {
                HStack(spacing: 6) {
                    Text("FIXTURE v1")
                        .foregroundStyle(Palette.amber)
                    Text(store.fixtureIdentifier ?? "unknown")
                        .lineLimit(1)
                        .accessibilityIdentifier("fixture.current")
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
                    Text("pending")
                        .accessibilityIdentifier("fixture.action.pending")
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

}

#if DEBUG
private struct FixtureActionGate: View {
    @ObservedObject var store: RoomsStore

    var body: some View {
        VStack(spacing: 10) {
            Text("Fixture action held")
                .font(.custom("Avenir Next Demi Bold", size: 12))
            Button("Complete fixture action") { store.completeFixtureAction() }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardFocusable()
                .accessibilityIdentifier("fixture.action.complete")
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
}
#endif

private struct RoomRow: View {
    @ObservedObject var store: RoomsStore
    let room: SessionRoom
    @State private var showsMore = false

    private var roomID: String { room.uiIdentifier }
    private var activePane: SessionRoom.Pane? { room.panes.first(where: \.isActive) ?? room.panes.first }
    private var attached: Bool { room.clients.contains { !$0.isControlMode } }
    private var presence: AgentPresence { store.presence(for: room) }

    /// What the room is called on the card.
    ///
    /// A room running a named coding agent is known by that session's name: it
    /// is what the person working in it chose to call the work. The tmux name is
    /// a launcher-generated string such as
    /// `agent-20260901023710`, so it moves to the metadata line
    /// rather than being lost.
    private var title: String { presence.title ?? room.name }

    /// The second line's middle field. It carries whichever of the two names the
    /// title did not take, and falls back to the pane's command for a room with
    /// no agent in it.
    private var origin: String {
        guard presence != .absent else {
            let command = activePane?.currentCommand ?? ""
            return command.isEmpty ? "unknown" : command
        }
        return room.name
    }

    private var originAccessibilityLabel: String {
        presence == .absent ? "Active command \(origin)" : "Tmux session \(origin)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(attached ? Palette.mint : Palette.muted)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("room.\(roomID)")
                Spacer(minLength: 6)
                if room.interactiveClients.count == 1, let client = room.interactiveClients.first {
                    focusIndicator(for: client)
                }
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
                    Text(origin)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(originAccessibilityLabel)
                        .accessibilityIdentifier("room.\(roomID).origin")
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

            // Our own Preview says so on its button. A read-only client we do
            // not own has nowhere else to appear, so it keeps the line.
            if !room.readOnlyClients.isEmpty, !store.isPreviewing(room) {
                Label("READ ONLY client attached", systemImage: "eye")
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
                    .keyboardFocusable()
                    .fixtureDefaultAction(store.isFixture)
                    .disabled(store.phase != .idle)
                PreviewControl(store: store, room: room, roomID: roomID)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showsMore.toggle() }
                } label: {
                    Label("More", systemImage: showsMore ? "chevron.up" : "ellipsis")
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("room.\(roomID).more")
                .keyboardFocusable()
                .disabled(store.phase != .idle)
            }

            if showsMore {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duplicate adds another view of this room. Edits are shared; no session is cloned.")
                        .font(.custom("Avenir Next Medium", size: 10))
                        .foregroundStyle(Palette.muted)
                    HStack(spacing: 8) {
                        Button("Duplicate Window") { store.duplicate(room) }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .accessibilityIdentifier("room.\(roomID).duplicate")
                            .keyboardFocusable()
                            .disabled(store.phase != .idle)
                        Button("Delete…", role: .destructive) { store.requestDelete(room) }
                            .buttonStyle(DangerButtonStyle())
                            .accessibilityLabel("Delete room \(room.name)")
                            .accessibilityIdentifier("room.\(roomID).delete")
                            .keyboardFocusable()
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

    /// Whether the one attached client can be focused, said in a dot.
    ///
    /// The dot sits beside the room's status and costs no line of its own. The
    /// full reason is its accessibility label.
    private func focusIndicator(for client: SessionRoom.Client) -> some View {
        let focusability = store.focusability(for: client)
        let ready = focusability.isFocusable
        let detail: String
        switch focusability {
        case .focusable: detail = "Exact iTerm target ready"
        case let .unavailable(reason): detail = "Cannot focus: \(reason)"
        }
        return Circle()
            .fill(ready ? Palette.mint : Palette.amber)
            .frame(width: 6, height: 6)
            .accessibilityLabel(detail)
            .accessibilityIdentifier("room.\(roomID).focus-indicator")
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

/// Takes keyboard focus without the system ring; each button style draws its own in its own color.
private extension View {
    func keyboardFocusable() -> some View {
        focusable().focusEffectDisabled()
    }
}

/// The focus halo, drawn just outside the control's own shape.
private struct FocusHalo<S: InsettableShape>: ViewModifier {
    @Environment(\.isFocused) private var focused
    let tint: Color
    let pressed: Bool
    let shape: S

    func body(content: Content) -> some View {
        // A press reads as the control going down and dark, so the halo stays
        // out of the way until the finger lifts.
        let lit = focused && !pressed
        content
            .overlay {
                shape
                    .strokeBorder(tint.opacity(lit ? 0.9 : 0), lineWidth: 1.5)
            }
            .overlay {
                shape
                    .strokeBorder(tint.opacity(lit ? 0.5 : 0), lineWidth: 3)
                    .blur(radius: 3)
                    .padding(-2)
            }
            .animation(.easeOut(duration: 0.12), value: lit)
    }
}

private extension View {
    func focusHalo(_ tint: Color, pressed: Bool, in shape: some InsettableShape) -> some View {
        modifier(FocusHalo(tint: tint, pressed: pressed, shape: shape))
    }
}

/// One button for the whole Preview state.
///
/// It reads READ ONLY while a Preview is up and turns into Close Preview under
/// the pointer, so the way out is where the way in was and the card's layout
/// does not shift when a Preview opens.
private struct PreviewControl: View {
    @ObservedObject var store: RoomsStore
    let room: SessionRoom
    let roomID: String
    @State private var hovering = false

    var body: some View {
        if store.isPreviewing(room) {
            Button {
                store.closePreview(room)
            } label: {
                // Both labels occupy the same width, so the row does not shift
                // as the pointer crosses the button.
                ZStack {
                    label("Close Preview", icon: "xmark").opacity(hovering ? 1 : 0)
                    label("READ ONLY", icon: "eye").opacity(hovering ? 0 : 1)
                }
            }
            .buttonStyle(PreviewActiveButtonStyle(closing: hovering))
            .onHover { hovering = $0 }
            .accessibilityLabel("Close preview of \(room.name)")
            .accessibilityIdentifier("room.\(roomID).close-preview")
            .keyboardFocusable()
            .disabled(store.phase != .idle)
        } else {
            Button("Preview") { store.preview(room) }
                .buttonStyle(SecondaryActionButtonStyle())
                .accessibilityLabel("Preview \(room.name) read only")
                .accessibilityIdentifier("room.\(roomID).preview")
                .keyboardFocusable()
                .disabled(store.phase != .idle)
        }
    }

    private func label(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .fixedSize()
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
                .keyboardFocusable()
                .disabled(!state.isFocusable)
                .accessibilityLabel("Client \(client.clientName), \(client.tty ?? "TTY unavailable"), \(state.isFocusable ? "focusable" : "unavailable")")
                .accessibilityIdentifier("client.\(client.clientName).select")
            }

            HStack {
                Spacer()
                Button("Cancel") { store.cancelChooser() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .keyboardFocusable()
                    .accessibilityIdentifier("client-chooser.cancel")
            }
        }
        .padding(22)
        .frame(width: 410)
        .sheetChrome()
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
                    .keyboardFocusable()
                    .accessibilityIdentifier("delete-confirmation.cancel")
                Spacer()
                Button("Delete Session", role: .destructive) { store.confirmDelete() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DangerButtonStyle())
                    .keyboardFocusable()
                    .accessibilityIdentifier("delete-confirmation.confirm")
            }
        }
        .padding(22)
        .frame(width: 400)
        .sheetChrome()
    }
}

private extension View {
    /// The card a sheet sits on. Both sheets float over a dimmed room list, and
    /// a square-cornered panel over that backdrop reads as the window itself
    /// having lost its corners. Same radius as a room card, one line of border
    /// so the edge survives on the dark canvas, and a shadow to put it above.
    func sheetChrome() -> some View {
        background(Palette.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issue.recoveryCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidateSummary(candidate))
                            .font(.custom("SF Mono", size: 9))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("recovery.candidate.\(candidate.nonce)")
                        HStack(spacing: 7) {
                            if isPromotable(candidate) && !candidate.readOnly {
                                Button("Use as Primary") { store.resolve(candidateNonce: candidate.nonce, as: .choosePrimary) }
                                    .keyboardFocusable()
                                    .accessibilityIdentifier("recovery.\(candidate.nonce).choose-primary")
                            }
                            if isPromotable(candidate) && candidate.readOnly {
                                Button("Use as Preview") { store.resolve(candidateNonce: candidate.nonce, as: .choosePreview) }
                                    .keyboardFocusable()
                                    .accessibilityIdentifier("recovery.\(candidate.nonce).choose-preview")
                            }
                            Button("Clean Up This Candidate") { store.resolve(candidateNonce: candidate.nonce, as: .cleanUp) }
                                .keyboardFocusable()
                                .accessibilityIdentifier("recovery.\(candidate.nonce).clean-up")
                        }
                    }
                }
            }
            .buttonStyle(QuietButtonStyle())
        } else {
            switch issue.retry {
            case .none:
                EmptyView()
            case .enabled(let intent):
                Button(issue.kind == .staleTarget ? "Refresh" : "Retry") { store.retry(intent) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardFocusable()
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

    private func candidateSummary(_ candidate: ManagedRecoveryCandidate) -> String {
        let role = candidate.role?.rawValue ?? "unassigned"
        let guid = candidate.terminal?.sessionGUID ?? "no-guid"
        let tty = candidate.terminal?.tty ?? "no-tty"
        return "\(candidate.roomName) · \(candidate.sessionToken.sessionID) · \(role) · \(candidate.state.rawValue) · nonce \(candidate.nonce) · GUID \(guid) · \(tty)"
    }

    private func isPromotable(_ candidate: ManagedRecoveryCandidate) -> Bool {
        candidate.state == .complete || candidate.state == .recovered
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

private extension View {
    /// The one press response every button on the card uses: dip, darken, inner shadow, spring back.
    func pressedResponse(_ pressed: Bool, in shape: some InsettableShape) -> some View {
        overlay {
            shape.fill(Color.black.opacity(pressed ? 0.28 : 0))
        }
        .overlay {
            shape
                .stroke(Color.black.opacity(pressed ? 0.7 : 0), lineWidth: 4)
                .blur(radius: 3)
                .offset(y: 2)
                .mask(shape.fill(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)))
        }
        .scaleEffect(pressed ? 0.95 : 1, anchor: .center)
        .offset(y: pressed ? 0.75 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: pressed)
    }
}

/// For a button with no box of its own. It moves and dims with the same spring
/// as the rest, because a button that never answers a press reads as dead.
private struct PlainPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .offset(y: configuration.isPressed ? 0.75 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.45), value: configuration.isPressed)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(Color.black.opacity(0.82))
            .background(Palette.mint, in: Capsule())
            .pressedResponse(configuration.isPressed, in: Capsule())
            .focusHalo(Palette.mint, pressed: configuration.isPressed, in: Capsule())
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Palette.ink)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(Palette.line))
            .pressedResponse(configuration.isPressed, in: Capsule())
            .focusHalo(Palette.ink, pressed: configuration.isPressed, in: Capsule())
    }
}

/// Amber while it only reports READ ONLY, red once it offers to close.
private struct PreviewActiveButtonStyle: ButtonStyle {
    let closing: Bool

    func makeBody(configuration: Configuration) -> some View {
        let tint = closing ? Palette.red : Palette.amber
        return configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.45)))
            .pressedResponse(configuration.isPressed, in: Capsule())
            .focusHalo(tint, pressed: configuration.isPressed, in: Capsule())
            .animation(.easeOut(duration: 0.12), value: closing)
    }
}

private struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Palette.red)
            .background(Palette.red.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(Palette.red.opacity(0.35)))
            .pressedResponse(configuration.isPressed, in: Capsule())
            .focusHalo(Palette.red, pressed: configuration.isPressed, in: Capsule())
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .pressedResponse(configuration.isPressed, in: RoundedRectangle(cornerRadius: 7))
            .focusHalo(Palette.ink, pressed: configuration.isPressed, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.ink.opacity(0.9))
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .pressedResponse(configuration.isPressed, in: RoundedRectangle(cornerRadius: 8))
            .focusHalo(Palette.ink, pressed: configuration.isPressed, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClientChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
            .pressedResponse(configuration.isPressed, in: RoundedRectangle(cornerRadius: 9))
            .focusHalo(Palette.mint, pressed: configuration.isPressed, in: RoundedRectangle(cornerRadius: 9))
    }
}

private extension View {
    @ViewBuilder
    func fixtureDefaultAction(_ enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(.defaultAction)
        } else {
            self
        }
    }
}
