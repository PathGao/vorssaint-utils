// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Turns one chosen key combination into Finder's native Rename command.
/// Unrelated keys stay on the tap thread's fast path, and the tap only lives
/// while the feature is on, Accessibility is available and this login session
/// is the one on screen.
final class FinderRenameService {
    static let shared = FinderRenameService()

    private static let finderBundleID = "com.apple.finder"

    private let routeLock = NSLock()
    private var routeShortcut = GlobalShortcut.finderRenameDefault

    private let lifecycleLock = NSLock()
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var shouldStopTapThread = false
    private var pendingStartAfterStop = false

    private init() {
        // A filter tap owned by a switched-away login session keeps its place
        // in the chain, so the window server waits out the tap timeout on every
        // key the account on screen presses (issue #1075). Hand the tap back on
        // resign and build it from the preferences again on the way in.
        SessionActivity.shared.onChange { [weak self] _ in
            self?.syncWithPreferences()
        }
    }

    func syncWithPreferences() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.finderRenameShortcut,
                                            fallback: .finderRenameDefault)
        routeLock.withLock { routeShortcut = shortcut }
        let enabled = AppFeature.finderRename.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.finderRenameEnabled)
        // Accessibility is asked of the system and not of `Permissions.shared`,
        // whose answer is a poll up to `PermissionPollingSupport.interval` old.
        // The re-arm hands a revoked tap to this sync to be stopped, and a
        // stale grant here would install it straight back.
        if SessionActivitySupport.tapShouldRun(
            featureWanted: enabled,
            accessibilityGranted: AXIsProcessTrusted(),
            sessionIsActive: SessionActivity.shared.isActive) {
            installTap()
        } else {
            removeTap()
        }
    }

    func suspend() {
        removeTap()
    }

    private func installTap() {
        let thread = lifecycleLock.withLock { () -> Thread? in
            if tapThread != nil {
                if shouldStopTapThread { pendingStartAfterStop = true }
                return nil
            }
            shouldStopTapThread = false
            pendingStartAfterStop = false
            let thread = Thread { [weak self] in self?.runEventTap() }
            thread.name = "Vorssaint Finder Rename"
            thread.qualityOfService = .userInteractive
            tapThread = thread
            return thread
        }
        thread?.start()
    }

    private func removeTap() {
        let snapshot = lifecycleLock.withLock {
            () -> (runLoop: CFRunLoop?, tap: CFMachPort?, threadExists: Bool) in
            shouldStopTapThread = true
            pendingStartAfterStop = false
            return (tapRunLoop, tap, tapThread != nil)
        }
        if let tap = snapshot.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = snapshot.runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else if !snapshot.threadExists {
            lifecycleLock.withLock {
                shouldStopTapThread = false
                tapThread = nil
            }
        }
    }

    private func runEventTap() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            lifecycleLock.withLock { tapRunLoop = runLoop }

            let shouldStop = lifecycleLock.withLock { shouldStopTapThread }
            guard !shouldStop else {
                if clearEventTapThread() { installTap() }
                return
            }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                // The Super Key decorates shortcuts before this tap sees them.
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let service = Unmanaged<FinderRenameService>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    return service.route(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                _ = clearEventTapThread()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            lifecycleLock.withLock { self.tap = tap }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            if lifecycleLock.withLock({ shouldStopTapThread }) {
                CGEvent.tapEnable(tap: tap, enable: false)
            } else {
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
            if clearEventTapThread() { installTap() }
        }
    }

    private func clearEventTapThread() -> Bool {
        lifecycleLock.withLock {
            let shouldRestart = pendingStartAfterStop
            tap = nil
            tapRunLoop = nil
            tapThread = nil
            shouldStopTapThread = false
            pendingStartAfterStop = false
            return shouldRestart
        }
    }

    /// Puts the tap back after the window server disabled it, unless a stop is
    /// already on its way and the port is about to go. Main thread.
    private func rearmDisabledTap() {
        let currentTap = lifecycleLock.withLock { shouldStopTapThread ? nil : tap }
        if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
    }

    /// Runs on the tap thread. Every unrelated key returns after an in-memory
    /// comparison; Finder and Accessibility are consulted only for the chosen
    /// combination.
    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A tap put straight back is a tap put back into whatever session
            // is on screen now (issue #1075). The flag that answers that is
            // written on the main thread and this callback runs on the tap's
            // own thread, so the question is asked where the answer lives
            // rather than read across the two. Accessibility is asked in the
            // same place and for the same reason as the sync: this tap modifies
            // events, so a revoked grant has to end it rather than put it back.
            // Leaving the tap disabled until then is the safe direction — the
            // combination reaches Finder untapped, which is how the feature is
            // off.
            DispatchQueue.main.async { [weak self] in
                if SessionActivity.shared.isActive, AXIsProcessTrusted() {
                    self?.rearmDisabledTap()
                } else {
                    self?.syncWithPreferences()
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let shortcut = routeLock.withLock { routeShortcut }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = GlobalShortcutModifiers(cgFlags: event.flags)
        guard shortcut.matches(keyCode: keyCode, modifiers: modifiers),
              AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == Self.finderBundleID,
              FinderRenameSupport.acceptsFocusedRole(focusedRole(for: front.processIdentifier)),
              let replacement = event.copy()
        else { return Unmanaged.passUnretained(event) }

        replacement.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Return))
        replacement.flags = []
        return Unmanaged.passRetained(replacement)
    }

    private func focusedRole(for pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                            &role) == .success,
              let role, CFGetTypeID(role) == CFStringGetTypeID()
        else { return nil }
        return role as? String
    }
}
