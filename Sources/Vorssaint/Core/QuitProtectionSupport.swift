// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

enum QuitProtectionShortcut: String, CaseIterable, Identifiable {
    case quit
    case close

    var id: String { rawValue }
    var character: String { self == .quit ? "q" : "w" }
    /// The US position, used only while no keyboard layout can be read.
    var fallbackKeyCode: Int64 { self == .quit ? 12 : 13 }
    var symbol: String { self == .quit ? "⌘Q" : "⌘W" }
}

enum QuitProtectionMode: String, CaseIterable, Identifiable {
    case hold
    case doublePress
    case extraModifier

    var id: String { rawValue }
}

enum QuitProtectionExtraModifier: String, CaseIterable, Identifiable {
    case shift
    case option
    case control

    var id: String { rawValue }
}

enum QuitProtectionScope: String, CaseIterable, Identifiable {
    case all
    case selectedOnly
    case allExceptSelected

    var id: String { rawValue }
}

struct QuitProtectionConfiguration: Equatable {
    var enabled: Bool
    var mode: QuitProtectionMode
    var holdDurationMilliseconds: Double
    var doublePressIntervalMilliseconds: Double
    var extraModifier: QuitProtectionExtraModifier
    var scope: QuitProtectionScope
    var exceptions: [String]
    var showFeedback: Bool
}

enum QuitProtectionSupport {
    static let holdDurationRange = 250.0...2_000.0
    static let doublePressIntervalRange = 200.0...1_500.0
    static let defaultHoldDurationMilliseconds = 800.0
    static let defaultDoublePressIntervalMilliseconds = 600.0

    static func sanitizedHoldDuration(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHoldDurationMilliseconds }
        return min(max(value, holdDurationRange.lowerBound), holdDurationRange.upperBound)
    }

    static func sanitizedDoublePressInterval(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDoublePressIntervalMilliseconds }
        return min(max(value, doublePressIntervalRange.lowerBound), doublePressIntervalRange.upperBound)
    }

    /// CGEvent timestamps are monotonic nanoseconds. Confirmation uses them
    /// directly so a busy main run loop cannot make a valid second press miss
    /// its configured interval.
    static func isWithinDoublePressInterval(firstTimestamp: UInt64,
                                            secondTimestamp: UInt64,
                                            intervalMilliseconds: Double) -> Bool {
        guard secondTimestamp >= firstTimestamp else { return false }
        let allowedNanoseconds = UInt64(
            sanitizedDoublePressInterval(intervalMilliseconds) * 1_000_000
        )
        return secondTimestamp - firstTimestamp <= allowedNanoseconds
    }

    static func usesNativeQuitRequest(for shortcut: QuitProtectionShortcut) -> Bool {
        shortcut == .quit
    }

    static func scopeAllows(_ scope: QuitProtectionScope,
                            bundleIdentifier: String?,
                            exceptions: [String]) -> Bool {
        let contains = bundleIdentifier.map { exceptions.contains($0) } ?? false
        switch scope {
        case .all: return true
        case .selectedOnly: return contains
        case .allExceptSelected: return !contains
        }
    }

    /// Only the exact Command shortcut is protected by hold/double press.
    /// Extra-modifier mode deliberately claims the bare shortcut too, so a
    /// user cannot bypass protection by pressing plain Command-Q/Command-W.
    static func isBaseShortcut(keyCharacter: String?,
                               keyCode: Int64,
                               commandKeyCode: Int64?,
                               command: Bool,
                               control: Bool,
                               option: Bool,
                               shift: Bool,
                               shortcut: QuitProtectionShortcut) -> Bool {
        guard command, !control, !option, !shift else { return false }
        return matchesKey(keyCharacter: keyCharacter,
                          keyCode: keyCode,
                          commandKeyCode: commandKeyCode,
                          shortcut: shortcut)
    }

    static func isExtraShortcut(keyCharacter: String?,
                                keyCode: Int64,
                                commandKeyCode: Int64?,
                                command: Bool,
                                control: Bool,
                                option: Bool,
                                shift: Bool,
                                shortcut: QuitProtectionShortcut,
                                extraModifier: QuitProtectionExtraModifier) -> Bool {
        guard command else { return false }
        let hasExtra: Bool
        switch extraModifier {
        case .shift: hasExtra = shift && !option && !control
        case .option: hasExtra = option && !shift && !control
        case .control: hasExtra = control && !shift && !option
        }
        return hasExtra && matchesKey(keyCharacter: keyCharacter,
                                      keyCode: keyCode,
                                      commandKeyCode: commandKeyCode,
                                      shortcut: shortcut)
    }

    /// `commandKeyCode` is the key the active layout types this shortcut on
    /// with Command held, which is the same question the system asks of a menu
    /// key equivalent. It is the identity to compare against: the character the
    /// event carries is the one typed *without* Command, so a Cyrillic layout
    /// reports "й" and a Greek one ";" for the very key that quits. The
    /// character is left as the answer only while no layout can be read.
    static func matchesKey(keyCharacter: String?,
                           keyCode: Int64,
                           commandKeyCode: Int64?,
                           shortcut: QuitProtectionShortcut) -> Bool {
        if let commandKeyCode {
            return keyCode == commandKeyCode
        }
        if let keyCharacter {
            return keyCharacter.lowercased() == shortcut.character
        }
        return keyCode == shortcut.fallbackKeyCode
    }

    /// The post-confirmation swallow holds until the keys that confirmed the
    /// shortcut come back up. A key up can be lost — the tap is re-enabled
    /// after being disabled on timeout, a tap ahead of ours takes the event,
    /// the session switches user — and a swallow that never ends takes
    /// Command-Q and every key's autorepeat with it, with nothing the user can
    /// do to recover them. It therefore also expires on its own.
    static let swallowTimeoutMilliseconds = 2_000.0

    static func swallowRemainsActive(startTimestamp: UInt64,
                                     currentTimestamp: UInt64) -> Bool {
        guard currentTimestamp >= startTimestamp else { return false }
        return currentTimestamp - startTimestamp
            <= UInt64(swallowTimeoutMilliseconds * 1_000_000)
    }

    static func modeFor(_ rawValue: String?) -> QuitProtectionMode {
        guard let rawValue, let value = QuitProtectionMode(rawValue: rawValue) else { return .hold }
        return value
    }

    static func extraModifierFor(_ rawValue: String?) -> QuitProtectionExtraModifier {
        guard let rawValue, let value = QuitProtectionExtraModifier(rawValue: rawValue) else { return .shift }
        return value
    }

    static func scopeFor(_ rawValue: String?) -> QuitProtectionScope {
        guard let rawValue, let value = QuitProtectionScope(rawValue: rawValue) else { return .all }
        return value
    }
}

/// Which physical key the system will read as Command-Q and Command-W.
///
/// Keyboard layouts carry their own Command table, and every non-Latin layout
/// points it back at the Latin letters: Russian types "й" on the Q key but
/// still quits there, and "Dvorak - QWERTY ⌘" moves Q back under the QWERTY
/// position exactly while Command is held. Asking the layout the same question
/// the system asks is what keeps protection on the key that actually quits.
enum QuitProtectionKeyLayout {
    private static let lock = NSLock()
    private static var keyCodes: [QuitProtectionShortcut: Int64] = [:]
    private static var layoutObserver: AnyObject?

    /// nil while no layout has answered, which leaves matching on the character.
    static func commandKeyCode(for shortcut: QuitProtectionShortcut) -> Int64? {
        lock.withLock { keyCodes[shortcut] }
    }

    /// Called when the tap starts. Switching layout moves both shortcuts without
    /// producing an event of ours, so the resolution has to follow it.
    /// Safe to call more than once.
    static func startObserving() {
        refresh()
        guard layoutObserver == nil else { return }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in refresh() }
    }

    /// Takes a layout directly as well, so tests can resolve against a specific
    /// keyboard layout instead of the one the machine happens to be running.
    static func refresh(layoutData: Data? = commandLayoutData()) {
        let resolved = layoutData.map { keyCodes(in: $0) } ?? [:]
        lock.withLock { keyCodes = resolved }
    }

    static func keyCodes(in layoutData: Data) -> [QuitProtectionShortcut: Int64] {
        var resolved: [QuitProtectionShortcut: Int64] = [:]
        for code in UInt16(0)...127 {
            guard let character = commandCharacter(for: code, layoutData: layoutData),
                  let shortcut = QuitProtectionShortcut.allCases
                      .first(where: { $0.character == character }),
                  resolved[shortcut] == nil
            else { continue }
            resolved[shortcut] = Int64(code)
            if resolved.count == QuitProtectionShortcut.allCases.count { break }
        }
        return resolved
    }

    /// An input method (Pinyin, Korean) carries no layout of its own; Command
    /// shortcuts fall back to the ASCII-capable layout there, and so do we.
    private static func commandLayoutData() -> Data? {
        guard Thread.isMainThread else { return nil }
        return unicodeLayoutData(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            ?? unicodeLayoutData(
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            )
    }

    private static func unicodeLayoutData(_ source: TISInputSource?) -> Data? {
        guard let source,
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
    }

    private static func commandCharacter(for code: UInt16, layoutData: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                                  UInt32((cmdKey >> 8) & 0xFF),
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length == 1 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }
}
