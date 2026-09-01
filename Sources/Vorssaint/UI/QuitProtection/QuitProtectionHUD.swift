// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Small, non-activating feedback panel. It is intentionally independent from
/// Settings so showing a confirmation never changes the target application.
final class QuitProtectionHUD {
    private static let minimumSize = CGSize(width: 300, height: 48)
    private static let textInset: CGFloat = 12
    private var size = QuitProtectionHUD.minimumSize
    private var panel: NSPanel?

    /// The confirmation lines are localized and formatted with the shortcut
    /// symbol, so their rendered width is only known at show time. Widest of
    /// the shipped translations is ~300pt of text, well past what the fixed
    /// 300pt panel left for it.
    private static func fittingSize(title: String, detail: String) -> CGSize {
        let text = max((title as NSString).size(withAttributes: [.font: ContentView.titleFont]).width,
                       (detail as NSString).size(withAttributes: [.font: ContentView.detailFont]).width)
        return CGSize(width: max(minimumSize.width, (text + textInset * 2).rounded(.up)),
                      height: minimumSize.height)
    }

    func show(title: String, detail: String) {
        size = Self.fittingSize(title: title, detail: detail)
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.contentView = ContentView(frame: CGRect(origin: .zero, size: size))
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                        .stationary, .ignoresCycle]
            self.panel = panel
        }

        guard let content = panel?.contentView as? ContentView else { return }
        panel?.setContentSize(size)
        content.update(title: title, detail: detail)
        positionPanel()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        // Event taps can arrive between normal AppKit drawing passes. Draw now
        // so a short confirmation never waits for another app event to appear.
        panel?.display()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (frame.midX - size.width / 2).rounded(),
                                     y: (frame.minY + 18).rounded()))
    }

    private final class ContentView: NSView {
        static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let detailFont = NSFont.systemFont(ofSize: 10.5)

        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            title.font = Self.titleFont
            title.textColor = .white
            title.alignment = .center
            detail.font = Self.detailFont
            detail.textColor = .white.withAlphaComponent(0.68)
            detail.alignment = .center
            addSubview(title)
            addSubview(detail)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            let inset = QuitProtectionHUD.textInset
            title.frame = CGRect(x: inset, y: 23, width: bounds.width - inset * 2, height: 17)
            detail.frame = CGRect(x: inset, y: 7, width: bounds.width - inset * 2, height: 14)
        }

        func update(title: String, detail: String) {
            self.title.stringValue = title
            self.detail.stringValue = detail
            setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ". "))
            needsLayout = true
            // The pill is drawn from bounds, so a width change has to repaint.
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let body = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: body,
                                    xRadius: body.height / 2,
                                    yRadius: body.height / 2)
            NSColor(calibratedWhite: 0.09, alpha: 0.95).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
