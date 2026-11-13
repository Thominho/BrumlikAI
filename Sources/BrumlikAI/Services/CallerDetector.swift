import Foundation
import CoreGraphics

/// Reads the caller's name or number from the title of the FaceTime / Phone call window.
/// Other apps' window titles are only visible with the Screen Recording permission.
enum CallerDetector {
    private static let callApps: Set<String> = ["FaceTime", "Phone", "Telefon"]

    static func detectCallerHint() -> String? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, callApps.contains(owner),
                  let title = window[kCGWindowName as String] as? String,
                  let caller = extractCaller(from: title) else { continue }
            return caller
        }
        return nil
    }

    /// Turns titles like "FaceTime — Jan Novák" or "Audio call with +420 777 123 456" into the caller part.
    static func extractCaller(from title: String) -> String? {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callApps.contains(result) else { return nil }

        for app in callApps {
            for separator in [" — ", " – ", " - ", ": "] {
                if result.hasPrefix(app + separator) { result = String(result.dropFirst(app.count + separator.count)) }
                if result.hasSuffix(separator + app) { result = String(result.dropLast(app.count + separator.count)) }
            }
        }

        let lowered = result.lowercased()
        let prefixes = ["audio call with ", "video call with ", "call with ", "zvukový hovor s ", "videohovor s ", "hovor s ", "volání s "]
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func looksLikePhoneNumber(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789+-().").union(.whitespaces)
        let digits = text.filter(\.isNumber).count
        return (5...20).contains(digits) && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
