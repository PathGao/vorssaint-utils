// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// The window that was in front when a session opened. Kept as a value so the
/// session survives the window disappearing mid-session.
struct SwitcherSessionSource: Equatable {
    let itemID: String?
    let pid: pid_t
    let windowID: CGWindowID?
    let windowOwnerPID: pid_t?
    let isFullscreen: Bool
    /// Window server bounds of the source window; `.zero` for an app-only entry.
    let frame: CGRect

    init(item: SwitcherItem) {
        itemID = item.id
        pid = item.pid
        windowID = item.windowID
        windowOwnerPID = item.windowOwnerPID
        isFullscreen = item.isFullscreen
        frame = item.frame
    }
}

/// A shortcut press already owned by the switcher while the window list is
/// being assembled. The tap thread can cancel or add repeated navigation
/// without ever waiting for the main thread or Accessibility.
struct SwitcherPendingSessionStart: Equatable {
    let generation: UInt64
    let shortcut: GlobalShortcut
    let scope: SwitcherSessionScope
    let reversed: Bool
    var additionalNavigation = 0
    var commitWhenReady = false
}

/// The presses the event tap owns before the window list exists. Every method
/// is pure state, so the caller keeps it under its own lock and the tap thread
/// never waits on anything.
struct SwitcherPendingStarts: Equatable {
    /// A press may repeat this many times before the list is ready; beyond
    /// that the extra steps cannot mean anything the user can see.
    static let navigationLimit = 64

    private(set) var current: SwitcherPendingSessionStart?
    private var generation: UInt64 = 0

    var isPending: Bool { current != nil }

    /// A quick flick still commits once enumeration finishes, but can never
    /// flash a panel after the key was released.
    mutating func noteShortcutModifiersReleased() {
        guard var pending = current else { return }
        pending.commitWhenReady = true
        current = pending
    }

    mutating func clear() {
        current = nil
    }

    /// Claims a shortcut press. Returns the generation to schedule when this
    /// press opens a new start, or `nil` when it only folds into one that is
    /// already on its way.
    mutating func claim(shortcut: GlobalShortcut,
                        scope: SwitcherSessionScope,
                        reversed: Bool) -> UInt64? {
        if var pending = current {
            // The previous press was already released: this one is a fresh
            // session rather than another step through the old one.
            guard !pending.commitWhenReady else { return start(shortcut: shortcut, scope: scope, reversed: reversed) }
            if pending.scope == scope {
                let next = pending.additionalNavigation + (reversed ? -1 : 1)
                pending.additionalNavigation = max(-Self.navigationLimit, min(Self.navigationLimit, next))
                current = pending
            }
            return nil
        }
        return start(shortcut: shortcut, scope: scope, reversed: reversed)
    }

    private mutating func start(shortcut: GlobalShortcut,
                                scope: SwitcherSessionScope,
                                reversed: Bool) -> UInt64 {
        generation &+= 1
        current = SwitcherPendingSessionStart(generation: generation,
                                              shortcut: shortcut,
                                              scope: scope,
                                              reversed: reversed)
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        SwitcherSupport.isCurrentSessionStart(generation: generation,
                                              pendingGeneration: current?.generation)
    }

    /// Hands over the pending start and closes it out, so the session that
    /// follows can never be started twice from the same press.
    mutating func take(generation: UInt64) -> SwitcherPendingSessionStart? {
        guard isCurrent(generation) else { return nil }
        let pending = current
        current = nil
        return pending
    }

    mutating func discard(generation: UInt64) {
        guard isCurrent(generation) else { return }
        current = nil
    }
}

/// Everything the panel needs from outside the session: the preferences and
/// the grid the adapter has already measured. Read fresh for each event, the
/// same moment the switcher read them before.
///
/// The two layout questions are answered here rather than passed in, because
/// both depend on the session's own scope. Handing them in pre-answered is how
/// a window-scoped session used to get sized for the grouped layout on its
/// first frame: the scope the caller measured with was the one teardown had
/// reset, not the one the session was opening with.
struct SwitcherSessionEnvironment: Equatable {
    let iconRowMode: Bool
    let simpleMode: Bool
    let mergeWindowsByApp: Bool
    let gridColumns: Int
    let searchPinEnabled: Bool

    var usesIconRowLayout: Bool {
        SwitcherSupport.usesIconRowLayout(iconRowMode: iconRowMode, simpleMode: simpleMode)
    }

    func usesWindowRow(scope: SwitcherSessionScope) -> Bool {
        SwitcherSupport.usesWindowRow(simpleMode: simpleMode,
                                      mergeWindowsByApp: mergeWindowsByApp,
                                      sessionScope: scope)
    }

    func usesAppGroupsForMainShortcut(scope: SwitcherSessionScope) -> Bool {
        SwitcherSupport.usesAppGroupsForMainShortcut(iconRowLayout: usesIconRowLayout,
                                                     windowRow: usesWindowRow(scope: scope))
    }
}

/// What starts a session, once the window list has been enumerated.
struct SwitcherSessionStart {
    let windows: [SwitcherItem]
    let frontmostPID: pid_t
    let focusedSourceWindowID: CGWindowID?
    let shortcut: GlobalShortcut
    let scope: SwitcherSessionScope
    let reversed: Bool
    let additionalNavigation: Int
    let commitWhenReady: Bool

    init(windows: [SwitcherItem],
         frontmostPID: pid_t,
         focusedSourceWindowID: CGWindowID?,
         pending: SwitcherPendingSessionStart) {
        self.windows = windows
        self.frontmostPID = frontmostPID
        self.focusedSourceWindowID = focusedSourceWindowID
        shortcut = pending.shortcut
        scope = pending.scope
        reversed = pending.reversed
        additionalNavigation = pending.additionalNavigation
        commitWhenReady = pending.commitWhenReady
    }

    init(windows: [SwitcherItem],
         frontmostPID: pid_t,
         focusedSourceWindowID: CGWindowID? = nil,
         shortcut: GlobalShortcut,
         scope: SwitcherSessionScope = .allApps,
         reversed: Bool = false,
         additionalNavigation: Int = 0,
         commitWhenReady: Bool = false) {
        self.windows = windows
        self.frontmostPID = frontmostPID
        self.focusedSourceWindowID = focusedSourceWindowID
        self.shortcut = shortcut
        self.scope = scope
        self.reversed = reversed
        self.additionalNavigation = additionalNavigation
        self.commitWhenReady = commitWhenReady
    }
}

/// One keystroke, already resolved against the session's shortcuts. Turning a
/// `CGEvent` into this is the adapter's job; deciding what it means is not.
struct SwitcherKeyEvent {
    /// Which of the session's keys this is, in the order the switcher resolves
    /// them: the session's own shortcut wins over the Apps shortcut, which
    /// wins over the window shortcut, which wins over the arrows.
    enum Kind: Equatable {
        case sessionShortcut(shiftIsNavigationModifier: Bool)
        /// The Apps shortcut pressed during a window-scoped session.
        case appsShortcutInWindowScope(shiftIsNavigationModifier: Bool)
        case windowShortcut(positionalMatch: Bool, shiftIsNavigationModifier: Bool)
        case rightArrow
        case leftArrow
        case downArrow
        case upArrow
        case delete
        case escape
        case enter
        /// Anything else: a command letter or search text.
        case other
    }

    let kind: Kind
    let shiftHeld: Bool
    let isRepeat: Bool
    let keyCode: Int64
    /// The printable text this keystroke typed, already stripped of control
    /// characters. Only read for `.other`.
    let typedText: String?
    let now: TimeInterval

    init(kind: Kind,
         shiftHeld: Bool = false,
         isRepeat: Bool = false,
         keyCode: Int64 = 0,
         typedText: String? = nil,
         now: TimeInterval = 0) {
        self.kind = kind
        self.shiftHeld = shiftHeld
        self.isRepeat = isRepeat
        self.keyCode = keyCode
        self.typedText = typedText
        self.now = now
    }
}

/// What the session asks the adapter to do. The order in an outcome is the
/// order the switcher performed these in before, and it matters: the panel is
/// resized off published state, and publishing the selection re-measures the
/// icon row.
enum SwitcherSessionEffect: Equatable {
    /// Mirror the list, counts, search and scope into the published state.
    case publishSession
    /// Mirror the selection, which re-measures the icon row and the panel.
    case publishSelection
    case recomputeLayouts
    case resizePanel
    case schedulePanel
    /// Fill the preview map from what the capture cache already holds.
    case seedPreviews
    case refreshPreviews
    /// Keep only previews still backing a listed window, dropping one more.
    case prunePreviewsToVisible(dropping: CGWindowID?)
    case removePreview(CGWindowID)
    /// Presses that landed before the list was ready, replayed one at a time
    /// so each step measures the icon row the way a live press would.
    case replayNavigation(delta: Int, times: Int)
    case cancelIconRowEdgeHover
    /// Drop the panel and everything the adapter holds for this session.
    case teardown
    case activate(item: SwitcherItem, source: SwitcherSessionSource?, previousWindowID: CGWindowID?)
    case closeWindow(SwitcherItem)
    case closeSelectedWindow
    case quitSelectedApp
    /// Commit once the effects before it have been performed.
    case commit
}

/// The result of feeding one event to the session.
struct SwitcherSessionOutcome: Equatable {
    /// True when the event must not reach the app underneath. Key events the
    /// session owns are always swallowed; a modifier change only when it
    /// stepped the selection.
    var swallowsEvent = false
    var effects: [SwitcherSessionEffect] = []

    static let ignored = SwitcherSessionOutcome()
}

/// One switcher session: the list it opened with, where the selection is, what
/// the search has narrowed it to, which windows are on their way out, and how
/// it ends. No panel, no event tap, no Accessibility — `AppSwitcher` owns all
/// of that and feeds this events.
struct SwitcherSession {
    enum Event {
        case begin(SwitcherSessionStart)
        case keyDown(SwitcherKeyEvent)
        /// `shortcutModifiersHeld` is nil when the session has no shortcut,
        /// which is how a session opened without a key held stays open.
        case modifiersChanged(shortcutModifiersHeld: Bool?, shiftHeld: Bool, now: TimeInterval)
        case select(index: Int)
        case navigate(delta: Int, wrapping: Bool)
        case requestClose(SwitcherItem)
        /// The close did not take, or the window outlived the retries.
        case closeAbandoned(itemID: String)
        case closeConfirmed(itemID: String, windowID: CGWindowID)
        case appTerminated(pid: pid_t)
        case commit
        case cancel
    }

    /// Longest search a switcher panel accepts; past this the query is no
    /// longer narrowing anything.
    static let searchQueryLimit = 64

    private(set) var isActive = false
    /// Everything the session opened with, before the search narrowed it.
    private(set) var items: [SwitcherItem] = []
    /// What the panel shows: `items` minus whatever the search filtered out.
    private(set) var visibleItems: [SwitcherItem] = []
    private(set) var selectedIndex = 0
    private(set) var searchQuery = ""
    /// True once S pinned the search field open. While set, releasing the
    /// session's modifier no longer commits — search text can then be typed
    /// with no modifier held, so a letter never comes out as the modifier's
    /// special character (⌥ on its own types symbols on layouts like US,
    /// e.g. ⌥S types "ß").
    private(set) var isSearchPinned = false
    private(set) var scope: SwitcherSessionScope = .allApps
    private(set) var shortcut: GlobalShortcut?
    /// The on-screen window when the session opened — becomes the
    /// second-most-recent window on commit, so a flick toggles straight back.
    /// Cleared if that window is closed during the session: a window the user
    /// just got rid of is not somewhere to send them back to.
    private(set) var startWindowID: CGWindowID?
    private(set) var source: SwitcherSessionSource?
    /// Windows already asked to close, still listed until they are really
    /// gone. Releasing the shortcut skips them, so they are never raised on
    /// the way out.
    private(set) var closingItemIDs: Set<String> = []
    private(set) var commitPendingForClose = false

    private var shiftBackNavigationHeld = false
    /// Pressing Shift mid-session already steps back once, so the Tab landing
    /// in that same physical chord must not step again — but later Tabs during
    /// the same Shift hold must keep walking the list (issue #784). The chord
    /// is recognized by time: anything after this deadline is a deliberate
    /// separate press.
    private var shiftBackChordDeadline: TimeInterval = 0
    /// True once the user moved the selection themselves.
    private var userNavigated = false

    var itemCount: Int { items.count }

    var selectedItem: SwitcherItem? {
        visibleItems.indices.contains(selectedIndex) ? visibleItems[selectedIndex] : nil
    }

    var selectedItemID: String? { selectedItem?.id }

    func contains(itemID: String) -> Bool {
        items.contains { $0.id == itemID }
    }

    // MARK: - Interface

    mutating func apply(_ event: Event, environment: SwitcherSessionEnvironment) -> SwitcherSessionOutcome {
        switch event {
        case .begin(let start):
            return SwitcherSessionOutcome(effects: begin(start, environment: environment))
        case .keyDown(let key):
            return handleKeyDown(key, environment: environment)
        case .modifiersChanged(let held, let shiftHeld, let now):
            return handleModifiersChanged(shortcutModifiersHeld: held,
                                          shiftHeld: shiftHeld,
                                          now: now,
                                          environment: environment)
        case .select(let index):
            return SwitcherSessionOutcome(effects: select(index: index))
        case .navigate(let delta, let wrapping):
            return SwitcherSessionOutcome(effects: navigate(by: delta,
                                                            wrapping: wrapping,
                                                            environment: environment))
        case .requestClose(let item):
            return SwitcherSessionOutcome(effects: requestClose(item))
        case .closeAbandoned(let itemID):
            closingItemIDs.remove(itemID)
            return SwitcherSessionOutcome(effects: resumePendingCommitAfterClose())
        case .closeConfirmed(let itemID, let windowID):
            return SwitcherSessionOutcome(effects: applyClosedWindowRemoval(itemID: itemID,
                                                                            windowID: windowID))
        case .appTerminated(let pid):
            return SwitcherSessionOutcome(effects: applyTerminatedApp(pid: pid))
        case .commit:
            return SwitcherSessionOutcome(effects: commit())
        case .cancel:
            guard isActive else { return .ignored }
            return SwitcherSessionOutcome(effects: teardown())
        }
    }

    // MARK: - Session lifecycle

    private mutating func begin(_ start: SwitcherSessionStart,
                                environment: SwitcherSessionEnvironment) -> [SwitcherSessionEffect] {
        // The foreground window is what a session is measured against, and it
        // does not always exist: an app left with no windows, or with all of
        // them minimized or on another Space, still owns the keyboard. The
        // switcher opens either way (issue #324).
        let sourceItem = SwitcherSupport.sessionSourceItem(frontmostPID: start.frontmostPID,
                                                          focusedWindowID: start.focusedSourceWindowID,
                                                          items: start.windows)
        let list = Self.ordered(start.windows, currentID: sourceItem?.id)

        isActive = true
        items = list
        searchQuery = ""
        isSearchPinned = false
        visibleItems = list
        // Optional.map: a session that starts with no source clears the
        // context instead of keeping the previous session's.
        source = sourceItem.map(SwitcherSessionSource.init)
        startWindowID = sourceItem?.windowID
        scope = start.scope
        closingItemIDs = []
        commitPendingForClose = false
        userNavigated = false
        // Index 0 is the on-screen window; index 1 is the most-recently-used
        // other window — the toggle target, which may be another window of the
        // same app. Shift starts from the far end. With no on-screen window
        // the session opens on the first entry from another app.
        selectedIndex = start.scope == .frontmostApp
            ? SwitcherSupport.initialWindowScopedSelectionIndex(itemCount: list.count,
                                                                hasForegroundItem: sourceItem != nil,
                                                                reversed: start.reversed)
            : Self.initialSelectionIndex(
                in: list,
                reversed: start.reversed,
                hasForegroundItem: sourceItem != nil,
                frontmostPID: SwitcherSupport.appPID(forFrontmost: start.frontmostPID, items: list),
                // `scope` above is already the new one, so the icon row can
                // never be measured against the scope teardown left behind.
                usesAppGroups: environment.usesAppGroupsForMainShortcut(scope: scope))
        shortcut = start.shortcut
        shiftBackNavigationHeld = start.reversed && start.shortcut.shiftIsNavigationModifier
        shiftBackChordDeadline = 0

        var effects: [SwitcherSessionEffect] = [.publishSession, .recomputeLayouts,
                                                .seedPreviews, .publishSelection]
        if start.additionalNavigation != 0 {
            effects.append(.replayNavigation(delta: start.additionalNavigation < 0 ? -1 : 1,
                                             times: abs(start.additionalNavigation)))
        }
        if start.commitWhenReady {
            effects.append(.commit)
        } else {
            effects.append(.refreshPreviews)
            effects.append(.schedulePanel)
        }
        return effects
    }

    /// Puts the window the user is looking at first. The enumerator already
    /// ordered everything else by how recently it was used, so the entry right
    /// after the current one is the window they came from — this only has to
    /// make sure the current one leads, even in the moment right after a
    /// switch, when the window server has not caught up yet.
    static func ordered(_ items: [SwitcherItem], currentID: String?) -> [SwitcherItem] {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else { return items }
        var ordered = items
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    static func initialSelectionIndex(in items: [SwitcherItem],
                                      reversed: Bool,
                                      hasForegroundItem: Bool,
                                      frontmostPID: pid_t,
                                      usesAppGroups: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        guard usesAppGroups else {
            return SwitcherSupport.initialSelectionPosition(pids: items.map(\.pid),
                                                            hasForegroundEntry: hasForegroundItem,
                                                            frontmostPID: frontmostPID,
                                                            reversed: reversed)
        }

        // The icon row steps app by app, so the same rule runs over the groups
        // and lands on the chosen group's representative window.
        let groups = SwitcherSupport.appGroups(items: items)
        guard !groups.isEmpty else { return 0 }
        let groupIndex = SwitcherSupport.initialSelectionPosition(pids: groups.map(\.pid),
                                                                  hasForegroundEntry: hasForegroundItem,
                                                                  frontmostPID: frontmostPID,
                                                                  reversed: reversed)
        return groups[groupIndex].representativeIndex
    }

    /// Activates the current selection.
    private mutating func commit() -> [SwitcherSessionEffect] {
        guard isActive else { return [] }
        guard closingItemIDs.isEmpty else {
            commitPendingForClose = true
            return []
        }
        // A window that was just closed is still listed for a moment; letting
        // go right after must land on what takes its place, never on it.
        let selection = SwitcherSupport.commitTargetID(itemIDs: visibleItems.map(\.id),
                                                       selectedIndex: selectedIndex,
                                                       closingItemIDs: closingItemIDs)
            .flatMap { id in visibleItems.first { $0.id == id } }
        let committedSource = source
        let previousWindowID = startWindowID
        var effects = teardown()
        if let selection {
            effects.append(.activate(item: selection,
                                     source: committedSource,
                                     previousWindowID: previousWindowID))
        }
        return effects
    }

    private mutating func resumePendingCommitAfterClose() -> [SwitcherSessionEffect] {
        guard commitPendingForClose, closingItemIDs.isEmpty, isActive else { return [] }
        commitPendingForClose = false
        return commit()
    }

    private mutating func teardown() -> [SwitcherSessionEffect] {
        isActive = false
        items = []
        visibleItems = []
        selectedIndex = 0
        searchQuery = ""
        isSearchPinned = false
        startWindowID = nil
        source = nil
        shortcut = nil
        scope = .allApps
        shiftBackNavigationHeld = false
        shiftBackChordDeadline = 0
        closingItemIDs = []
        commitPendingForClose = false
        userNavigated = false
        return [.teardown]
    }

    // MARK: - Keys

    private mutating func handleKeyDown(_ key: SwitcherKeyEvent,
                                        environment: SwitcherSessionEnvironment) -> SwitcherSessionOutcome {
        // Initial presses are claimed directly on the tap thread and queued
        // asynchronously. Reaching here after that session ended is only a
        // race with teardown; the already-claimed key must stay swallowed.
        guard isActive else { return SwitcherSessionOutcome(swallowsEvent: true) }

        var effects: [SwitcherSessionEffect] = []
        switch key.kind {
        case .sessionShortcut(let shiftIsNavigationModifier),
             .appsShortcutInWindowScope(let shiftIsNavigationModifier):
            // A window-scoped session keeps its list when the Apps shortcut is
            // pressed with overlapping modifiers instead of expanding to all apps.
            if shiftIsNavigationModifier, key.shiftHeld, consumesShiftBackChordTab(now: key.now) {
                break
            }
            let delta = shiftIsNavigationModifier && key.shiftHeld ? -1 : 1
            // Holding the key stops at the list's end instead of wrapping, like
            // the system switcher; a fresh press wraps around (issue #187).
            effects = navigate(by: delta, wrapping: !key.isRepeat, environment: environment)
        case .windowShortcut(let positionalMatch, let shiftIsNavigationModifier):
            // Jumps between the selected app's windows. In the icon row mode
            // that is the grouped app; in the plain grid it hops across the
            // same app's thumbnails, so the key works in both looks.
            let delta = SwitcherSupport.windowNavigationDelta(
                positionalMatch: positionalMatch,
                shiftIsNavigationModifier: shiftIsNavigationModifier,
                shiftHeld: key.shiftHeld
            )
            if scope == .frontmostApp {
                effects = navigate(by: delta, wrapping: !key.isRepeat, environment: environment)
            } else {
                effects = navigateWindowInSelectedApp(by: delta)
            }
        case .rightArrow:
            effects = navigate(by: 1, wrapping: true, environment: environment)
        case .leftArrow:
            effects = navigate(by: -1, wrapping: true, environment: environment)
        case .downArrow:
            effects = moveRow(by: environment.gridColumns, environment: environment)
        case .upArrow:
            effects = moveRow(by: -environment.gridColumns, environment: environment)
        case .delete:
            effects = removeLastSearchCharacter()
        case .escape:
            effects = teardown()
        case .enter:
            effects = commit()
        case .other:
            // The first letter typed is a command: W closes the highlighted
            // window, Q quits its app, S pins the search field open so typing
            // no longer needs the session's modifier held. Once a search is
            // under way (or already pinned) every key belongs to the query,
            // so all three letters can still be typed.
            if searchQuery.isEmpty, !isSearchPinned,
               let action = SwitcherSupport.letterAction(typedCharacter: key.typedText,
                                                         keyCode: key.keyCode,
                                                         pinSearchEnabled: environment.searchPinEnabled) {
                // One window per press: holding the key down must never walk
                // through the list closing or quitting everything on the way.
                guard !key.isRepeat else { break }
                switch action {
                case .closeWindow: effects = [.closeSelectedWindow]
                case .quitApp: effects = [.quitSelectedApp]
                case .pinSearch:
                    isSearchPinned = true
                    effects = [.publishSession]
                }
            } else if let text = key.typedText {
                effects = appendSearch(text)
            }
            // Swallow stray keys so they never leak into the focused app.
        }
        return SwitcherSessionOutcome(swallowsEvent: true, effects: effects)
    }

    private mutating func handleModifiersChanged(shortcutModifiersHeld: Bool?,
                                                 shiftHeld: Bool,
                                                 now: TimeInterval,
                                                 environment: SwitcherSessionEnvironment) -> SwitcherSessionOutcome {
        guard isActive, !isSearchPinned else { return .ignored }
        if let shortcutModifiersHeld, !shortcutModifiersHeld {
            return SwitcherSessionOutcome(effects: commit())
        }
        defer { shiftBackNavigationHeld = shiftHeld }
        guard let shortcut,
              SwitcherSupport.shouldNavigateBackwardOnShiftPress(
                shiftIsNavigationModifier: shortcut.shiftIsNavigationModifier,
                wasShiftHeld: shiftBackNavigationHeld,
                isShiftHeld: shiftHeld)
        else { return .ignored }
        let effects = navigate(by: -1, wrapping: true, environment: environment)
        shiftBackChordDeadline = now + SwitcherSupport.shiftBackChordWindow
        return SwitcherSessionOutcome(swallowsEvent: true, effects: effects)
    }

    /// True exactly once for the Tab that belongs to the Shift press that just
    /// stepped back; consuming it keeps a Shift+Tab chord at one step.
    private mutating func consumesShiftBackChordTab(now: TimeInterval) -> Bool {
        guard now < shiftBackChordDeadline else { return false }
        shiftBackChordDeadline = 0
        return true
    }

    // MARK: - Selection

    private mutating func navigate(by delta: Int,
                                   wrapping: Bool,
                                   environment: SwitcherSessionEnvironment) -> [SwitcherSessionEffect] {
        var effects: [SwitcherSessionEffect] = [.cancelIconRowEdgeHover]
        guard !visibleItems.isEmpty else { return effects }
        userNavigated = true
        if environment.usesAppGroupsForMainShortcut(scope: scope), scope == .allApps {
            selectedIndex = SwitcherSupport.nextAppSelectionIndex(items: visibleItems,
                                                                  selectedIndex: selectedIndex,
                                                                  delta: delta,
                                                                  wrapping: wrapping)
            effects.append(.publishSelection)
            return effects
        }
        let next = selectedIndex + delta
        if !wrapping, !visibleItems.indices.contains(next) { return effects }
        selectedIndex = (next + visibleItems.count) % visibleItems.count
        effects.append(.publishSelection)
        return effects
    }

    private mutating func navigateWindowInSelectedApp(by delta: Int) -> [SwitcherSessionEffect] {
        userNavigated = true
        selectedIndex = SwitcherSupport.nextWindowSelectionIndexWithinApp(items: visibleItems,
                                                                          selectedIndex: selectedIndex,
                                                                          delta: delta)
        return [.publishSelection]
    }

    /// Row jump (↑/↓): moves without wrapping so the selection stays put at
    /// the grid edges.
    private mutating func moveRow(by delta: Int,
                                  environment: SwitcherSessionEnvironment) -> [SwitcherSessionEffect] {
        if environment.usesIconRowLayout {
            return navigateWindowInSelectedApp(by: delta < 0 ? -1 : 1)
        }
        guard delta != 0 else { return [] }
        let target = SwitcherSupport.gridSelectionIndex(after: selectedIndex,
                                                        itemCount: visibleItems.count,
                                                        columns: environment.gridColumns,
                                                        movingDown: delta > 0)
        guard target != selectedIndex else { return [] }
        userNavigated = true
        selectedIndex = target
        return [.publishSelection]
    }

    private mutating func select(index: Int) -> [SwitcherSessionEffect] {
        guard isActive, visibleItems.indices.contains(index) else { return [] }
        userNavigated = true
        selectedIndex = index
        return [.publishSelection]
    }

    // MARK: - Search

    private mutating func appendSearch(_ text: String) -> [SwitcherSessionEffect] {
        let clean = Self.sanitizedSearchInput(text)
        guard !clean.isEmpty else { return [] }
        let preferredID = selectedItemID
        let remaining = max(0, Self.searchQueryLimit - searchQuery.count)
        guard remaining > 0 else { return [] }
        searchQuery += String(clean.prefix(remaining))
        return applySearchFilter(preferredItemID: preferredID)
    }

    private mutating func removeLastSearchCharacter() -> [SwitcherSessionEffect] {
        guard !searchQuery.isEmpty else { return [] }
        let preferredID = selectedItemID
        searchQuery.removeLast()
        return applySearchFilter(preferredItemID: preferredID)
    }

    static func sanitizedSearchInput(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
        }))
    }

    private mutating func applySearchFilter(preferredItemID: String?) -> [SwitcherSessionEffect] {
        let records = items.map { item in
            SwitcherSearchRecord(id: item.id, title: item.title, appName: item.appName)
        }
        let visibleIDs = Set(SwitcherSupport.filteredSearchIDs(records: records, query: searchQuery))
        visibleItems = items.filter { visibleIDs.contains($0.id) }
        selectedIndex = SwitcherSupport.searchSelectionIndex(itemIDs: visibleItems.map(\.id),
                                                             preferredID: preferredItemID,
                                                             previousIndex: selectedIndex)
        return [.publishSession, .publishSelection, .recomputeLayouts, .resizePanel]
    }

    // MARK: - Closing and quitting

    private mutating func requestClose(_ item: SwitcherItem) -> [SwitcherSessionEffect] {
        guard isActive,
              visibleItems.contains(where: { $0.id == item.id }),
              !closingItemIDs.contains(item.id),
              item.windowID != nil
        else { return [] }
        closingItemIDs.insert(item.id)
        return [.closeWindow(item)]
    }

    /// Removes the app's windows from the list and keeps the session open —
    /// mirroring the system switcher.
    private mutating func applyTerminatedApp(pid: pid_t) -> [SwitcherSessionEffect] {
        let removedIDs = Set(items.lazy.filter { $0.pid == pid }.map(\.id))
        closingItemIDs.subtract(removedIDs)
        let removedBeforeSelection = visibleItems[..<min(selectedIndex, visibleItems.count)]
            .filter { $0.pid == pid }.count
        items.removeAll { $0.pid == pid }
        visibleItems.removeAll { $0.pid == pid }

        guard !items.isEmpty else { return teardown() }
        guard !visibleItems.isEmpty else {
            selectedIndex = 0
            return [.publishSession, .prunePreviewsToVisible(dropping: nil), .publishSelection,
                    .recomputeLayouts, .resizePanel] + resumePendingCommitAfterClose()
        }
        selectedIndex = min(max(0, selectedIndex - removedBeforeSelection), visibleItems.count - 1)
        return [.publishSession, .prunePreviewsToVisible(dropping: nil), .publishSelection,
                .recomputeLayouts, .resizePanel] + resumePendingCommitAfterClose()
    }

    private mutating func applyClosedWindowRemoval(itemID: String,
                                                   windowID: CGWindowID) -> [SwitcherSessionEffect] {
        let state = SwitcherSupport.closeState(afterRemoving: itemID,
                                               itemIDs: visibleItems.map(\.id),
                                               selectedIndex: selectedIndex)
        guard state.didRemove else {
            // Filtered out of the visible list by a search: only the session's
            // own bookkeeping has to catch up.
            items.removeAll { $0.id == itemID }
            closingItemIDs.remove(itemID)
            if source?.itemID == itemID { startWindowID = nil }
            guard !items.isEmpty else { return teardown() }
            return [.publishSession, .removePreview(windowID)]
                + applySearchFilter(preferredItemID: selectedItemID)
                + resumePendingCommitAfterClose()
        }

        items.removeAll { $0.id == itemID }
        let remaining = Set(state.remainingItemIDs)
        visibleItems = visibleItems.filter { remaining.contains($0.id) }
        closingItemIDs.remove(itemID)
        if source?.itemID == itemID { startWindowID = nil }

        guard !state.shouldEndSession else {
            if items.isEmpty || searchQuery.isEmpty { return teardown() }
            selectedIndex = 0
            return [.publishSession, .prunePreviewsToVisible(dropping: windowID), .publishSelection,
                    .recomputeLayouts, .resizePanel] + resumePendingCommitAfterClose()
        }

        selectedIndex = state.selectedIndex
        return [.publishSession, .prunePreviewsToVisible(dropping: windowID), .publishSelection,
                .recomputeLayouts, .resizePanel] + resumePendingCommitAfterClose()
    }
}
