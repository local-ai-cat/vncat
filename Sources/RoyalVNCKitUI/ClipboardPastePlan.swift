import Foundation

/// What the session's Paste (toolbar button or Command-V) sends, from what the
/// local clipboard holds.
///
/// Text keeps winning, so copied prose never turns into a picture. An image
/// wins when there is no text, or when the only text is a web address that
/// came along with it: Safari and Photos-style "Copy" put the image's URL
/// next to the image, and the person copied the picture, not the link.
public enum ClipboardPastePlan: Equatable, Sendable {
    case text(String)
    case image
    case nothing

    public static func choose(string: String?, hasImage: Bool) -> ClipboardPastePlan {
        let text = string.flatMap { $0.isEmpty ? nil : $0 }
        guard hasImage else {
            return text.map(ClipboardPastePlan.text) ?? .nothing
        }
        guard let text else { return .image }
        return isLoneWebAddress(text) ? .image : .text(text)
    }

    static func isLoneWebAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
