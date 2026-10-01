import Foundation
import TmuxRoomsCore

/// How many colors the terminal can show.
enum ColorDepth: Equatable {
    case none
    case ansi256
    case trueColor

    /// `NO_COLOR` wins over everything else. Otherwise `COLORTERM` announces 24-bit
    /// color, and a `256color` terminal name announces the fixed palette. Anything
    /// else gets no color rather than a guess that could print the wrong hue.
    static func detect(environment: [String: String]) -> ColorDepth {
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return .none }
        let colorTerm = (environment["COLORTERM"] ?? "").lowercased()
        if colorTerm.contains("truecolor") || colorTerm.contains("24bit") { return .trueColor }
        if (environment["TERM"] ?? "").contains("256color") { return .ansi256 }
        return .none
    }
}

/// The SGR parameters that set one agent's foreground color.
struct AgentColor: Equatable {
    /// Used when the terminal shows 24-bit color.
    let trueColor: String
    /// Used when only the 256-color palette is available.
    let ansi256: String
}

/// What tells one coding agent's room from another's: a short tag and a color.
enum AgentStyle {
    /// The colors triflux uses for these agents in its HUD (`hud/colors.mjs`), so a
    /// room reads the same here as there. Antigravity is grouped with Gemini in the
    /// HUD, so `agy` takes Gemini's blue.
    ///
    /// The values are written out rather than computed. Rounding the orange to the
    /// nearest cell of the 256-color cube lands on a pinkish red, so the fallback
    /// for it is the palette's own orange, 208.
    static func color(for kind: AgentKind?) -> AgentColor? {
        switch kind {
        case .claude: AgentColor(trueColor: "38;2;232;112;64", ansi256: "38;5;208")  // #E87040
        case .codex: AgentColor(trueColor: "97", ansi256: "97")  // bright white
        case .agy: AgentColor(trueColor: "38;5;39", ansi256: "38;5;39")  // Gemini blue
        case nil: nil
        }
    }

    /// The word printed in the AGENT column, so a room is still identifiable with
    /// colors off.
    static func tag(for kind: AgentKind?) -> String {
        kind?.rawValue ?? "-"
    }

    /// The SGR parameters that set this agent's foreground, or `nil` without an
    /// agent or without color.
    static func foreground(for kind: AgentKind?, depth: ColorDepth) -> String? {
        guard let color = color(for: kind) else { return nil }
        switch depth {
        case .none: return nil
        case .ansi256: return color.ansi256
        case .trueColor: return color.trueColor
        }
    }

    /// Styles one already padded row.
    ///
    /// An unselected agent row is text in the agent's color. The selected row keeps
    /// that color but adds reverse video, which swaps foreground and background:
    /// the bar becomes the agent's color and the text takes the terminal's own
    /// background, so it reads on dark and light themes alike. A row with no agent,
    /// or a terminal without color, is only reversed when selected.
    static func paint(_ text: String, kind: AgentKind?, selected: Bool, depth: ColorDepth) -> String {
        var parameters: [String] = []
        if let foreground = foreground(for: kind, depth: depth) {
            if selected { parameters.append("1") }
            parameters.append(foreground)
        }
        if selected { parameters.append("7") }
        guard !parameters.isEmpty else { return text }
        return "\u{1B}[\(parameters.joined(separator: ";"))m\(text)\u{1B}[0m"
    }
}
