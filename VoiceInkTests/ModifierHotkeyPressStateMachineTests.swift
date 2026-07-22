import Testing
@testable import VoiceInk

struct ModifierHotkeyPressStateMachineTests {
    @Test
    func cleanShortPressReleaseToggles() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(eventTime: 1.0)
        let action = machine.endPress(
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .toggle)
    }

    @Test
    func chordWithAnotherKeyDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(eventTime: 1.0)
        machine.markChord()
        let action = machine.endPress(
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func longPressDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(eventTime: 1.0)
        let action = machine.endPress(
            eventTime: 1.7,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func releaseWithoutPressDoesNothing() {
        var machine = ModifierHotkeyPressStateMachine()

        let action = machine.endPress(
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func resetClearsAllSessionState() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(eventTime: 1.0)
        machine.markChord()
        machine.reset()

        #expect(!machine.isPressed)
        #expect(machine.pressStartTime == nil)
        #expect(!machine.didChordWithAnotherKey)
        #expect(
            machine.endPress(
                eventTime: 2.0,
                shortPressThreshold: 0.5
            ) == .none
        )
    }
}
