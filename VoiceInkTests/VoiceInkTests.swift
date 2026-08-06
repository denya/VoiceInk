//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func enhancementOutputFilterUnwrapsTranscriptEnvelope() {
        let output = """
            <TRANSCRIPT>
            Cleaned transcript.
            </TRANSCRIPT>
            """

        #expect(
            AIEnhancementOutputFilter.filter(output, preservingMarkupFrom: "Cleaned transcript.")
                == "Cleaned transcript."
        )
    }

    @Test func enhancementOutputFilterUnwrapsGenericOuterEnvelope() {
        let output = """
            <MODEL_OUTPUT format="plain-text">
            Cleaned transcript.
            </MODEL_OUTPUT>
            """

        #expect(
            AIEnhancementOutputFilter.filter(output, preservingMarkupFrom: "Cleaned transcript.")
                == "Cleaned transcript."
        )
    }

    @Test func enhancementOutputFilterPreservesTagsInsideSpokenContent() {
        let output = "I said <TRANSCRIPT>hello</TRANSCRIPT> during the recording."

        #expect(AIEnhancementOutputFilter.filter(output, preservingMarkupFrom: output) == output)
    }

    @Test func enhancementOutputFilterRemovesReasoningBeforeUnwrappingEnvelope() {
        let output = """
            <thinking>Internal reasoning.</thinking>
            <TRANSCRIPT>
            Cleaned transcript.
            </TRANSCRIPT>
            """

        #expect(
            AIEnhancementOutputFilter.filter(output, preservingMarkupFrom: "Cleaned transcript.")
                == "Cleaned transcript."
        )
    }

    @Test func enhancementOutputFilterPreservesOuterMarkupWithoutTranscriptContext() {
        let output = "<response>Intentional assistant XML.</response>"

        #expect(AIEnhancementOutputFilter.filter(output) == output)
    }

    @Test func currentEnhancementCatalogsAndFallbackChain() {
        let geminiModels = Set(AIProvider.gemini.availableModels)
        #expect(
            Set([
                "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite",
                "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools",
                "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview", "gemini-3-flash-preview",
                "gemini-2.5-flash", "gemini-2.5-flash-lite",
            ]).isSubset(of: geminiModels)
        )

        let anthropicModels = Set(AIProvider.anthropic.availableModels)
        #expect(
            Set([
                "claude-fable-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
                "claude-opus-4-6", "claude-opus-4-5-20251101", "claude-sonnet-5",
                "claude-sonnet-4-6", "claude-sonnet-4-5-20250929", "claude-haiku-4-5",
            ]).isSubset(of: anthropicModels)
        )

        #expect(
            AIService.normalizedProviderChain(
                primary: .gemini,
                fallbacks: [.anthropic, .gemini],
                fallbackEnabled: true
            ) == [.gemini, .anthropic]
        )
    }

}
