import AppKit

/// Standard-shape main menu: App, File, Edit, Window. An LSUIElement app
/// gets none automatically, so without it ⌘Q, ⌘W, ⌘H, Cut/Copy/Paste and
/// the standard About / Hide / Show All commands have nothing to route
/// through when an editor window is key. The menu shows at the top of the
/// screen whenever one of our windows is focused.
///
/// Check for Updates, Settings (⌘,) and Open Recording (⌘O) go to
/// `AppDelegate`; Export (⌘E), Send to Orbis (⇧⌘E), Undo and Redo to the
/// key editor (`EditorWindowController`), with `AppDelegate` disabling
/// them when no editor is key. They use their own actions, not `undo:`/`redo:`, so
/// they drive the editor's undo stack rather than a focused text field's.
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
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(AppDelegate.checkForUpdates(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.showSettingsWindow(_:)),
                        keyEquivalent: ",")
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

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open Recording…",
                         action: #selector(AppDelegate.showOpenRecordingPanel(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(.separator())
        // The editor's two toolbar buttons, with shortcuts.
        fileMenu.addItem(withTitle: "Export…",
                         action: #selector(EditorWindowController.exportVideo(_:)),
                         keyEquivalent: "e")
        let sendToOrbis = NSMenuItem(title: "Send to Orbis…",
                                     action: #selector(EditorWindowController.sendToOrbis(_:)),
                                     keyEquivalent: "e")
        sendToOrbis.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(sendToOrbis)

        // Edit menu — text-field clipboard actions via the responder
        // chain (NSText handles these natively for any focused NSTextView
        // / NSTextField, which is what SwiftUI TextFields wrap).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo",
                         action: #selector(EditorWindowController.undoEditorChange(_:)),
                         keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: #selector(EditorWindowController.redoEditorChange(_:)),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
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
