// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Every yield goes through here. `yieldActivation(to:)` only hands over
/// activation this app holds, and Vorssaint (`LSUIElement`, non-activating
/// panels) usually holds none when a switch commits, so the yield gave away
/// nothing and the cooperative `activate(from:)` after it was refused.
/// Self-activating first gives the yield something to hand over.
enum ActivationHandoff {
    static func yield(to app: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.yieldActivation(to: app)
    }
}
