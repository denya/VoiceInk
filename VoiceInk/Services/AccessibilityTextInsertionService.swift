import Foundation
import AppKit
import ApplicationServices
import os

struct TextInsertionComputationResult: Equatable {
    let updatedText: String
    let caretLocation: Int
}

enum AccessibilityInsertOutcome: Equatable {
    case success
    case accessibilityNotTrusted
    case noFocusedElement
    case secureTextField
    case unsupportedValueAttribute
    case valueNotSettable
    case failedToSetValue(code: Int32)

    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    var debugSummary: String {
        switch self {
        case .success:
            return "success"
        case .accessibilityNotTrusted:
            return "accessibilityNotTrusted"
        case .noFocusedElement:
            return "noFocusedElement"
        case .secureTextField:
            return "secureTextField"
        case .unsupportedValueAttribute:
            return "unsupportedValueAttribute"
        case .valueNotSettable:
            return "valueNotSettable"
        case .failedToSetValue(let code):
            return "failedToSetValue(\(code))"
        }
    }
}

@MainActor
enum AccessibilityTextInsertionService {
    private static let logger = Logger(subsystem: "com.VoiceInk", category: "AccessibilityTextInsertionService")

    static func insertText(
        _ text: String,
        appPID: pid_t,
        preferredElement: AXUIElement?
    ) -> AccessibilityInsertOutcome {
        guard AXIsProcessTrusted() else {
            return .accessibilityNotTrusted
        }

        let appElement = AXUIElementCreateApplication(appPID)

        var candidates: [AXUIElement] = []
        if let preferredElement {
            candidates.append(preferredElement)
        }
        if let focusedElement = copyAXElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute) {
            candidates.append(focusedElement)
        }

        let uniqueCandidates = deduplicatedElements(candidates)
        guard !uniqueCandidates.isEmpty else {
            return .noFocusedElement
        }

        var lastOutcome: AccessibilityInsertOutcome = .noFocusedElement

        for element in uniqueCandidates {
            let outcome = attemptInsert(text, into: element)
            if outcome.isSuccess {
                return .success
            }
            lastOutcome = outcome
        }

        return lastOutcome
    }

    static func computeInsertion(
        originalText: String,
        selectedRange: CFRange?,
        insertionText: String
    ) -> TextInsertionComputationResult {
        let nsText = originalText as NSString
        let textLength = nsText.length

        var location: Int
        var length: Int

        if let selectedRange {
            if selectedRange.location == kCFNotFound {
                location = textLength
            } else {
                location = max(0, selectedRange.location)
            }
            length = max(0, selectedRange.length)
        } else {
            location = textLength
            length = 0
        }

        location = min(location, textLength)
        if location + length > textLength {
            length = textLength - location
        }

        let replacementRange = NSRange(location: location, length: length)
        let updatedText = nsText.replacingCharacters(in: replacementRange, with: insertionText)
        let caretLocation = location + (insertionText as NSString).length

        return TextInsertionComputationResult(updatedText: updatedText, caretLocation: caretLocation)
    }

    private static func attemptInsert(_ text: String, into element: AXUIElement) -> AccessibilityInsertOutcome {
        if isSecureTextField(element) {
            return .secureTextField
        }

        guard let currentValue = copyStringAttribute(element, attribute: kAXValueAttribute) else {
            return .unsupportedValueAttribute
        }

        let selectedRange = copySelectedTextRange(element)
        let computation = computeInsertion(
            originalText: currentValue,
            selectedRange: selectedRange,
            insertionText: text
        )

        guard isAttributeSettable(element, attribute: kAXValueAttribute) else {
            return .valueNotSettable
        }

        let setError = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            computation.updatedText as CFString
        )

        guard setError == .success else {
            return .failedToSetValue(code: setError.rawValue)
        }

        if isAttributeSettable(element, attribute: kAXSelectedTextRangeAttribute) {
            var caretRange = CFRange(location: computation.caretLocation, length: 0)
            if let axRange = AXValueCreate(.cfRange, &caretRange) {
                let selectionError = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    axRange
                )
                if selectionError != .success {
                    logger.notice("Inserted text but failed to update caret range: \(selectionError.rawValue, privacy: .public)")
                }
            }
        }

        return .success
    }

    private static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private static func copyAXElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copySelectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        let ok = AXValueGetValue(axValue, .cfRange, &range)
        return ok ? range : nil
    }

    private static func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard error == .success,
              let subrole = subroleValue as? String else {
            return false
        }

        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func deduplicatedElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var unique: [AXUIElement] = []

        for element in elements {
            if !unique.contains(where: { CFEqual($0, element) }) {
                unique.append(element)
            }
        }

        return unique
    }
}
