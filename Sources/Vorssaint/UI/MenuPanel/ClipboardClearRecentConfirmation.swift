// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Asks before "Clear recent" deletes anything. The button stores the recent
/// IDs it saw, and only those are deleted, so a copy made while the alert is
/// open survives and the count shown is the count removed.
struct ClipboardClearRecentConfirmation: ViewModifier {
    @Binding var entryIDs: Set<UUID>?
    @ObservedObject private var l10n = L10n.shared

    func body(content: Content) -> some View {
        let text = FeatureStrings.clipboard(l10n.language)
        content.alert(text.clearRecent,
                      isPresented: Binding(get: { entryIDs != nil }, set: { if !$0 { entryIDs = nil } }),
                      presenting: entryIDs) { ids in
            Button(text.cancel, role: .cancel) {}
            Button(text.clearRecent, role: .destructive) {
                ClipboardHistoryService.shared.clearRecent(confirmedIDs: ids)
            }
        } message: { ids in
            Text(String(format: text.clearRecentConfirmFormat, ids.count))
        }
    }
}
