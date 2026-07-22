import Foundation

struct AIEnhancementOutputFilter {
    static func filter(_ text: String) -> String {
        var processedText = text
        let patterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(
                    in: processedText, options: [], range: range, withTemplate: "")
            }
        }

        processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let envelopePattern = #"(?is)\A<(TRANSCRIPT|USER_MESSAGE)>\s*(.*?)\s*</\1>\z"#
        if let regex = try? NSRegularExpression(pattern: envelopePattern),
           let match = regex.firstMatch(
               in: processedText,
               range: NSRange(processedText.startIndex..., in: processedText)
           ),
           let contentRange = Range(match.range(at: 2), in: processedText)
        {
            return String(processedText[contentRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return processedText
    }
}
