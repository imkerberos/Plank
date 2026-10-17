import Foundation

struct AppBadgeContent: Equatable, Sendable {
    let label: String
    let displayText: String

    init?(_ text: String) {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        self.label = label
        let digits = label.filter { !$0.isWhitespace && $0 != "," }
        if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // Compare the normalized digits without overflowing large counts.
            let significant = digits.drop(while: { $0 == "0" })
            displayText = significant.count > 2 ? "99+" : (significant.isEmpty ? "0" : String(significant))
        } else if ["•", "●", ".", "…"].contains(label) || label.count > 4 {
            displayText = ""
        } else {
            displayText = label
        }
    }
}
