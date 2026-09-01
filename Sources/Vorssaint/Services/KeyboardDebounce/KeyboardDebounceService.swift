// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Suppresses accidental duplicate physical key presses inside a short window.
/// Auto-repeat from a held key is left untouched so normal key-repeat behavior
/// keeps working.
final class KeyboardDebounceService: ObservableObject {
    static let shared = KeyboardDebounceService()

    @Published private(set) var isRunning = false

    private let eventLock = NSLock()
    private let lifecycleLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var shouldStopTapThread = false
    private var pendingStartAfterStop = false
    private var lifecycleGeneration: UInt = 0
    private var state = KeyboardDebounceState()
    private var config = KeyboardDebounceConfig(enabled: false,
                                                globalWindowMs: Defaults.defaultKeyboardDebounceWindowMs,
                                                keyWindows: [:])

    private init() {
        // This tap sits at the HID stage, ahead of the split into login
        // sessions, so a session that is switched away still sees the keys of
        // the account on screen — and this one answers them from state that was
        // built out of another account's typing, swallowing what it reads as a
        // bounce. Hand the tap back on resign and build it again from the
        // preferences on the way in (issue #1075).
        SessionActivity.shared.onChange { [weak self] _ in
            self?.syncWithPreferences()
        }
    }

    func syncWithPreferences() {
        let shouldRun = SessionActivitySupport.tapShouldRun(
            featureWanted: AppFeature.keyboardDebounce.isAvailable
                && UserDefaults.standard.bool(forKey: DefaultsKey.keyboardDebounceEnabled),
            accessibilityGranted: Permissions.shared.accessibility,
            sessionIsActive: SessionActivity.shared.isActive
        )
        let nextConfig = KeyboardDebounceConfig(
            enabled: shouldRun,
            globalWindowMs: Defaults.sanitizedKeyboardDebounceWindow(
                UserDefaults.standard.integer(forKey: DefaultsKey.keyboardDebounceWindowMs)
            ),
            keyWindows: KeyboardDebounceConfig.decodeKeyWindows(
                UserDefaults.standard.string(forKey: DefaultsKey.keyboardDebounceKeyWindows) ?? ""
            )
        )
        eventLock.withLock {
            config = nextConfig
        }

        if shouldRun {
            start()
        } else {
            stop()
        }
    }

    func suspend() {
        stop()
    }

    private func start() {
        eventLock.withLock {
            state.reset()
        }

        // The new thread is created and assigned to tapThread inside the same
        // critical section as the decision: a stop() must never observe
        // tapThread == nil while a start is committed, or it would reset
        // shouldStopTapThread and let the new thread enable a tap whose
        // "running" publish is then dropped as stale — a live tap with the
        // feature showing disabled.
        let startState = lifecycleLock.withLock { () -> (thread: Thread?, publishRunning: Bool, generation: UInt) in
            if tapThread != nil {
                if shouldStopTapThread {
                    pendingStartAfterStop = true
                    return (nil, false, lifecycleGeneration)
                }
                return (nil, true, lifecycleGeneration)
            }
            shouldStopTapThread = false
            pendingStartAfterStop = false
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            let thread = Thread { [weak self] in
                self?.runEventTap(generation: generation)
            }
            thread.name = "Vorssaint Keyboard Debounce"
            thread.qualityOfService = .userInteractive
            tapThread = thread
            return (thread, false, generation)
        }

        if let thread = startState.thread {
            thread.start()
        } else if startState.publishRunning {
            publishRunning(true, generation: startState.generation)
        }
    }

    private func stop() {
        eventLock.withLock {
            state.reset()
        }

        let snapshot = lifecycleLock.withLock {
            () -> (runLoop: CFRunLoop?, tap: CFMachPort?, threadExists: Bool, generation: UInt) in
            shouldStopTapThread = true
            pendingStartAfterStop = false
            lifecycleGeneration &+= 1
            return (tapRunLoop, tap, tapThread != nil, lifecycleGeneration)
        }

        if let tap = snapshot.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Switching a tap off leaves this process owning the port, and the
            // port is what the window server waits on. Handing the tap back
            // means leaving the chain, not going quiet in it.
            CFMachPortInvalidate(tap)
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
        publishRunning(false, generation: snapshot.generation)
    }

    private func runEventTap(generation: UInt) {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            lifecycleLock.withLock {
                tapRunLoop = runLoop
            }

            let shouldStopBeforeCreatingTap = lifecycleLock.withLock {
                shouldStopTapThread
            }
            guard !shouldStopBeforeCreatingTap else {
                let shouldRestart = clearEventTapThread()
                if shouldRestart {
                    start()
                } else {
                    publishRunning(false, generation: generation)
                }
                return
            }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.keyUp.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let service = Unmanaged<KeyboardDebounceService>.fromOpaque(userInfo).takeUnretainedValue()
                    return service.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                _ = clearEventTapThread()
                publishRunning(false, generation: generation)
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            lifecycleLock.withLock {
                self.tap = tap
                runLoopSource = source
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            eventLock.withLock {
                state.reset()
            }

            let shouldStop = lifecycleLock.withLock {
                shouldStopTapThread
            }
            if shouldStop {
                CGEvent.tapEnable(tap: tap, enable: false)
            } else {
                publishRunning(true, generation: generation)
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
            eventLock.withLock {
                state.reset()
            }
            let shouldRestart = clearEventTapThread()
            if shouldRestart {
                start()
            } else {
                publishRunning(false, generation: generation)
            }
        }
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

    /// Puts the tap back after the window server disabled it, unless a stop is
    /// already on its way and the port is about to go. Main thread.
    private func rearmDisabledTap() {
        let currentTap = lifecycleLock.withLock {
            shouldStopTapThread ? nil : tap
        }
        if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
    }

    private func publishRunning(_ running: Bool, generation: UInt) {
        let update = { [weak self] in
            guard let self else { return }
            let isCurrent = self.lifecycleLock.withLock {
                generation == self.lifecycleGeneration
            }
            guard isCurrent else { return }
            self.isRunning = running
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Keys flowed untapped while the tap was out of the chain, so the
            // gap must not be read as a quiet stretch and the next press as a
            // bounce.
            eventLock.withLock {
                state.reset()
            }
            // A tap put straight back is a tap put back into whatever session
            // is on screen now (issue #1075). The flag that answers that is
            // written on the main thread, and this callback runs on the tap's
            // own thread, so the question is asked where the answer lives
            // rather than read across the two.
            // Accessibility is asked here for the same reason the mouse twin
            // asks it: this tap modifies events, so a revoked permission has to
            // end it rather than put it back. The sync then stops it for good.
            DispatchQueue.main.async { [weak self] in
                if SessionActivity.shared.isActive, AXIsProcessTrusted() {
                    self?.rearmDisabledTap()
                } else {
                    self?.syncWithPreferences()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let timestamp = UInt64(event.timestamp)
        let eventKind: KeyboardDebounceState.EventKind = type == .keyDown ? .keyDown : .keyUp
        let shouldSuppress = eventLock.withLock {
            state.shouldSuppress(keyCode: keyCode,
                                 isAutoRepeat: isRepeat,
                                 event: eventKind,
                                 timestampNanoseconds: timestamp,
                                 config: config)
        }
        if shouldSuppress {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

