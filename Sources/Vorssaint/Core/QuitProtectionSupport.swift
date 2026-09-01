// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum QuitProtectionShortcut: String, CaseIterable, Identifiable {
    case quit
    case close

    var id: String { rawValue }
    var character: String { self == .quit ? "q" : "w" }
    /// Which key the active layout answers this shortcut on with Command held,
    /// read from the keycap cache that already holds the layout's Command
    /// table. nil while no layout has been read, which leaves matching on the
    /// character.
    var commandKeyCode: Int64? { GlobalShortcut.layoutKeyCode(for: character, usesCommand: true) }
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

    /// A held Command-Q must not repeat into the protected app: each repeat
    /// would restart a hold or count as the second of a double press. Nothing
    /// past that point acts without Command, so the drop asks for it. Matching
    /// resolves the shortcut from the layout's Command table, which answers for
    /// the bare key too — the Q and W keys on a Latin layout, the keys that type
    /// "й" and "ц" on Russian, ";" and "ς" on Greek — and dropping their
    /// autorepeat unconditionally left holding those keys with protection on
    /// producing one character and no repeat.
    static func dropsAutorepeat(isRepeat: Bool, command: Bool) -> Bool {
        isRepeat && command
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
