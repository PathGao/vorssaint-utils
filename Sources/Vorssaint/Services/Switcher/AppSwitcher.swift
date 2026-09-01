// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import SwiftUI

/// The window switcher: a global event tap takes over the configured shortcut,
/// and while its modifiers are held a non-activating panel cycles through real
/// windows. Releasing commits, middle-clicking a card or pressing W closes the
/// highlighted window, and Q quits its app. When the optional pin-search
/// preference is enabled, S pins the search field open (so typing no longer
/// needs the modifier held). Esc and a click outside cancel. The panel joins
/// every Space and fullscreen app, so the switcher is available wherever the
/// user is.
///
/// What a session *is* lives in `SwitcherSession`; this class is the adapter
/// around it. It owns the event tap, the panel and the observers, turns real
/// input into session events, and performs the effects the session hands back.
/// The `@Published` properties below are the session's state projected for
/// SwiftUI: they are written only while performing an effect, never as a
/// decision of their own.
final class AppSwitcher: ObservableObject {
    static let shared = AppSwitcher()

    @Published private(set) var windows: [SwitcherItem] = []
    @Published private(set) var previews: [CGWindowID: CGImage] = [:]
    @Published private(set) var selectedIndex = 0 {
        didSet {
            guard oldValue != selectedIndex else { return }
            updateIconRowLayoutForCurrentSelection()
            revealSelectedIconInVisibleRow()
            if sessionActive, usesIconRowLayout {
                resizePanel()
            }
        }
    }
    @Published private(set) var grid = SwitcherGrid.empty
    @Published private(set) var iconRowLayout = SwitcherIconRowLayout.empty
    /// First icon currently shown in an overflow row. The row steps this
    /// index by one when the pointer parks on the last visible icon.
    @Published private(set) var iconRowFirstVisibleIndex = 0
    @Published private(set) var searchQuery = ""
    @Published private(set) var isSearchPinned = false
    @Published private(set) var totalWindowCount = 0
    @Published private(set) var sessionScope: SwitcherSessionScope = .allApps

    /// The session state machine. Main thread only.
    private var session = SwitcherSession()

    /// Whether a session is open, as the tap thread sees it: the stored value
    /// lives under `routeLock` because the tap routes every keystroke by it.
    /// `session.isActive` is the authority; this is its cross-thread copy, and
    /// both are written on the main thread in the same breath.
    private var sessionActive: Bool {
        get { routeLock.withLock { routeSessionActive } }
        set { routeLock.withLock { routeSessionActive = newValue } }
    }
    private var panel: NSPanel?

    // The tap lives on a dedicated thread: an active keyDown tap makes the
    // window server hold every keystroke in the login session until this
    // process answers, so the callback must never queue behind main-thread
    // work. On the main run loop, any stall here delayed keys system-wide
    // and then released them in a burst (issue #275). Same lifecycle shape
    // as the keyboard debounce tap.
    private let lifecycleLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var shouldStopTapThread = false
    private var pendingStartAfterStop = false
    /// Alive only while the Switcher's tap needs layout labels off main.
    private var keyboardLayoutObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var wakeRetry: DispatchWorkItem?

    /// The little state the tap thread needs to route an event without
    /// touching the main thread; mutated only under `routeLock`.
    private let routeLock = NSLock()
    private var routeSessionActive = false
    private var routeShortcut = GlobalShortcut.switcherDefault
    private var routeWindowShortcut = GlobalShortcut.switcherWindowDefault
    private var routeCapturing = false
    private var routeCanStartSession = false
    private var routePending = SwitcherPendingStarts()

    /// Enumeration touches every regular app through Accessibility, so it runs
    /// away from the event tap on one serial queue.
    private let enumerationQueue = DispatchQueue(label: "com.vorssaint.switcher.enumeration",
                                                  qos: .userInitiated)
    private var pendingShow: DispatchWorkItem?
    /// Mouse position when the panel appeared; hover is inert until it moves.
    private var hoverAnchor: NSPoint?
    /// The card currently under the pointer. Kept separate from selection so
    /// a middle click on panel chrome can never close an unrelated window.
    private var hoveredWindowIndex: Int?
    private var swallowingMiddleMouseUp = false
    /// Fires while the pointer stays on the last visible overflow icon.
    private var iconRowEdgeHoverWork: DispatchWorkItem?
    private var iconRowEdgeHoverIndex: Int?

    // Virtual key codes handled during a session.
    private enum KeyCode {
        static let tab: Int64 = 48
        static let delete: Int64 = 51
        static let escape: Int64 = 53
        static let enter: Int64 = 36
        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126
    }

    private init() {}

    private var isTapLive: Bool {
        lifecycleLock.withLock {
            guard let tap else { return false }
            return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
        }
    }

    /// Applies the persisted preference; safe to call repeatedly.
    func syncWithPreferences() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.switcherShortcut,
                                            fallback: .switcherDefault)
        let windowShortcut = GlobalShortcut.saved(for: DefaultsKey.switcherWindowShortcut,
                                                  fallback: .switcherWindowDefault)
        routeLock.withLock {
            routeShortcut = shortcut
            routeWindowShortcut = windowShortcut
        }
        let enabled = AppFeature.switcher.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.switcherEnabled)
        let canStartSession = enabled && Permissions.shared.accessibility
        routeLock.withLock { routeCanStartSession = canStartSession }
        if canStartSession {
            startObservingKeyboardLayout()
            startObservingWake()
            installTap()
            // A live tap can pick up a shortcut change without rebuilding;
            // apply here so the native hotkeys follow immediately.
            if !UserDefaults.standard.bool(forKey: DefaultsKey.switcherTakeOverSystemShortcuts) {
                restoreNativeHotkeys()
            } else {
                applyNativeHotkeySuppressionIfTapLive()
            }
            // Build the panel and its SwiftUI tree now: the first hosting-view
            // render costs hundreds of milliseconds, far too slow to pay on
            // the first ⌘Tab.
            let panel = ensurePanel()
            panel.contentViewController?.view.layoutSubtreeIfNeeded()
            if !capturesPreviews {
                WindowPreviewProvider.shared.stopWarming()
            } else {
                WindowPreviewProvider.shared.startWarming()
            }
        } else {
            restoreNativeHotkeys()
            stopObservingKeyboardLayout()
            stopObservingWake()
            removeTap()
            WindowPreviewProvider.shared.stopWarming()
        }
    }

    /// Force-stops the tap regardless of the preference. Used before the app
    /// resets its own permissions, so a revoked Accessibility grant can never
    /// leave a live tap behind.
    func suspend() {
        restoreNativeHotkeys()
        stopObservingWake()
        routeLock.withLock { routeCanStartSession = false }
        removeTap()
    }

    /// While a shortcut field is listening, every key has to reach it, even
    /// the switcher's own combination. This is a flag the routing reads, not a
    /// teardown: tearing the tap down and rebuilding it per recording would
    /// churn the window server's keyboard path for no reason (issue #275).
    /// Main thread only, like every other write to the routing state.
    func setCapturingShortcut(_ capturing: Bool) {
        if capturing, sessionActive { cancelSession() }
        routeLock.withLock {
            routeCapturing = capturing
            if capturing {
                routePending.clear()
            }
        }
    }

    // MARK: - Event tap

    private func startObservingKeyboardLayout() {
        GlobalShortcut.refreshLayoutLabels()
        guard keyboardLayoutObserver == nil else { return }
        keyboardLayoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in GlobalShortcut.refreshLayoutLabels() }
    }

    private func stopObservingKeyboardLayout() {
        if let keyboardLayoutObserver {
            DistributedNotificationCenter.default().removeObserver(keyboardLayoutObserver)
        }
        keyboardLayoutObserver = nil
    }

    private func startObservingWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.recoverTapAfterWake() }
    }

    private func stopObservingWake() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        wakeRetry?.cancel()
        wakeRetry = nil
    }

    private func recoverTapAfterWake() {
        reconcileTakeover()
        wakeRetry?.cancel()
        // Input services and Dock hotkeys can settle after the workspace wake
        // itself. Recheck once so neither half of the takeover stays stale.
        let retry = DispatchWorkItem { [weak self] in self?.reconcileTakeover() }
        wakeRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)
    }

    private func reconcileTakeover() {
        guard AppFeature.switcher.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.switcherEnabled),
              Permissions.shared.accessibility else {
            restoreNativeHotkeys()
            return
        }
        if !isTapLive {
            restoreNativeHotkeys()
            removeTap()
            installTap()
        } else {
            applyNativeHotkeySuppressionIfTapLive()
        }
    }

    private func installTap() {
        // Thread creation and the tapThread assignment share one critical
        // section with the decision, so a concurrent stop can never observe
        // a committed start without its thread.
        let thread = lifecycleLock.withLock { () -> Thread? in
            if tapThread != nil {
                if shouldStopTapThread { pendingStartAfterStop = true }
                return nil
            }
            shouldStopTapThread = false
            pendingStartAfterStop = false
            let thread = Thread { [weak self] in
                self?.runEventTap()
            }
            thread.name = "Vorssaint Switcher"
            thread.qualityOfService = .userInteractive
            tapThread = thread
            return thread
        }
        thread?.start()
    }

    private func removeTap() {
        if sessionActive { cancelSession() }
        routeLock.withLock { routePending.clear() }
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

            let shouldStopBeforeCreatingTap = lifecycleLock.withLock { shouldStopTapThread }
            guard !shouldStopBeforeCreatingTap else {
                if clearEventTapThread() { installTap() }
                return
            }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let switcher = Unmanaged<AppSwitcher>.fromOpaque(userInfo).takeUnretainedValue()
                    return switcher.route(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                _ = clearEventTapThread()
                // Without a tap there is nothing to replace ⌘Tab, so give the
                // system switcher back rather than leaving the shortcut dead.
                DispatchQueue.main.async { [weak self] in self?.restoreNativeHotkeys() }
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            lifecycleLock.withLock {
                self.tap = tap
                runLoopSource = source
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            let shouldStop = lifecycleLock.withLock { shouldStopTapThread }
            if shouldStop {
                CGEvent.tapEnable(tap: tap, enable: false)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.applyNativeHotkeySuppressionIfTapLive()
                }
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
            if clearEventTapThread() { installTap() }
        }
    }

    /// Dock's ⌘Tab handler is a symbolic hotkey, not an event the session tap
    /// can swallow. Switch those hotkeys off only while this tap is actually
    /// installed, so a missing Accessibility grant never kills both switchers.
    private func applyNativeHotkeySuppression() {
        let (apps, windows) = routeLock.withLock { (routeShortcut, routeWindowShortcut) }
        let takeOver = UserDefaults.standard.bool(
            forKey: DefaultsKey.switcherTakeOverSystemShortcuts)
        SwitcherNativeHotkeys.apply(
            SwitcherSupport.nativeHotkeysToSuppress(
                takeOverSystemShortcuts: takeOver,
                appsShortcut: apps,
                windowShortcut: windows,
                nativeShortcuts: SwitcherNativeHotkeys.configuredShortcuts())
        )
    }

    private func applyNativeHotkeySuppressionIfTapLive() {
        let canStart = routeLock.withLock { routeCanStartSession }
        guard isTapLive, canStart else { return }
        applyNativeHotkeySuppression()
    }

    private func restoreNativeHotkeys() {
        SwitcherNativeHotkeys.apply([])
    }

    private func clearEventTapThread() -> Bool {
        lifecycleLock.withLock {
            let shouldRestart = pendingStartAfterStop
            tap = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
            shouldStopTapThread = false
            pendingStartAfterStop = false
            return shouldRestart
        }
    }

    /// Runs on the tap thread. The window server holds every keystroke in
    /// the login session until this returns, so the common case — no session
    /// open, key is not the shortcut — must stay pure math and never wait on
    /// the main thread. Only events the switcher may actually consume hop to
    /// the main thread, and those are rare by definition: one shortcut press,
    /// then the handful of keys typed while the panel is up.
    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never resurrect a tap that removeTap is already tearing down.
            let currentTap = lifecycleLock.withLock { shouldStopTapThread ? nil : tap }
            if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
            routeLock.withLock { routePending.clear() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionActive else { return }
                self.cancelSession()
            }
            return Unmanaged.passUnretained(event)
        }

        let (active, shortcut, windowShortcut, capturing, canStartSession, hasPendingStart) = routeLock.withLock {
            (routeSessionActive, routeShortcut, routeWindowShortcut, routeCapturing,
             routeCanStartSession, routePending.isPending)
        }
        // A shortcut field in Settings has the keyboard: hand every key
        // straight through so the user can record this feature's own
        // combination instead of opening the switcher with it.
        if capturing { return Unmanaged.passUnretained(event) }
        if !active {
            guard canStartSession else { return Unmanaged.passUnretained(event) }
            if type == .flagsChanged {
                let stillInactive = routeLock.withLock { () -> Bool in
                    guard !routeSessionActive else { return false }
                    if let pending = routePending.current,
                       !pending.shortcut.requiredModifiersHeld(in: event.flags) {
                        // A quick flick still commits once enumeration finishes,
                        // but can never flash a panel after the key was released.
                        routePending.noteShortcutModifiersReleased()
                    }
                    return true
                }
                if stillInactive { return Unmanaged.passUnretained(event) }
                var verdict: Unmanaged<CGEvent>?
                DispatchQueue.main.sync {
                    verdict = self.handle(type: type, event: event)
                }
                return verdict
            }
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .otherMouseUp {
                let stillInactive = routeLock.withLock { () -> Bool in
                    guard !routeSessionActive else { return false }
                    routePending.clear()
                    return true
                }
                if stillInactive { return Unmanaged.passUnretained(event) }
                var verdict: Unmanaged<CGEvent>?
                DispatchQueue.main.sync {
                    verdict = self.handle(type: type, event: event)
                }
                return verdict
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let matchesApps = shortcut.matches(event: event, allowingExtraShift: true)
            let matchesWindows = !matchesApps
                && (windowShortcut.matches(event: event, allowingExtraShift: true)
                    || windowShortcut.matchesByCharacter(event: event))
            let matchesShortcut = matchesApps || matchesWindows
            guard matchesShortcut || hasPendingStart else {
                return Unmanaged.passUnretained(event)
            }
            let pendingKeyDecision = routeLock.withLock { () -> SwitcherPendingKeyDecision in
                let decision = SwitcherSupport.pendingKeyDecision(
                    sessionIsActive: routeSessionActive,
                    hasPendingStart: routePending.isPending,
                    commitWhenReady: routePending.current?.commitWhenReady ?? false,
                    matchesShortcut: matchesShortcut
                )
                if decision == .cancelAndSwallow {
                    routePending.clear()
                }
                return decision
            }
            switch pendingKeyDecision {
            case .swallow, .cancelAndSwallow:
                return nil
            case .handleActiveSession:
                break
            case .routeShortcut:
                guard matchesShortcut else { return Unmanaged.passUnretained(event) }

                let requestedShortcut = matchesWindows ? windowShortcut : shortcut
                let requestedScope: SwitcherSessionScope = matchesWindows ? .frontmostApp : .allApps
                let reversed: Bool
                if matchesWindows {
                    let positional = windowShortcut.matches(event: event, allowingExtraShift: true)
                    reversed = SwitcherSupport.windowNavigationDelta(
                        positionalMatch: positional,
                        shiftIsNavigationModifier: windowShortcut.shiftIsNavigationModifier,
                        shiftHeld: event.flags.contains(.maskShift)
                    ) < 0
                } else {
                    reversed = shortcut.shiftIsNavigationModifier && event.flags.contains(.maskShift)
                }

                var generationToSchedule: UInt64?
                let claimedWhileInactive = routeLock.withLock { () -> Bool in
                    guard !routeSessionActive else { return false }
                    generationToSchedule = routePending.claim(shortcut: requestedShortcut,
                                                              scope: requestedScope,
                                                              reversed: reversed)
                    return true
                }
                if claimedWhileInactive {
                    if let generationToSchedule {
                        // The active tap returns before the main queue performs
                        // any TCC, window-server or Accessibility work.
                        DispatchQueue.main.async { [weak self] in
                            self?.beginPendingSession(generation: generationToSchedule)
                        }
                    }
                    return nil
                }
            }
        }

        var verdict: Unmanaged<CGEvent>?
        DispatchQueue.main.sync {
            verdict = self.handle(type: type, event: event)
        }
        return verdict
    }

    /// Main-thread side of the tap; reached only for events `route` decided
    /// the switcher may care about.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // With Accessibility revoked the AX lookups behind a session would hang
        // and freeze input; pass events through and drop any session that was
        // open. Cached flag: a live TCC round-trip is too heavy per key.
        guard Permissions.shared.accessibility else {
            if sessionActive { cancelSession() }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            let swallows = perform(session.apply(.keyDown(decodeKey(event)),
                                                 environment: sessionEnvironment()))
            return swallows ? nil : Unmanaged.passUnretained(event)
        case .flagsChanged:
            let outcome = session.apply(
                .modifiersChanged(shortcutModifiersHeld: session.shortcut.map {
                                      $0.requiredModifiersHeld(in: event.flags)
                                  },
                                  shiftHeld: event.flags.contains(.maskShift),
                                  now: ProcessInfo.processInfo.systemUptime),
                environment: sessionEnvironment())
            return perform(outcome) ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if type == .otherMouseDown,
               let panel,
               let hoveredWindowIndex,
               windows.indices.contains(hoveredWindowIndex),
               SwitcherSupport.isMiddleClickInsidePanel(
                   eventType: type,
                   buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
                   panelIsVisible: panel.isVisible,
                   panelFrame: panel.frame,
                   location: NSEvent.mouseLocation,
                   itemIsHovered: true
               ) {
                swallowingMiddleMouseUp = true
                self.hoveredWindowIndex = nil
                closeWindow(windows[hoveredWindowIndex])
                return nil
            }
            swallowingMiddleMouseUp = false
            dismissForClickOutsidePanel()
            return Unmanaged.passUnretained(event)
        case .otherMouseUp:
            let shouldSwallow = SwitcherSupport.shouldSwallowMiddleMouseUp(
                   eventType: type,
                   buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
                   swallowedMouseDown: swallowingMiddleMouseUp
               )
            swallowingMiddleMouseUp = false
            if shouldSwallow {
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Resolves one keystroke against the shortcuts this session answers to.
    /// The order is a priority order: the session's own shortcut wins over the
    /// Apps shortcut, which wins over the window shortcut, which wins over the
    /// arrows — a window shortcut bound to an arrow key still steps windows.
    ///
    /// The session shortcut's modifiers are necessarily held while the panel
    /// is up, so they never disqualify the window key (a window shortcut like
    /// ⌥Tab works during a ⌘Tab session). Matching by character too keeps the
    /// default ⌘` on the key that actually types ` on ABNT2, German and other
    /// non-US layouts (#187). Shift only means "backward" on a positional
    /// match: on a character match it may be part of typing the character.
    private func decodeKey(_ event: CGEvent) -> SwitcherKeyEvent {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let (appsShortcut, windowShortcut) = routeLock.withLock {
            (routeShortcut, routeWindowShortcut)
        }
        let shortcut = session.shortcut ?? appsShortcut

        let kind: SwitcherKeyEvent.Kind
        if keyCode == shortcut.keyCode, shortcut.matches(event: event, allowingExtraShift: true) {
            kind = .sessionShortcut(shiftIsNavigationModifier: shortcut.shiftIsNavigationModifier)
        } else if session.scope == .frontmostApp,
                  keyCode == appsShortcut.keyCode,
                  appsShortcut.matches(event: event,
                                       allowingExtraShift: true,
                                       tolerating: shortcut.modifiers) {
            kind = .appsShortcutInWindowScope(
                shiftIsNavigationModifier: appsShortcut.shiftIsNavigationModifier)
        } else if session.searchQuery.isEmpty,
                  windowShortcut.matches(event: event, allowingExtraShift: true,
                                         tolerating: shortcut.modifiers)
                      || windowShortcut.matchesByCharacter(event: event,
                                                           tolerating: shortcut.modifiers) {
            let positional = windowShortcut.matches(event: event, allowingExtraShift: true,
                                                    tolerating: shortcut.modifiers)
            kind = .windowShortcut(positionalMatch: positional,
                                   shiftIsNavigationModifier: windowShortcut.shiftIsNavigationModifier)
        } else {
            switch keyCode {
            case KeyCode.rightArrow: kind = .rightArrow
            case KeyCode.leftArrow: kind = .leftArrow
            case KeyCode.downArrow: kind = .downArrow
            case KeyCode.upArrow: kind = .upArrow
            case KeyCode.delete: kind = .delete
            case KeyCode.escape: kind = .escape
            case KeyCode.enter: kind = .enter
            default: kind = .other
            }
        }

        return SwitcherKeyEvent(kind: kind,
                                shiftHeld: flags.contains(.maskShift),
                                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                keyCode: keyCode,
                                typedText: kind == .other ? printableSearchText(from: event) : nil,
                                now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Session effects

    /// The preferences and measurements the session reads, sampled at the
    /// moment the event arrives — the same moment the switcher read them
    /// before. The scope is deliberately not part of it: the session answers
    /// the scope-dependent layout questions from its own scope, so a caller
    /// cannot measure a session against a scope it no longer has.
    private func sessionEnvironment() -> SwitcherSessionEnvironment {
        SwitcherSessionEnvironment(
            iconRowMode: iconRowModeEnabled,
            simpleMode: simpleModeEnabled,
            mergeWindowsByApp: UserDefaults.standard.bool(forKey: DefaultsKey.switcherMergeTabs),
            gridColumns: grid.columns,
            searchPinEnabled: searchPinEnabled
        )
    }

    @discardableResult
    private func perform(_ outcome: SwitcherSessionOutcome) -> Bool {
        perform(outcome.effects)
        return outcome.swallowsEvent
    }

    private func perform(_ effects: [SwitcherSessionEffect]) {
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: SwitcherSessionEffect) {
        switch effect {
        case .publishSession:
            windows = session.visibleItems
            totalWindowCount = session.itemCount
            searchQuery = session.searchQuery
            isSearchPinned = session.isSearchPinned
            sessionScope = session.scope
        case .publishSelection:
            selectedIndex = session.selectedIndex
        case .recomputeLayouts:
            recomputeLayouts(for: session.visibleItems)
        case .resizePanel:
            resizePanel()
        case .schedulePanel:
            scheduleShowPanel()
        case .seedPreviews:
            guard capturesPreviews else {
                previews = [:]
                return
            }
            previews = Dictionary(uniqueKeysWithValues: session.visibleItems.compactMap { item in
                item.previewWindowID.flatMap { id in
                    WindowPreviewProvider.shared.cachedPreview(for: id).map { (id, $0) }
                }
            })
        case .refreshPreviews:
            guard capturesPreviews else { return }
            WindowPreviewProvider.shared.refreshPreviews(
                for: session.visibleItems,
                maxPixelSize: 640 * PreviewSizing.scale
            ) { [weak self] windowID, image in
                guard let self,
                      self.session.isActive,
                      self.session.items.contains(where: { $0.previewWindowID == windowID })
                else { return }
                self.previews[windowID] = image
            }
        case .prunePreviewsToVisible(let dropping):
            let remaining = Set(session.visibleItems.compactMap(\.previewWindowID))
            previews = previews.filter { remaining.contains($0.key) && $0.key != dropping }
        case .removePreview(let windowID):
            previews.removeValue(forKey: windowID)
        case .replayNavigation(let delta, let times):
            for _ in 0..<times {
                perform(session.apply(.navigate(delta: delta, wrapping: true),
                                      environment: sessionEnvironment()))
            }
        case .cancelIconRowEdgeHover:
            cancelIconRowEdgeHover()
        case .teardown:
            performTeardown()
        case .activate(let item, let source, let previousWindowID):
            recordUse(item, previous: previousWindowID)
            WindowActivator.activate(item,
                                     sourceWasFullscreen: source?.isFullscreen ?? false,
                                     sourcePID: source?.pid,
                                     sourceWindowID: source?.isFullscreen == true ? nil : source?.windowID,
                                     sourceWindowOwnerPID: source?.windowOwnerPID)
        case .closeWindow(let item):
            beginClosingWindow(item)
        case .closeSelectedWindow:
            closeSelectedWindow()
        case .quitSelectedApp:
            quitSelectedApp()
        case .commit:
            commitSession()
        }
    }

    /// Drops everything this class holds for a session that has just ended.
    /// The session itself is already reset; this is only the panel side.
    private func performTeardown() {
        sessionActive = false
        pendingShow?.cancel()
        pendingShow = nil
        WindowPreviewProvider.shared.cancel()
        panel?.orderOut(nil)
        windows = []
        previews = [:]
        selectedIndex = 0
        grid = .empty
        iconRowLayout = .empty
        searchQuery = ""
        isSearchPinned = false
        totalWindowCount = 0
        hoverAnchor = nil
        hoveredWindowIndex = nil
        cancelIconRowEdgeHover()
        iconRowFirstVisibleIndex = 0
        sessionScope = .allApps
    }

    // MARK: - Session lifecycle

    /// Runs only after the tap callback has returned. Window enumeration may
    /// wait on bounded AX calls, while modifier-up turns the pending result
    /// into a no-panel commit without waiting for this work to finish.
    private func beginPendingSession(generation: UInt64) {
        guard routeLock.withLock({ routePending.isCurrent(generation) }) else { return }
        guard Permissions.shared.accessibility,
              AXIsProcessTrusted(),
              lifecycleLock.withLock({ tap != nil && !shouldStopTapThread })
        else {
            discardPendingSessionStart(generation: generation)
            return
        }

        guard let requested = routeLock.withLock({ () -> SwitcherPendingSessionStart? in
            guard routePending.isCurrent(generation) else { return nil }
            return routePending.current
        }) else { return }
        let allApps = requested.scope == .allApps
        let mergeWindowsByApp = UserDefaults.standard.bool(forKey: DefaultsKey.switcherMergeTabs)
        let groupByApp = allApps && mergeWindowsByApp
        let preservesGroupedWindows = SwitcherSupport.preservesGroupedWindowsDuringEnumeration(
            allApps: allApps,
            mergeWindowsByApp: mergeWindowsByApp,
            simpleMode: simpleModeEnabled
        )
        guard let reportedFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            discardPendingSessionStart(generation: generation)
            return
        }
        let enumerationSnapshot = WindowEnumerator.snapshot()
        enumerationQueue.async { [weak self] in
            guard let self,
                  self.routeLock.withLock({ self.routePending.isCurrent(generation) })
            else { return }
            let allWindows = WindowEnumerator.enumerateSwitcherWindows(
                groupByApp: groupByApp,
                preservingGroupedWindows: preservesGroupedWindows,
                snapshot: enumerationSnapshot,
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return !self.routeLock.withLock { self.routePending.isCurrent(generation) }
                }
            )
            guard self.routeLock.withLock({ self.routePending.isCurrent(generation) }) else { return }
            let sessionWindows: [SwitcherItem]
            switch requested.scope {
            case .allApps:
                sessionWindows = allWindows
            case .frontmostApp:
                sessionWindows = SwitcherSupport.frontmostAppWindows(
                    allItems: allWindows,
                    frontmostPID: reportedFrontPID)
            }
            let needsFocusedWindowLookup = !sessionWindows.isEmpty
                && SwitcherSupport.needsFocusedWindowLookup(
                    frontmostPID: reportedFrontPID,
                    items: sessionWindows)
            let focusedSourceWindowID = needsFocusedWindowLookup
                ? self.focusedWindowID(for: reportedFrontPID,
                                       accessibilityGranted: enumerationSnapshot.accessibilityGranted)
                : nil
            DispatchQueue.main.async { [weak self] in
                self?.finishPendingSession(generation: generation,
                                           reportedFrontPID: reportedFrontPID,
                                           focusedSourceWindowID: focusedSourceWindowID,
                                           windows: sessionWindows)
            }
        }
    }

    private func finishPendingSession(generation: UInt64,
                                      reportedFrontPID: pid_t,
                                      focusedSourceWindowID: CGWindowID?,
                                      windows: [SwitcherItem]) {
        guard routeLock.withLock({ routePending.isCurrent(generation) }) else { return }
        guard !windows.isEmpty else {
            discardPendingSessionStart(generation: generation)
            return
        }
        guard let pending = routeLock.withLock({ () -> SwitcherPendingSessionStart? in
            guard let pending = routePending.take(generation: generation) else { return nil }
            routeSessionActive = true
            return pending
        }) else { return }

        let start = SwitcherSessionStart(windows: windows,
                                         frontmostPID: reportedFrontPID,
                                         focusedSourceWindowID: focusedSourceWindowID,
                                         pending: pending)
        perform(session.apply(.begin(start), environment: sessionEnvironment()))
    }

    private func discardPendingSessionStart(generation: UInt64) {
        routeLock.withLock { routePending.discard(generation: generation) }
    }

    private func focusedWindowID(for pid: pid_t, accessibilityGranted: Bool) -> CGWindowID? {
        guard accessibilityGranted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // This runs on the serial session enumeration queue. A hung frontmost
        // app must not delay this session for the 6s default AX timeout.
        AXUIElementSetMessagingTimeout(app, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let window = value as! AXUIElement
        return AXWindowResolver.windowID(for: window)
    }

    /// Records a switch straight away instead of waiting for the window server
    /// and Accessibility to report it: a flick of the shortcut is faster than
    /// either, and it is exactly the moment the toggle has to be right.
    private func recordUse(_ activated: SwitcherItem, previous: CGWindowID?) {
        WindowUseTracker.shared.recordSwitch(to: activated.windowID, from: previous)
    }

    /// Activates the current selection. Also used by the panel on click.
    func commitSession() {
        perform(session.apply(.commit, environment: sessionEnvironment()))
    }

    private func cancelSession() {
        perform(session.apply(.cancel, environment: sessionEnvironment()))
    }

    // MARK: - Selection and hover

    func select(index: Int) {
        perform(session.apply(.select(index: index), environment: sessionEnvironment()))
    }

    /// Hover-selection from the panel. Ignored until the mouse really moves:
    /// the panel may open centered on the cursor's screen, and the card that
    /// happens to sit under a stationary pointer must not steal the selection.
    func hoverSelect(index: Int) {
        guard session.isActive, windows.indices.contains(index) else { return }
        hoveredWindowIndex = index
        let mouse = NSEvent.mouseLocation
        if let anchor = hoverAnchor {
            guard hypot(mouse.x - anchor.x, mouse.y - anchor.y) > 4 else { return }
            hoverAnchor = nil
        }
        select(index: index)
    }

    func hoverSelectEnded(index: Int) {
        if hoveredWindowIndex == index { hoveredWindowIndex = nil }
    }

    /// Icon-row hover. Selects the tile, then only the last visible overflow
    /// icon may start the one-by-one slide.
    func hoverSelectIconRow(index: Int) {
        hoverSelect(index: index)
        guard hoverAnchor == nil else { return }
        beginIconRowEdgeHoverIfNeeded(at: index)
    }

    func hoverSelectIconRowEnded(index: Int) {
        hoverSelectEnded(index: index)
        guard iconRowEdgeHoverIndex == iconRowIndex(forSelectionIndex: index) else { return }
        cancelIconRowEdgeHover()
    }

    // MARK: - Search input

    private func printableSearchText(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 16)
        event.keyboardGetUnicodeString(maxStringLength: chars.count,
                                       actualStringLength: &length,
                                       unicodeString: &chars)
        guard length > 0 else { return nil }
        return SwitcherSession.sanitizedSearchInput(String(utf16CodeUnits: chars, count: length))
    }

    // MARK: - Closing and quitting

    func closeWindow(_ item: SwitcherItem) {
        perform(session.apply(.requestClose(item), environment: sessionEnvironment()))
    }

    /// Closes the highlighted window (⌘Tab → W) and keeps the session open, so
    /// the app stays running and the panel moves on to the next window. Same
    /// path as the card's close button.
    private func closeSelectedWindow() {
        guard let item = session.selectedItem else { return }
        closeWindow(item)
    }

    /// Quits the app owning the selected window (⌘Tab → Q). The session drops
    /// its windows once the terminate request is out, mirroring the system
    /// switcher.
    private func quitSelectedApp() {
        guard let selected = session.selectedItem else { return }
        let pid = selected.pid
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier != Defaults.finderBundleIdentifier else { return }
        app.terminate()
        perform(session.apply(.appTerminated(pid: pid), environment: sessionEnvironment()))
    }

    private func beginClosingWindow(_ item: SwitcherItem) {
        guard let windowID = item.windowID else { return }
        WindowActivator.closeWindowIncludingHiddenState(item) { [weak self] didClose in
            guard let self else { return }
            guard didClose else {
                self.perform(self.session.apply(.closeAbandoned(itemID: item.id),
                                                environment: self.sessionEnvironment()))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.finishClosingWindow(itemID: item.id,
                                          windowID: windowID,
                                          pid: item.pid,
                                          attempt: 0)
            }
        }
    }

    private func finishClosingWindow(itemID: String, windowID: CGWindowID, pid: pid_t, attempt: Int) {
        guard session.isActive else { return }
        guard session.contains(itemID: itemID) else {
            perform(session.apply(.closeAbandoned(itemID: itemID), environment: sessionEnvironment()))
            return
        }

        let refreshed = WindowEnumerator.listWindows(for: pid, maximumCount: 64)
        guard !refreshed.contains(where: { $0.windowID == windowID }) else {
            // Still there after the retries: the app kept it, so it is a
            // normal entry again and the release may raise it.
            guard attempt < 2 else {
                perform(session.apply(.closeAbandoned(itemID: itemID),
                                      environment: sessionEnvironment()))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.finishClosingWindow(itemID: itemID,
                                          windowID: windowID,
                                          pid: pid,
                                          attempt: attempt + 1)
            }
            return
        }

        perform(session.apply(.closeConfirmed(itemID: itemID, windowID: windowID),
                              environment: sessionEnvironment()))
    }


    // MARK: - Panel

    /// Shows the panel after a short delay — quick flicks commit before it
    /// fires and never see any UI, exactly like the system switcher.
    private func scheduleShowPanel() {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session.isActive else { return }
            self.showPanel()
        }
        pendingShow = work
        let appearanceDelay = SwitcherSupport.appearanceDelay(
            milliseconds: UserDefaults.standard.integer(forKey: DefaultsKey.switcherAppearanceDelay))
        DispatchQueue.main.asyncAfter(deadline: .now() + appearanceDelay, execute: work)
    }

    private func showPanel() {
        let panel = ensurePanel()
        panel.hasShadow = !usesIconRowLayout
        hoverAnchor = NSEvent.mouseLocation
        panel.setFrame(centeredFrame(for: currentPanelSize), display: true)
        panel.invalidateShadow()
        let animationBehavior = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        panel.animationBehavior = animationBehavior
    }

    /// A click outside cancels before the event continues through the session
    /// tap. This preserves the click and prevents a nearly simultaneous Command
    /// release from committing the highlighted window first (issues #384 and
    /// #539).
    private func dismissForClickOutsidePanel() {
        guard session.isActive, let panel else { return }
        guard SwitcherSupport.shouldDismissForClick(panelIsVisible: panel.isVisible,
                                                    panelFrame: panel.frame,
                                                    location: NSEvent.mouseLocation)
        else { return }
        cancelSession()
    }

    /// Re-fits the panel after the grid changed mid-session (e.g. an app quit
    /// with Q). Animated only when already on screen, so the size change reads
    /// as intentional instead of a flash.
    private func resizePanel() {
        guard let panel else { return }
        let frame = centeredFrame(for: currentPanelSize)
        panel.hasShadow = !usesIconRowLayout
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        panel.invalidateShadow()
    }

    private var currentPanelSize: CGSize {
        usesIconRowLayout
            ? (simpleModeEnabled
                ? (usesWindowRow ? iconRowLayout.simpleWindowPanelSize : iconRowLayout.simplePanelSize)
                : iconRowLayout.panelSize)
            : grid.panelSize
    }

    private var iconRowModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.switcherIconRowMode)
    }

    private var simpleModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.switcherSimpleMode)
    }

    private var usesWindowRow: Bool {
        SwitcherSupport.usesWindowRow(
            simpleMode: simpleModeEnabled,
            mergeWindowsByApp: UserDefaults.standard.bool(forKey: DefaultsKey.switcherMergeTabs),
            sessionScope: session.scope
        )
    }

    private var searchPinEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.switcherSearchPinEnabled)
    }

    private var showsShortcutHints: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.switcherShowShortcutHints)
    }

    private var usesIconRowLayout: Bool {
        SwitcherSupport.usesIconRowLayout(iconRowMode: iconRowModeEnabled,
                                          simpleMode: simpleModeEnabled)
    }

    private var capturesPreviews: Bool {
        SwitcherSupport.capturesPreviews(simpleMode: simpleModeEnabled)
    }

    // MARK: - Placement screen

    private var screenPlacement: SwitcherScreenPlacement {
        SwitcherScreenPlacement.placement(
            storedValue: UserDefaults.standard.string(forKey: DefaultsKey.switcherScreenPlacement))
    }

    /// The screen the panel is laid out on. Every choice falls back to the
    /// pointer's screen, which exists whenever any display does: the menu bar
    /// screen goes missing only mid-reconfiguration, and the active window's
    /// screen is unknown for an app-only source or a window parked entirely
    /// off screen.
    private var placementScreen: NSScreen? {
        switch screenPlacement {
        case .pointer:
            return NSScreen.withMouse
        case .menuBar:
            return NSScreen.withMenuBar ?? NSScreen.withMouse
        case .activeWindow:
            return activeWindowScreen ?? NSScreen.withMouse
        }
    }

    /// The screen showing most of the window that was in front when the
    /// session began. The source frame comes from the window server, so it is
    /// matched against `CGDisplayBounds` rather than the flipped AppKit frames.
    private var activeWindowScreen: NSScreen? {
        guard let frame = session.source?.frame else { return nil }
        let screens = NSScreen.screens
        let bounds = screens.map { CGDisplayBounds($0.displayID) }
        guard let index = SwitcherSupport.displayIndex(showingMostOf: frame, displayBounds: bounds) else {
            return nil
        }
        return screens[index]
    }

    private var placementVisibleFrame: CGRect {
        placementScreen?.visibleFrame ?? NSScreen.pointerVisibleFrame
    }

    private func recomputeLayouts(for items: [SwitcherItem]) {
        guard let screen = placementScreen ?? NSScreen.screens.first else { return }
        grid = SwitcherGrid.compute(count: max(items.count, 1), on: screen)
        let appGroups = SwitcherSupport.appGroups(items: items)
        iconRowLayout = SwitcherIconRowLayout.compute(
            appCount: usesWindowRow ? items.count : appGroups.count,
            selectedWindowCount: usesWindowRow ? 1 : selectedAppWindowCount(in: items),
            screenVisibleFrame: screen.visibleFrame,
            showsShortcutHints: showsShortcutHints,
            tileWidth: usesWindowRow ? SwitcherIconRowLayout.windowTileWidth
                                     : SwitcherIconRowLayout.appTileWidth
        )
    }

    private func updateIconRowLayoutForCurrentSelection() {
        guard !windows.isEmpty else { return }
        let appGroups = SwitcherSupport.appGroups(items: windows)
        iconRowLayout = SwitcherIconRowLayout.compute(
            appCount: usesWindowRow ? windows.count : appGroups.count,
            selectedWindowCount: usesWindowRow ? 1 : selectedAppWindowCount(in: windows),
            screenVisibleFrame: placementVisibleFrame,
            showsShortcutHints: showsShortcutHints,
            tileWidth: usesWindowRow ? SwitcherIconRowLayout.windowTileWidth
                                     : SwitcherIconRowLayout.appTileWidth
        )
        revealSelectedIconInVisibleRow()
    }

    private var iconRowItemCount: Int {
        usesWindowRow ? windows.count : SwitcherSupport.appGroups(items: windows).count
    }

    private func iconRowIndex(forSelectionIndex selectionIndex: Int) -> Int? {
        guard windows.indices.contains(selectionIndex) else { return nil }
        if usesWindowRow { return selectionIndex }
        let groups = SwitcherSupport.appGroups(items: windows)
        return groups.firstIndex { $0.pid == windows[selectionIndex].pid }
    }

    private func selectionIndex(forIconRowIndex iconIndex: Int) -> Int? {
        if usesWindowRow {
            return windows.indices.contains(iconIndex) ? iconIndex : nil
        }
        let groups = SwitcherSupport.appGroups(items: windows)
        return groups.indices.contains(iconIndex) ? groups[iconIndex].representativeIndex : nil
    }

    private func revealSelectedIconInVisibleRow() {
        guard usesIconRowLayout,
              let iconIndex = iconRowIndex(forSelectionIndex: selectedIndex)
        else { return }
        iconRowFirstVisibleIndex = SwitcherSupport.iconRowFirstVisibleIndex(
            revealing: iconIndex,
            itemCount: iconRowItemCount,
            visibleCount: iconRowLayout.visibleIconCount,
            currentFirstVisibleIndex: iconRowFirstVisibleIndex
        )
    }

    private func beginIconRowEdgeHoverIfNeeded(at selectionIndex: Int) {
        guard usesIconRowLayout,
              let iconIndex = iconRowIndex(forSelectionIndex: selectionIndex),
              SwitcherSupport.iconRowEdgeHoverDelta(
                hoveredIndex: iconIndex,
                firstVisibleIndex: iconRowFirstVisibleIndex,
                visibleCount: iconRowLayout.visibleIconCount,
                itemCount: iconRowItemCount
              ) != nil
        else {
            cancelIconRowEdgeHover()
            return
        }
        guard iconRowEdgeHoverIndex != iconIndex else { return }
        cancelIconRowEdgeHover()
        iconRowEdgeHoverIndex = iconIndex
        let work = DispatchWorkItem { [weak self] in
            self?.stepIconRowFromEdgeHover()
        }
        iconRowEdgeHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SwitcherSupport.iconRowEdgeHoverInterval,
                                      execute: work)
    }

    private func stepIconRowFromEdgeHover() {
        guard session.isActive, usesIconRowLayout,
              let hovered = iconRowEdgeHoverIndex,
              let delta = SwitcherSupport.iconRowEdgeHoverDelta(
                hoveredIndex: hovered,
                firstVisibleIndex: iconRowFirstVisibleIndex,
                visibleCount: iconRowLayout.visibleIconCount,
                itemCount: iconRowItemCount
              )
        else {
            cancelIconRowEdgeHover()
            return
        }

        let nextFirst = SwitcherSupport.clampedIconRowFirstVisibleIndex(
            itemCount: iconRowItemCount,
            visibleCount: iconRowLayout.visibleIconCount,
            firstVisibleIndex: iconRowFirstVisibleIndex + delta
        )
        guard nextFirst != iconRowFirstVisibleIndex else {
            cancelIconRowEdgeHover()
            return
        }

        let nextIcon = SwitcherSupport.iconRowIndexAfterEdgeHoverStep(
            firstVisibleIndex: nextFirst,
            visibleCount: iconRowLayout.visibleIconCount,
            itemCount: iconRowItemCount,
            delta: delta
        )
        // Publish the new hover target first. Sliding the row fires a hover-end
        // on the previous last icon, and that must not cancel this step.
        iconRowEdgeHoverIndex = nextIcon
        iconRowFirstVisibleIndex = nextFirst
        if let nextSelection = selectionIndex(forIconRowIndex: nextIcon) {
            select(index: nextSelection)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.stepIconRowFromEdgeHover()
        }
        iconRowEdgeHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SwitcherSupport.iconRowEdgeHoverRepeatInterval,
                                      execute: work)
    }

    private func cancelIconRowEdgeHover() {
        iconRowEdgeHoverWork?.cancel()
        iconRowEdgeHoverWork = nil
        iconRowEdgeHoverIndex = nil
    }

    private func selectedAppWindowCount(in items: [SwitcherItem]) -> Int {
        guard items.indices.contains(selectedIndex) else { return 1 }
        let pid = items[selectedIndex].pid
        return max(1, items.filter { $0.pid == pid }.count)
    }

    private func centeredFrame(for size: CGSize) -> NSRect {
        let screen = placementVisibleFrame
        return NSRect(x: screen.midX - size.width / 2,
                      y: screen.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: SwitcherView().environmentObject(self))
        self.panel = panel
        return panel
    }
}

/// Grid metrics for one switcher session: large cards laid out in as many
/// rows as needed, sized to the screen the panel opens on — no sideways
/// scrolling, no squinting.
struct SwitcherGrid: Equatable {
    let columns: Int
    let rows: Int
    let visibleRows: Int
    let panelSize: CGSize

    // Breathing room scales with the cards, so making previews smaller also
    // keeps the panel from spending that saved space on empty gaps.
    static var cardWidth: CGFloat { SwitcherGridCard.width }
    static var cardHeight: CGFloat { SwitcherGridCard.height }
    static var spacing: CGFloat { 12 * PreviewSizing.scale }
    static var padding: CGFloat { 20 * PreviewSizing.scale }

    static let empty = SwitcherGrid(columns: 1, rows: 1, visibleRows: 1, panelSize: .zero)

    static func compute(count: Int, on screen: NSScreen) -> SwitcherGrid {
        let usableWidth = screen.visibleFrame.width * 0.92
        let usableHeight = screen.visibleFrame.height * 0.85

        let maxColumns = max(1, Int((usableWidth - padding * 2 + spacing) / (cardWidth + spacing)))
        let columns = SwitcherSupport.gridColumnCount(itemCount: count, maxColumns: maxColumns)
        let rows = Int(ceil(Double(count) / Double(columns)))

        let maxRows = max(1, Int((usableHeight - padding * 2 + spacing) / (cardHeight + spacing)))
        let visibleRows = min(rows, maxRows)

        let width = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing + padding * 2
        let height = CGFloat(visibleRows) * cardHeight + CGFloat(visibleRows - 1) * spacing + padding * 2
        return SwitcherGrid(columns: columns, rows: rows, visibleRows: visibleRows,
                            panelSize: CGSize(width: width, height: height))
    }
}
