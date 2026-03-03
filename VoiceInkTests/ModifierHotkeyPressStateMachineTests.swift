import Testing
@testable import VoiceInk

struct ModifierHotkeyPressStateMachineTests {
    @Test
    func offModeCleanPressReleaseToggles() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        let action = machine.endPress(
            doubleTapEnabled: false,
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .toggle)
    }

    @Test
    func offModeChordWithRegularKeyDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        machine.markChord()
        let action = machine.endPress(
            doubleTapEnabled: false,
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func offModeChordWithSecondModifierDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        machine.markChord()
        let action = machine.endPress(
            doubleTapEnabled: false,
            eventTime: 1.2,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func onModeSingleQuickTapDoesNothing() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        let action = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func onModeDoubleTapWithinWindowToggles() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        _ = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )
        machine.beginPress(keyCode: 0x36, eventTime: 1.3)
        let action = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.35,
            shortPressThreshold: 0.5
        )

        #expect(action == .toggle)
    }

    @Test
    func onModeDoubleTapOutsideWindowDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        _ = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.1,
            shortPressThreshold: 0.5
        )
        machine.beginPress(keyCode: 0x36, eventTime: 1.5)
        let action = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.55,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func onModeHoldStartsAndReleaseStopsPushToTalk() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        #expect(machine.canStartPushToTalk(doubleTapEnabled: true))
        machine.markPushToTalkStarted()
        let action = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.7,
            shortPressThreshold: 0.5
        )

        #expect(action == .stopPushToTalk)
    }

    @Test
    func onModeChordBeforeHoldDoesNotStartOrToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        machine.markChord()
        #expect(!machine.canStartPushToTalk(doubleTapEnabled: true))
        let action = machine.endPress(
            doubleTapEnabled: true,
            eventTime: 1.6,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }

    @Test
    func resetClearsAllSessionState() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        machine.markChord()
        machine.markPushToTalkStarted()
        machine.reset()

        #expect(!machine.isPressed)
        #expect(machine.activeModifierKeyCode == nil)
        #expect(machine.pressStartTime == nil)
        #expect(!machine.didChordWithAnotherKey)
        #expect(!machine.didStartPushToTalk)
        #expect(machine.lastCleanTapReleaseTime == nil)
        #expect(
            machine.endPress(
                doubleTapEnabled: true,
                eventTime: 2.0,
                shortPressThreshold: 0.5
            ) == .none
        )
    }

    @Test
    func offModeLongPressDoesNotToggle() {
        var machine = ModifierHotkeyPressStateMachine()

        machine.beginPress(keyCode: 0x36, eventTime: 1.0)
        let action = machine.endPress(
            doubleTapEnabled: false,
            eventTime: 1.7,
            shortPressThreshold: 0.5
        )

        #expect(action == .none)
    }
}
