/// TestUIApp — automated test harness for two UI behaviours:
///
///   Test 1 — Keyboard selection during overlay:
///     • Creates a borderless overlay window using the same setup as ScreenSelectionManager
///       (orderFrontRegardless + makeKeyAndOrderFront + NSApp.activate)
///     • Installs a local keyDown monitor
///     • Uses osascript to send synthetic key presses (top-row "1" and numpad "1")
///     • PASS if both key events are received by the local monitor
///
///   Test 2 — Finder reveal after a delayed file:
///     • Creates a real file on the Desktop
///     • Calls NSWorkspace.activateFileViewerSelecting(_:)
///     • Checks via AppleScript that Finder has the file selected and is frontmost
///     • PASS if file is selected and Finder is frontmost

import AppKit
import Foundation

// MARK: - KeyableWindow

/// Borderless window that can become key — mirrors OverlayWindow in ScreenSelectionManager.
@MainActor
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Helpers

@MainActor
func runAppleScript(_ source: String) -> String? {
    let script = NSAppleScript(source: source)
    var err: NSDictionary?
    let result = script?.executeAndReturnError(&err)
    if let e = err { print("  AppleScript error: \(e)") }
    return result?.stringValue
}

func sendKey(keyCode: Int) {
    let script = "tell application \"System Events\" to key code \(keyCode)"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
    task.waitUntilExit()
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // ---- Test 1 state ----
    var overlayWindow: KeyableWindow?
    var localMonitor: Any?
    var topRowReceived = false
    var numpadReceived = false

    // ---- Results ----
    var test1Passed = false
    var test2Passed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Test 1: Keyboard selection during overlay ===")
        runTest1()
    }

    // MARK: Test 1 — overlay keyboard events

    func runTest1() {
        let screen = NSScreen.screens[0]
        let frame = screen.frame

        // Replicate exactly what ScreenSelectionManager.present() does after the fix:
        //   orderFrontRegardless + NSApp.activate + makeKeyAndOrderFront
        let win = KeyableWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor = NSColor(white: 0, alpha: 0.55)
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false

        overlayWindow = win

        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Local keyDown monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return nil }
            let code = event.keyCode
            print("  Received keyDown: keyCode=\(code) chars='\(event.characters ?? "")'")
            if code == 18 { self.topRowReceived = true }   // top-row "1"
            if code == 83 { self.numpadReceived = true }   // numpad "1"
            return nil
        }

        // After run loop settles, check key status then fire synthetic keys
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            print("  isKeyWindow after activation: \(self.overlayWindow?.isKeyWindow ?? false)")
            print("  Sending top-row '1' (keyCode 18)...")
            DispatchQueue.global().async { sendKey(keyCode: 18) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            print("  Sending numpad '1' (keyCode 83)...")
            DispatchQueue.global().async { sendKey(keyCode: 83) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.finishTest1()
        }
    }

    func finishTest1() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        overlayWindow?.close()
        overlayWindow = nil

        test1Passed = topRowReceived && numpadReceived
        print("  top-row '1' received: \(topRowReceived)")
        print("  numpad  '1' received: \(numpadReceived)")
        print(test1Passed ? "PASS: Test 1 keyboard overlay" : "FAIL: Test 1 keyboard overlay")
        print("")

        print("=== Test 2: Finder reveal with file ===")
        runTest2()
    }

    // MARK: Test 2 — Finder reveal

    func runTest2() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let testFile = desktop.appendingPathComponent("screen_recorder_test_\(Int(Date().timeIntervalSince1970)).txt")
        try! "screen recorder test file".write(to: testFile, atomically: true, encoding: .utf8)
        print("  Created test file: \(testFile.lastPathComponent)")
        print("  Calling NSWorkspace.activateFileViewerSelecting...")
        NSWorkspace.shared.activateFileViewerSelecting([testFile])

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finishTest2(testFile: testFile)
        }
    }

    func finishTest2(testFile: URL) {
        let selectedName = runAppleScript("""
            tell application "Finder"
                set sel to selection
                if (count of sel) > 0 then
                    return name of item 1 of sel
                else
                    return ""
                end if
            end tell
        """) ?? ""

        let frontApp = runAppleScript(
            "tell application \"System Events\" to get name of first process whose frontmost is true"
        ) ?? ""

        let fileSelected = selectedName == testFile.lastPathComponent
        let finderFront = frontApp == "Finder"
        test2Passed = fileSelected && finderFront

        print("  Expected file: \(testFile.lastPathComponent)")
        print("  Finder selection: '\(selectedName)' — \(fileSelected ? "OK" : "WRONG")")
        print("  Frontmost app:    '\(frontApp)' — \(finderFront ? "OK" : "WRONG")")
        print(test2Passed ? "PASS: Test 2 Finder reveal" : "FAIL: Test 2 Finder reveal")
        print("")

        try? FileManager.default.removeItem(at: testFile)

        print("=== Results ===")
        print("Test 1 (keyboard overlay): \(test1Passed ? "PASS" : "FAIL")")
        print("Test 2 (Finder reveal):    \(test2Passed ? "PASS" : "FAIL")")

        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
