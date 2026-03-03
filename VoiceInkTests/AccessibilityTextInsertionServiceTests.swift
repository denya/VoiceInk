import Testing
@testable import VoiceInk

struct AccessibilityTextInsertionServiceTests {
    @Test
    func appendsWhenSelectionIsMissing() {
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: "hello",
            selectedRange: nil,
            insertionText: " world"
        )

        #expect(result.updatedText == "hello world")
        #expect(result.caretLocation == 11)
    }

    @Test
    func insertsAtCaretRange() {
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: "hello world",
            selectedRange: CFRange(location: 5, length: 0),
            insertionText: ","
        )

        #expect(result.updatedText == "hello, world")
        #expect(result.caretLocation == 6)
    }

    @Test
    func replacesSelectedRange() {
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: "hello world",
            selectedRange: CFRange(location: 6, length: 5),
            insertionText: "there"
        )

        #expect(result.updatedText == "hello there")
        #expect(result.caretLocation == 11)
    }

    @Test
    func clampsOutOfBoundsSelectionRange() {
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: "hello",
            selectedRange: CFRange(location: 99, length: 99),
            insertionText: "!"
        )

        #expect(result.updatedText == "hello!")
        #expect(result.caretLocation == 6)
    }

    @Test
    func treatsNotFoundSelectionAsAppend() {
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: "hello",
            selectedRange: CFRange(location: kCFNotFound, length: 0),
            insertionText: "!"
        )

        #expect(result.updatedText == "hello!")
        #expect(result.caretLocation == 6)
    }

    @Test
    func supportsMultilineText() {
        let original = "line1\nline2\nline3"
        let result = AccessibilityTextInsertionService.computeInsertion(
            originalText: original,
            selectedRange: CFRange(location: 6, length: 5),
            insertionText: "LINE_TWO"
        )

        #expect(result.updatedText == "line1\nLINE_TWO\nline3")
        #expect(result.caretLocation == 14)
    }
}
