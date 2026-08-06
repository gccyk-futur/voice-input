import Foundation

/// Pure text replacement calculation used by the AX value-based insertion path.
/// AX text ranges are character ranges; NSString gives us the same UTF-16
/// indexing model used by the accessibility APIs.
struct TextInsertionPlan: Equatable, Sendable {
    let replacement: String
    let caretLocation: Int

    static func make(currentValue: String, selectedRange: NSRange, insertion: String) -> Self? {
        let value = currentValue as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= value.length,
              selectedRange.length <= value.length - selectedRange.location else {
            return nil
        }

        let replacement = value.replacingCharacters(in: selectedRange, with: insertion)
        let caretLocation = selectedRange.location + (insertion as NSString).length
        return Self(replacement: replacement, caretLocation: caretLocation)
    }
}
