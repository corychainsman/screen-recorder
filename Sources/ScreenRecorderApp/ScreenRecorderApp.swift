import AppKit
import Combine
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = ScreenRecorder()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var recordMenuItem: NSMenuItem?
    private var settingsWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var isToggling = false
    private var singleInstanceLock: SingleInstanceLock?
    private var selectionManager: ScreenSelectionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lock = SingleInstanceLock(lockPath: "/tmp/screen-recorder-menubar.lock")
        guard lock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        singleInstanceLock = lock

        NSApp.applicationIconImage = makeAppIcon()
        configureStatusItem()
        observeRecorderState()
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Screen Recorder"
        setButtonImage(isRecording: false)
        configureMenu()
        statusItem = item
    }

    private func configureMenu() {
        let menu = NSMenu()

        let recordItem = NSMenuItem(title: "Record", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit ScreenRecorder", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
        recordMenuItem = recordItem
    }

    private func observeRecorderState() {
        recorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.setButtonImage(isRecording: isRecording)
                self?.recordMenuItem?.title = isRecording ? "Stop Recording" : "Record"
            }
            .store(in: &cancellables)
    }

    private func setButtonImage(isRecording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = isRecording ? "stop.circle.fill" : "record.circle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screen Recorder")
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleRecording()
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu(with: sender)
        } else {
            toggleRecording()
        }
    }

    private func showStatusMenu(with button: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        recordMenuItem?.title = recorder.isRecording ? "Stop Recording" : "Record"
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    private func toggleRecording() {
        guard !isToggling else { return }

        if recorder.isRecording {
            isToggling = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isToggling = false }
                if let outputURL = await self.recorder.stopRecording() {
                    self.revealInFinder(outputURL)
                }
            }
            return
        }

        // Starting — check if multi-display selection is needed
        isToggling = true
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.current
                let displays = content.displays

                if displays.count <= 1 {
                    defer { self.isToggling = false }
                    await self.recorder.startRecording()
                } else {
                    // Present picker; isToggling stays true until a selection or cancel
                    let manager = ScreenSelectionManager(displays: displays) { [weak self] chosen in
                        guard let self else { return }
                        defer { self.isToggling = false }
                        self.selectionManager = nil
                        guard let chosen else { return } // cancelled
                        Task { @MainActor in
                            await self.recorder.startRecording(display: chosen)
                        }
                    }
                    self.selectionManager = manager
                    manager.present()
                }
            } catch {
                self.isToggling = false
            }
        }
    }

    private func revealInFinder(_ outputURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    @objc
    private func openSettings() {
        activateAsRegularApp()

        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView()
        let host = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 240))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
    }

    private func activateAsRegularApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = makeAppIcon()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func makeAppIcon() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()

        // Dark grey background
        NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Red recording dot (radius ~38% of canvas)
        let dotRadius = size.width * 0.38
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dotRect = NSRect(
            x: center.x - dotRadius, y: center.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        )
        NSColor(srgbRed: 1.0, green: 0.231, blue: 0.188, alpha: 1).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        return image
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Screen selection overlay

/// Presents a full-screen semi-transparent overlay on every display, showing a large number
/// so the user can click or type a digit to choose which screen to record.
@MainActor
final class ScreenSelectionManager: NSObject {
    private let displays: [SCDisplay]
    private let completion: (SCDisplay?) -> Void

    private var overlayWindows: [NSWindow] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(displays: [SCDisplay], completion: @escaping (SCDisplay?) -> Void) {
        self.displays = displays
        self.completion = completion
    }

    func present() {
        // Build one overlay window per NSScreen, matched to SCDisplay via CGDirectDisplayID
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let scDisplay = scDisplay(for: screen) else { continue }

            let window = makeOverlayWindow(screen: screen, number: index + 1, scDisplay: scDisplay)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        // Activate the app and make the first overlay the key window so that
        // keyDown events are delivered to the local event monitor.
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.first?.makeKeyAndOrderFront(nil)

        installEventMonitors()
    }

    // MARK: - Private

    private func scDisplay(for screen: NSScreen) -> SCDisplay? {
        guard
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return displays.first(where: { $0.displayID == screenID })
    }

    private func makeOverlayWindow(screen: NSScreen, number: Int, scDisplay: SCDisplay) -> NSWindow {
        let frame = screen.frame
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.backgroundColor = NSColor(white: 0, alpha: 0.55)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        // Large centered number label
        let fontSize = min(frame.width, frame.height) * 0.28
        let label = NSTextField(labelWithString: "\(number)")
        label.font = NSFont.boldSystemFont(ofSize: fontSize)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        label.sizeToFit()

        // Center the label in the window's content view
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        window.contentView = contentView

        // Handle mouse-down in the overlay itself
        window.clickHandler = { [weak self] in
            self?.select(atIndex: number - 1)
        }

        return window
    }

    private func installEventMonitors() {
        // Local monitor — events inside our overlay windows
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event: event)
            return nil // consume the event
        }
        // Global monitor — events outside our windows (user clicks on another screen's overlay
        // which may be the "active" space from AppKit's perspective)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event: event)
        }
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            handleClick(at: event.locationInWindow, window: event.window)
        case .keyDown:
            handleKey(event: event)
        default:
            break
        }
    }

    private func handleClick(at locationInWindow: NSPoint, window: NSWindow?) {
        // Find which overlay was clicked by hit-testing the cursor position (screen coords)
        let screenPoint = NSEvent.mouseLocation
        for (index, overlay) in overlayWindows.enumerated() {
            if NSMouseInRect(screenPoint, overlay.frame, false) {
                select(atIndex: index)
                return
            }
        }
    }

    private func handleKey(event: NSEvent) {
        // Escape → cancel
        if event.keyCode == 53 {
            dismiss(chosen: nil)
            return
        }
        // Map both top-row and numpad key codes to digits 1–9
        let keyCodeToDigit: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,  // top row
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9   // numpad
        ]
        guard let digit = keyCodeToDigit[event.keyCode], digit <= overlayWindows.count else { return }
        select(atIndex: digit - 1)
    }

    private func select(atIndex index: Int) {
        // Map overlay index → SCDisplay via NSScreen order
        let screens = NSScreen.screens
        guard index < screens.count else { dismiss(chosen: nil); return }
        let screen = screens[index]
        guard let chosen = scDisplay(for: screen) else { dismiss(chosen: nil); return }
        dismiss(chosen: chosen)
    }

    private func dismiss(chosen: SCDisplay?) {
        // Remove monitors first to prevent re-entrancy
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }

        for window in overlayWindows { window.close() }
        overlayWindows.removeAll()

        completion(chosen)
    }
}

/// Borderless overlay window that forwards mouse-down to a handler closure.
private final class OverlayWindow: NSWindow {
    var clickHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        clickHandler?()
    }
}

final class SingleInstanceLock {
    private let lockPath: String
    private var fileDescriptor: Int32 = -1

    init(lockPath: String) {
        self.lockPath = lockPath
    }

    deinit {
        release()
    }

    func acquire() -> Bool {
        if fileDescriptor != -1 {
            return true
        }

        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd != -1 else { return false }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd
            return true
        }

        close(fd)
        return false
    }

    func release() {
        guard fileDescriptor != -1 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }
}

@main
struct ScreenRecorderMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

struct SettingsView: View {
    @State private var outputDirectoryPath = AppSettings.outputDirectory.path
    @State private var includeAudio = AppSettings.includeAudio
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Output Folder")
                .fontWeight(.bold)

            HStack(spacing: 10) {
                TextField("", text: $outputDirectoryPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Choose...") {
                    chooseOutputDirectory()
                }
            }

            Text("Recordings are saved as MP4 files in this directory.")
                .foregroundStyle(.secondary)

            Toggle("Include audio from the default audio source", isOn: $includeAudio)
                .toggleStyle(.checkbox)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
        }
        .onChange(of: includeAudio) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: AppSettings.includeAudioKey)
        }
        .onChange(of: launchAtLogin) { _, newValue in
            let service = SMAppService.mainApp
            do {
                if newValue {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                launchAtLogin = service.status == .enabled
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = AppSettings.outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            UserDefaults.standard.set(selectedURL.path, forKey: AppSettings.outputDirectoryPathKey)
            outputDirectoryPath = selectedURL.path
        }
    }
}
