import SwiftUI
import AppKit

// Footer menus (language switcher + options) — AppKit NSMenu coordinators.
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

// ── Language switcher (plain button → NSMenu, avoids accent color tinting) ──
struct LanguageSwitcher: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        // nil in menu-bar mode (NSPopover host never injects it) → keepVisible no-ops.
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        weak var notchVM: NotchViewModel?
        init(store: UsageStore) { self.store = store }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self
            for lang in AppLanguage.allCases {
                let item = NSMenuItem(title: lang.displayName, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = lang
                if lang == store.language { item.state = .on }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pick(_ item: NSMenuItem) {
            if let lang = item.representedObject as? AppLanguage {
                store.setLanguage(lang)
            }
        }

        // keepVisible: hold the notch panel open while this NSMenu is up (the cursor
        // leaves the notch's hover zone to reach the menu items).
        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}

/// Footer "⋯" menu: the durable-archive toggle + a confirmed clear. Mirrors
/// LanguageSwitcher's NSButton→NSMenu coordinator pattern; localized strings are
/// threaded in from the popover's Localizer (the menu lives in AppKit, outside
/// the SwiftUI environment).
struct OptionsMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.loc = loc
        // nil in menu-bar mode (NSPopover host never injects it) → keepVisible no-ops.
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, loc: loc) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        var loc: Localizer
        weak var notchVM: NotchViewModel?
        init(store: UsageStore, loc: Localizer) { self.store = store; self.loc = loc }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self

            // Display location: menu bar vs notch. A disabled header + one
            // checkable item per mode (mirrors the LanguageSwitcher pattern).
            let modeHeader = NSMenuItem(title: loc("displayModeHeader"), action: nil, keyEquivalent: "")
            modeHeader.isEnabled = false
            menu.addItem(modeHeader)
            for mode in DisplayMode.allCases {
                let item = NSMenuItem(title: mode.label(loc),
                                      action: #selector(pickDisplayMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = store.displayMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let toggle = NSMenuItem(title: loc("archiveToggle"),
                                    action: #selector(toggleArchive), keyEquivalent: "")
            toggle.target = self
            toggle.state = store.archiveHistoryLocally ? .on : .off
            menu.addItem(toggle)

            // Informational (disabled) line: live archived-day count once there's
            // data, else the "what is this" hint for first-timers.
            let count = store.archivedDayCount
            let noteTitle = count > 0 ? String(format: loc("archiveCount"), count) : loc("archiveNote")
            let note = NSMenuItem(title: noteTitle, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)

            menu.addItem(.separator())

            let clear = NSMenuItem(title: loc("archiveClear"),
                                   action: #selector(clearArchive), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pickDisplayMode(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let mode = DisplayMode(rawValue: raw) {
                store.setDisplayMode(mode)
            }
        }

        @objc func toggleArchive() {
            store.setArchiveHistoryLocally(!store.archiveHistoryLocally)
        }

        @objc func clearArchive() {
            // Hold the notch open across the modal; in notch mode also bring the app
            // forward so the alert (from a non-activating panel) isn't buried.
            notchVM?.preventClose = true
            if notchVM != nil { NSApp.activate(ignoringOtherApps: true) }
            defer { notchVM?.preventClose = false }

            let alert = NSAlert()
            alert.messageText = loc("archiveClearTitle")
            alert.informativeText = loc("archiveClearBody")
            alert.alertStyle = .warning
            alert.addButton(withTitle: loc("archiveClearConfirm"))
            alert.addButton(withTitle: loc("archiveClearCancel"))
            // First button (Clear) == NSAlertFirstButtonReturn (1000); compare by
            // rawValue so the constant resolves across SDK variants.
            if alert.runModal().rawValue == 1000 {
                store.clearArchive()
            }
        }

        // keepVisible: hold the notch panel open while the ⋯ NSMenu is up.
        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}

