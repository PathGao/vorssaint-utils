// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Hands this app's activation to another one.
///
/// Cooperative activation only lets an app pass on activation it currently
/// holds. Vorssaint is `LSUIElement`, and the surfaces that trigger a handoff —
/// the switcher panel, the Dock click tap, the process list — are all
/// non-activating, so at the moment a handoff commits Vorssaint usually is not
/// the active app. `yieldActivation(to:)` then gives away nothing, the
/// `activate(from:)` that follows is refused, and the target never comes
/// forward: its windows may rise but the menu bar stays with whatever app was
/// already active. Self-activating first is what gives the yield something to
/// hand over; it runs in direct response to the user's own key or click, which
/// the system accepts as a real gesture.
///
/// Every yield in the app goes through here. A bare `yieldActivation(to:)`
/// added elsewhere, whatever the receiver is spelled, would reintroduce the bug
/// on that path alone, so `Tests/MetricsTests.swift` scans `Sources` and fails
/// if one appears.
enum ActivationHandoff {
    /// Call on the main thread, synchronously with the gesture that asked for
    /// the switch. The caller still activates `app` itself afterwards — this
    /// only clears the way.
    static func yield(to app: NSRunningApplication) {
        // The self-activation below posts a real activation notification for
        // our own process; tell the use tracker it is ours so it does not rank
        // Vorssaint ahead of the app the user is switching away from.
        WindowUseTracker.shared.expectSelfActivationHandoff()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.yieldActivation(to: app)
    }
}
