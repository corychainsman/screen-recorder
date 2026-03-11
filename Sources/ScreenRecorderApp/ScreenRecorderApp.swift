import AppKit
import Combine
import Darwin
import Foundation
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lock = SingleInstanceLock(lockPath: "/tmp/screen-recorder-menubar.lock")
        guard lock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        singleInstanceLock = lock

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
        isToggling = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isToggling = false }

            if self.recorder.isRecording {
                if let outputURL = await self.recorder.stopRecording() {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } else {
                await self.recorder.startRecording()
            }
        }
    }

    @objc
    private func openSettings() {
        let view = SettingsView()
        let host = NSHostingController(rootView: view)

        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 220))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Output Folder")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("", text: $outputDirectoryPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Choose...") {
                    chooseOutputDirectory()
                }
            }

            Text("Recordings are saved as MP4 files in this directory.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Include audio from the default audio source", isOn: $includeAudio)
                .toggleStyle(.switch)
        }
        .onChange(of: includeAudio) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: AppSettings.includeAudioKey)
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
