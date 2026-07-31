import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindowController: NSWindowController?
    private var transcriptsWindowController: NSWindowController?
    private var recordingObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 400)
        popover.contentViewController = NSHostingController(
            rootView: MenuContent(
                model: model,
                onOpenTranscripts: { [weak self] in
                    self?.openTranscripts()
                }
            )
        )
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = statusImage(isRecording: false)
            button.imagePosition = .imageOnly
            button.toolTip = "MinuteMark"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        recordingObserver = model.$isRecording
            .removeDuplicates()
            .sink { [weak self] isRecording in
                self?.statusItem?.button?.image = self?.statusImage(
                    isRecording: isRecording
                )
            }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            popover?.performClose(nil)
            showContextMenu()
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        guard let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }

        let menu = NSMenu()
        let transcriptsItem = NSMenuItem(
            title: "Transcripts…",
            action: #selector(openTranscripts),
            keyEquivalent: ""
        )
        transcriptsItem.target = self
        transcriptsItem.image = NSImage(
            systemSymbolName: "doc.text.magnifyingglass",
            accessibilityDescription: "Transcripts"
        )
        menu.addItem(transcriptsItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        )
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MinuteMark",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openTranscripts() {
        popover?.performClose(nil)
        if transcriptsWindowController == nil {
            let hostingController = NSHostingController(
                rootView: TranscriptLibraryView(appModel: model)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "MinuteMark Transcripts"
            window.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable
            ]
            window.setContentSize(NSSize(width: 1_180, height: 760))
            window.minSize = NSSize(width: 960, height: 600)
            window.isReleasedWhenClosed = false
            window.center()
            transcriptsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        transcriptsWindowController?.showWindow(nil)
        transcriptsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(model: model)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "MinuteMark Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 480, height: 230))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func statusImage(isRecording: Bool) -> NSImage? {
        let name = isRecording ? "record.circle.fill" : "waveform.badge.mic"
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "MinuteMark"
        ) ?? NSImage(named: NSImage.applicationIconName)
        image?.isTemplate = !isRecording
        return image
    }
}
