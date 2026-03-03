import AppKit
import Foundation

enum ModifierHotkeyReleaseAction: Equatable {
    case none
    case toggle
    case stopPushToTalk
}

struct ModifierHotkeyPressStateMachine {
    private(set) var isPressed = false
    private(set) var activeModifierKeyCode: UInt16?
    private(set) var pressStartTime: TimeInterval?
    private(set) var didChordWithAnotherKey = false
    private(set) var didStartPushToTalk = false
    private(set) var lastCleanTapReleaseTime: TimeInterval?

    let doubleTapWindow: TimeInterval

    init(doubleTapWindow: TimeInterval = 0.3) {
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func beginPress(keyCode: UInt16, eventTime: TimeInterval) {
        isPressed = true
        activeModifierKeyCode = keyCode
        pressStartTime = eventTime
        didChordWithAnotherKey = false
        didStartPushToTalk = false
    }

    mutating func markChord() {
        guard isPressed else { return }
        didChordWithAnotherKey = true
    }

    func canStartPushToTalk(doubleTapEnabled: Bool) -> Bool {
        doubleTapEnabled && isPressed && !didChordWithAnotherKey && !didStartPushToTalk
    }

    mutating func markPushToTalkStarted() {
        guard isPressed else { return }
        didStartPushToTalk = true
        lastCleanTapReleaseTime = nil
    }

    mutating func endPress(
        doubleTapEnabled: Bool,
        eventTime: TimeInterval,
        shortPressThreshold: TimeInterval
    ) -> ModifierHotkeyReleaseAction {
        guard isPressed else { return .none }
        let pressDuration = pressStartTime.map { eventTime - $0 } ?? 0

        defer {
            isPressed = false
            activeModifierKeyCode = nil
            pressStartTime = nil
            didChordWithAnotherKey = false
            didStartPushToTalk = false
        }

        if didStartPushToTalk {
            lastCleanTapReleaseTime = nil
            return .stopPushToTalk
        }

        if didChordWithAnotherKey {
            lastCleanTapReleaseTime = nil
            return .none
        }

        let isShortPress = pressDuration < shortPressThreshold

        if !doubleTapEnabled {
            lastCleanTapReleaseTime = nil
            return isShortPress ? .toggle : .none
        }

        guard isShortPress else {
            lastCleanTapReleaseTime = nil
            return .none
        }

        if let lastRelease = lastCleanTapReleaseTime,
           eventTime - lastRelease <= doubleTapWindow {
            lastCleanTapReleaseTime = nil
            return .toggle
        }

        lastCleanTapReleaseTime = eventTime
        return .none
    }

    mutating func reset() {
        isPressed = false
        activeModifierKeyCode = nil
        pressStartTime = nil
        didChordWithAnotherKey = false
        didStartPushToTalk = false
        lastCleanTapReleaseTime = nil
    }
}

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    @Published var isDoubleTapForHandsFreeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDoubleTapForHandsFreeEnabled, forKey: Self.doubleTapForHandsFreeKey)
            shortcutModeHandler.reset()
        }
    }

    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }

    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?
    private static let doubleTapForHandsFreeKey = "isDoubleTapForHandsFreeEnabled"

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")
        self.isDoubleTapForHandsFreeEnabled = UserDefaults.standard.bool(forKey: Self.doubleTapForHandsFreeKey)

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            isDoubleTapForHandsFreeEnabled: {
                UserDefaults.standard.bool(forKey: Self.doubleTapForHandsFreeKey)
            },
            isModifierOnlyShortcut: { action in
                ShortcutStore.shortcut(for: action)?.isModifierOnly == true
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()

        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }

    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000  // ms to ns
                    try await Task.sleep(nanoseconds: delay)

                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }

    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()

        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()

        shortcutModeHandler.reset()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    var hasModifierRecordingShortcutConfigured: Bool {
        let primaryIsModifier = primaryRecordingShortcut == .custom &&
            ShortcutStore.shortcut(for: .primaryRecording)?.isModifierOnly == true
        let secondaryIsModifier = secondaryRecordingShortcut == .custom &&
            ShortcutStore.shortcut(for: .secondaryRecording)?.isModifierOnly == true
        return primaryIsModifier || secondaryIsModifier
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    private let isDoubleTapForHandsFreeEnabled: @MainActor () -> Bool
    private let isModifierOnlyShortcut: @MainActor (ShortcutAction) -> Bool

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var lastShortcutPressTime: Date?
    private var modifierPressState = ModifierHotkeyPressStateMachine()
    private var modifierHoldTask: Task<Void, Never>?
    private var activeModifierModeId: UUID?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        isDoubleTapForHandsFreeEnabled: @escaping @MainActor () -> Bool,
        isModifierOnlyShortcut: @escaping @MainActor (ShortcutAction) -> Bool
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.isDoubleTapForHandsFreeEnabled = isDoubleTapForHandsFreeEnabled
        self.isModifierOnlyShortcut = isModifierOnlyShortcut
    }

    func reset() {
        modifierHoldTask?.cancel()
        modifierHoldTask = nil
        modifierPressState.reset()
        activeModifierModeId = nil
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if usesModifierReleaseGate(action: action, mode: mode) {
            await handleModifierReleaseGateKeyDown(action: action, eventTime: eventTime, mode: mode, modeId: modeId)
            return
        }

        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = Date()
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if usesModifierReleaseGate(action: action, mode: mode) {
            await handleModifierReleaseGateKeyUp(action: action, eventTime: eventTime, mode: mode, modeId: modeId)
            return
        }

        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        if usesModifierReleaseGate(action: action, mode: .hybrid),
           isShortcutPressed,
           activeRecordingShortcutAction == action,
           modifierPressState.isPressed {
            if !modifierPressState.didStartPushToTalk {
                modifierPressState.markChord()
                modifierHoldTask?.cancel()
                modifierHoldTask = nil
            }
            return
        }

        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }

    private func usesModifierReleaseGate(action: ShortcutAction, mode: RecordingShortcutManager.Mode) -> Bool {
        isModifierOnlyShortcut(action) && mode != .pushToTalk
    }

    private func handleModifierReleaseGateKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID?
    ) async {
        guard !isShortcutPressed else { return }

        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeModifierModeId = modeId
        modifierPressState.beginPress(keyCode: 0, eventTime: eventTime)

        guard mode == .hybrid, isDoubleTapForHandsFreeEnabled() else { return }

        modifierHoldTask?.cancel()
        modifierHoldTask = Task { [weak self, eventTime] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.hybridPressThreshold ?? 0.5) * 1_000_000_000))
                await self?.handleModifierHoldThresholdReached(expectedPressStartTime: eventTime)
            } catch {
                // Cancelled
            }
        }
    }

    private func handleModifierReleaseGateKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID?
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }

        modifierHoldTask?.cancel()
        modifierHoldTask = nil
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeModifierModeId = nil

        let releaseAction = modifierPressState.endPress(
            doubleTapEnabled: mode == .hybrid && isDoubleTapForHandsFreeEnabled(),
            eventTime: eventTime,
            shortPressThreshold: hybridPressThreshold
        )

        switch releaseAction {
        case .none:
            return
        case .toggle:
            guard canHandleShortcutAction() else { return }
            await toggleRecorderPanel(modeId)
        case .stopPushToTalk:
            guard canHandleShortcutAction() else { return }
            await toggleRecorderPanel(modeId)
        }
    }

    private func handleModifierHoldThresholdReached(expectedPressStartTime: TimeInterval) async {
        guard modifierPressState.pressStartTime == expectedPressStartTime,
              modifierPressState.canStartPushToTalk(doubleTapEnabled: isDoubleTapForHandsFreeEnabled()),
              canHandleShortcutAction() else {
            return
        }

        modifierPressState.markPushToTalkStarted()
        await toggleRecorderPanel(activeModifierModeId)
    }
}
