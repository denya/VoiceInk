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

}
