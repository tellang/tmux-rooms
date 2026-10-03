import Foundation

/// Names from agent registries, transcripts, and tmux end up on a terminal,
/// where an escape sequence could move the cursor, retitle the window, or set
/// the clipboard through OSC 52.
public enum TerminalText {
    /// Drops C0 controls, DEL, and C1 controls, and turns a newline or tab into
    /// a space so a multi-line name stays on one row.
    public static func sanitized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" { scalars.append(" ") }
            else if !isControl(scalar) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}
