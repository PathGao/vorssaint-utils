// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Temporarily places plain text on the general pasteboard, pastes it, then
/// restores the previous content if the user did not copy something else.
/// All pasteboard reads share the app's serial lane because promised data can
/// block while its owning process renders it.
final class TransientPaste {
    static let shared = TransientPaste()

    private static let restoreDelay: TimeInterval = 0.5
    /// The wait for the shortcut's own modifiers to come up before ⌘V is
    /// posted anyway, then the settle before the post. Their sum is the
    /// bound `QuickToolsSupport.pastePlainModifierReleaseBound` repeats.
    private static let modifierPollAttempts = 100
    private static let modifierPollInterval: TimeInterval = 0.015
    private static let postDelay: TimeInterval = 0.06

    private var pendingRestore: (snapshot: [NSPasteboardItem], changeCount: Int)?
    private var restoreWork: DispatchWorkItem?
    private var isPerforming = false

    /// `stillWanted` is asked once more right before the ⌘V is posted. The
    /// pasteboard snapshot above runs on the serial lane with no time limit,
    /// so a caller whose press has a deadline or a target app hands the same
    /// test in here; a refusal takes the didFail path and the pasteboard is
    /// put back the way a failed post is. Nil never refuses.
    @discardableResult
    func paste(_ text: String,
               willPostShortcut: (() -> Void)? = nil,
               didPostShortcut: (() -> Void)? = nil,
               didFail: (() -> Void)? = nil,
               stillWanted: (() -> Bool)? = nil) -> Bool {
        guard Thread.isMainThread else { return false }
        guard !isPerforming else { return false }
        isPerforming = true

        let previous = pendingRestore
        restoreWork?.cancel()
        restoreWork = nil

        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            let originalChangeCount = pasteboard.changeCount
            let snapshot: [NSPasteboardItem]?
            if let previous, pasteboard.changeCount == previous.changeCount {
                snapshot = previous.snapshot
            } else {
                snapshot = Self.snapshot(of: pasteboard)
            }
            guard let snapshot else {
                DispatchQueue.main.async {
                    self.isPerforming = false
                    didFail?()
                }
                return
            }
            guard pasteboard.changeCount == originalChangeCount else {
                DispatchQueue.main.async {
                    self.isPerforming = false
                    didFail?()
                }
                return
            }

            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
                DispatchQueue.main.async {
                    self.isPerforming = false
                    didFail?()
                }
                return
            }
            let changeCount = pasteboard.changeCount

            DispatchQueue.main.async {
                ClipboardHistoryService.shared.ignoreNextChange(upTo: changeCount)
                self.pendingRestore = (snapshot, changeCount)
                Self.postPasteWhenModifiersReleased(
                    attempt: 0,
                    willPost: willPostShortcut,
                    didPost: didPostShortcut,
                    didFail: didFail,
                    stillWanted: stillWanted
                ) {
                    self.isPerforming = false
                    self.scheduleRestore(snapshot: snapshot, changeCount: changeCount)
                }
            }
        }
        return true
    }

    private func scheduleRestore(snapshot: [NSPasteboardItem], changeCount: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreWork = nil
            self.pendingRestore = nil
            GeneralPasteboardAccess.shared.async {
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == changeCount else { return }
                pasteboard.clearContents()
                if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
                let restoredCount = pasteboard.changeCount
                DispatchQueue.main.async {
                    ClipboardHistoryService.shared.ignoreNextChange(upTo: restoredCount)
                }
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    /// Nil means at least one advertised flavor could not be preserved, so the
    /// transient paste fails open instead of clearing incomplete user data.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else {
            return pasteboard.types?.isEmpty == false ? nil : []
        }
        var snapshot: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                copy.setData(data, forType: type)
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    private static func postPasteWhenModifiersReleased(attempt: Int,
                                                       willPost: (() -> Void)?,
                                                       didPost: (() -> Void)?,
                                                       didFail: (() -> Void)?,
                                                       stillWanted: (() -> Bool)?,
                                                       completion: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        if held.isEmpty || attempt >= modifierPollAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + postDelay) {
                postPasteShortcut(willPost: willPost, stillWanted: stillWanted) { succeeded in
                    if succeeded {
                        didPost?()
                    } else {
                        didFail?()
                    }
                    completion()
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierPollInterval) {
            postPasteWhenModifiersReleased(attempt: attempt + 1,
                                           willPost: willPost,
                                           didPost: didPost,
                                           didFail: didFail,
                                           stillWanted: stillWanted,
                                           completion: completion)
        }
    }

    private static func postPasteShortcut(willPost: (() -> Void)?,
                                          stillWanted: (() -> Bool)?,
                                          completion: @escaping (Bool) -> Void) {
        // Asked here and not on the way in: everything between the call and
        // this point can wait, and a paste that is no longer wanted must not
        // be posted just because it was wanted when it was queued.
        guard stillWanted?() ?? true else {
            completion(false)
            return
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil,
                                    virtualKey: CGKeyCode(kVK_ANSI_V),
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: false)
        else {
            completion(false)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        willPost?()
        keyDown.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            keyUp.post(tap: .cghidEventTap)
            completion(true)
        }
    }
}
