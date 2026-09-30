import AppKit

/// Standard-shape main menu: App, Edit, Window. An LSUIElement app gets
/// none automatically, so without it ⌘Q, ⌘W, ⌘H, Cut/Copy/Paste and the
/// standard About / Hide / Show All commands have nothing to route through
/// when an editor window is key. The menu shows at the top of the screen
/// whenever one of our windows is focused.
///
/// `Edit` deliberately omits Undo/Redo — those are handled inside the
/// editor view via `.onKeyPress` so they're scoped to the editor's
/// UndoManager without fighting text-field native undo.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App menu — the title of the first item is ignored; the system
        // always displays the app's name.
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Pepper",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pepper",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pepper",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — text-field clipboard actions via the responder
        // chain (NSText handles these natively for any focused NSTextView
        // / NSTextField, which is what SwiftUI TextFields wrap).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        // Window menu — Close / Minimize. `NSApp.windowsMenu` lets
        // AppKit auto-populate it with the app's live window list.
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
