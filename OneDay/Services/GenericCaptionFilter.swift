import Foundation

/// iOS writes a generic description into the Photos database for captures
/// that carry no user caption — "Screenshot" for screenshots, "Screen
/// Recording" for screen recordings. Those are system labels, not content,
/// so they must never surface as a day page's 说明文字.
nonisolated enum GenericCaptionFilter {
    /// Lowercased, whitespace-trimmed system placeholders.
    private static let systemCaptions: Set<String> = [
        "screenshot",
        "screen recording",
    ]

    /// Returns the caption unchanged, or nil when it is empty or a known
    /// system-generated placeholder.
    static func userCaption(_ text: String?) -> String? {
        guard let text else { return nil }
        let probe = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !probe.isEmpty, !systemCaptions.contains(probe) else { return nil }
        return text
    }
}
