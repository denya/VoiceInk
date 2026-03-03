import Foundation
import AppKit
import ApplicationServices
import os

struct PasteTargetSnapshot: @unchecked Sendable {
    let appPID: pid_t?
    let bundleID: String?
    let capturedAt: Date
    let focusedWindowAX: AXUIElement?
    let focusedElementAX: AXUIElement?
    let featureEnabledForSession: Bool
}

enum PasteTargetRestoreResult {
    case targetUnavailable
    case restored(targetPID: pid_t)
}

@MainActor
enum PasteTargetService {
    private static let logger = Logger(subsystem: "com.VoiceInk", category: "PasteTargetService")
    private static let featureToggleKey = "isTargetAwarePasteExperimentalEnabled"
    private static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    static func captureCurrentTargetForSession() -> PasteTargetSnapshot {
        let isEnabled = UserDefaults.standard.bool(forKey: featureToggleKey)
        let captureDate = Date()

        guard isEnabled else {
            return PasteTargetSnapshot(
                appPID: nil,
                bundleID: nil,
                capturedAt: captureDate,
                focusedWindowAX: nil,
                focusedElementAX: nil,
                featureEnabledForSession: false
            )
        }

        guard let frontmostApp = resolveCaptureApplication() else {
            logger.notice("Target-aware paste enabled, but no frontmost application was found at capture time")
            return PasteTargetSnapshot(
                appPID: nil,
                bundleID: nil,
                capturedAt: captureDate,
                focusedWindowAX: nil,
                focusedElementAX: nil,
                featureEnabledForSession: true
            )
        }

        let pid = frontmostApp.processIdentifier
        var focusedWindow: AXUIElement?
        var focusedElement: AXUIElement?

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(pid)
            focusedWindow = copyAXElementAttribute(appElement, attribute: kAXFocusedWindowAttribute)
            focusedElement = copyAXElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute)
        } else {
            logger.notice("Accessibility not trusted while capturing paste target")
        }

        logger.notice(
            "Captured paste target: pid=\(pid, privacy: .public), bundle=\(frontmostApp.bundleIdentifier ?? "unknown", privacy: .public)"
        )

        return PasteTargetSnapshot(
            appPID: pid,
            bundleID: frontmostApp.bundleIdentifier,
            capturedAt: captureDate,
            focusedWindowAX: focusedWindow,
            focusedElementAX: focusedElement,
            featureEnabledForSession: true
        )
    }

    static func restoreTargetIfPossible(from snapshot: PasteTargetSnapshot) async -> PasteTargetRestoreResult {
        guard snapshot.featureEnabledForSession else {
            return .targetUnavailable
        }

        guard let application = runningApplication(for: snapshot) else {
            logger.notice("Captured paste target is unavailable (app is not running)")
            return .targetUnavailable
        }

        let targetPID = application.processIdentifier
        let didActivate = application.activate(options: [.activateAllWindows])
        guard didActivate else {
            logger.notice("Failed to activate captured app for paste restoration: pid=\(targetPID, privacy: .public)")
            return .targetUnavailable
        }

        // Give AppKit time to perform app activation before AX focus restoration.
        try? await Task.sleep(nanoseconds: 120_000_000)

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(targetPID)

            if let focusedWindowAX = snapshot.focusedWindowAX {
                // Probe whether the captured window element is still valid
                var probeValue: CFTypeRef?
                let probeError = AXUIElementCopyAttributeValue(focusedWindowAX, kAXRoleAttribute as CFString, &probeValue)
                if probeError == .success {
                    _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, focusedWindowAX)
                    _ = AXUIElementPerformAction(focusedWindowAX, kAXRaiseAction as CFString)
                } else {
                    logger.notice("Captured window element is stale, skipping window restoration")
                }
            }

            if let focusedElementAX = snapshot.focusedElementAX {
                var probeValue: CFTypeRef?
                let probeError = AXUIElementCopyAttributeValue(focusedElementAX, kAXRoleAttribute as CFString, &probeValue)
                if probeError == .success {
                    _ = AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, focusedElementAX)
                } else {
                    logger.notice("Captured element is stale, skipping element restoration")
                }
            }

            // Let focus changes settle before insertion/paste fallback.
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        logger.notice("Restored paste target to pid=\(targetPID, privacy: .public)")
        return .restored(targetPID: targetPID)
    }

    private static func runningApplication(for snapshot: PasteTargetSnapshot) -> NSRunningApplication? {
        if let pid = snapshot.appPID,
           pid > 0,
           let byPID = NSRunningApplication(processIdentifier: pid),
           !byPID.isTerminated {
            return byPID
        }

        if let bundleID = snapshot.bundleID, !bundleID.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })
        }

        return nil
    }

    private static func resolveCaptureApplication() -> NSRunningApplication? {
        if let frontmost = frontmostNonSelfApplication() {
            return frontmost
        }

        guard AXIsProcessTrusted() else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedAppElement = copyAXElementAttribute(systemWide, attribute: kAXFocusedApplicationAttribute) else {
            return frontmostNonSelfApplication()
        }

        var focusedPID: pid_t = 0
        AXUIElementGetPid(focusedAppElement, &focusedPID)
        guard focusedPID > 0,
              focusedPID != ownProcessID,
              let focusedApp = NSRunningApplication(processIdentifier: focusedPID),
              !focusedApp.isTerminated else {
            return frontmostNonSelfApplication()
        }

        return focusedApp
    }

    private static func frontmostNonSelfApplication() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ownProcessID else {
            return nil
        }
        return frontmost
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

        return (value as! AXUIElement)
    }
}
