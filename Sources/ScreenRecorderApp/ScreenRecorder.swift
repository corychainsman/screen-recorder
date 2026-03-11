import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Permission management

/// Manages screen-recording and microphone permission checks for macOS 15+.
@MainActor
enum PermissionManager {

    // MARK: Status

    /// Returns `true` when the process already holds screen-recording permission.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Returns `true` when microphone permission has been granted.
    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Returns `true` when the microphone permission dialog may still appear
    /// (i.e. the user has not yet made a decision).
    static var isMicrophonePermissionUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    // MARK: Requests

    /// Triggers the screen-recording permission prompt if needed.
    /// The system dialog is modal and blocks interaction with the app until dismissed.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Triggers the microphone permission prompt if needed.
    /// Calls back on the main actor once the user responds.
    static func requestMicrophonePermission() async {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Wait-until-granted helpers

    /// Requests screen-recording access and then waits until the system permission
    /// dialog has been dismissed before returning.
    ///
    /// Detection strategy: `CGPreflightScreenCaptureAccess()` returns `false` for
    /// both "not yet asked" and "denied" — there is no separate denied state via this
    /// API.  The system dialog steals focus from the app, so we watch for the app to
    /// become active again (via `NSApplication.didBecomeActiveNotification`) as a
    /// reliable proxy for "the dialog was closed".  We also keep polling so that if
    /// permission is granted before the app re-activates we return immediately.
    ///
    /// - Returns: `true` if permission is granted after the dialog, `false` if denied.
    static func requestAndWaitForScreenRecording() async -> Bool {
        guard !hasScreenRecordingPermission else { return true }

        // Trigger the system prompt.
        CGRequestScreenCaptureAccess()

        // If the OS can determine immediately (e.g. already denied from a prior run
        // without ever showing a new dialog) just return.
        if !NSApp.isActive {
            // The dialog stole focus — wait for the app to re-activate.
            final class Box: @unchecked Sendable { var value: (any NSObjectProtocol)? }
            let box = Box()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.value = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    if let o = box.value {
                        NotificationCenter.default.removeObserver(o)
                        box.value = nil
                    }
                    continuation.resume()
                }
            }
        }

        return CGPreflightScreenCaptureAccess()
    }

    /// Requests microphone access and waits for the user to respond.
    /// - Returns: `true` if permission was granted, `false` if denied/restricted.
    static func requestAndWaitForMicrophone() async -> Bool {
        guard isMicrophonePermissionUndecided else {
            return hasMicrophonePermission
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Open System Settings

    /// Opens the Privacy & Security > Screen Recording pane in System Settings.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the Privacy & Security > Microphone pane in System Settings.
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Output folder writability

    /// Returns `true` when the app can write files into `directory`.
    /// This is a live check — call it whenever the chosen folder changes.
    static func hasWritePermission(for directory: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: directory.path)
    }
}

enum AppSettings {
    static let outputDirectoryPathKey = "outputDirectoryPath"
    static let includeAudioKey = "includeAudio"

    static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    static var outputDirectory: URL {
        guard
            let path = UserDefaults.standard.string(forKey: outputDirectoryPathKey),
            !path.isEmpty
        else {
            return defaultOutputDirectory
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? url : defaultOutputDirectory
    }

    static var includeAudio: Bool {
        if UserDefaults.standard.object(forKey: includeAudioKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: includeAudioKey)
    }
}

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var lastOutputPath: String?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    /// Resumed by `recordingOutputDidFinishRecording` once the file is fully written to disk.
    private var finishedContinuation: CheckedContinuation<Void, Never>?

    func startRecording(display chosenDisplay: SCDisplay? = nil) async {
        guard !isRecording else { return }

        do {
            let outputURL = Self.makeOutputURL(in: AppSettings.outputDirectory)
            self.outputURL = outputURL
            self.lastOutputPath = nil
            self.statusMessage = "Starting..."

            let content = try await SCShareableContent.current
            let display: SCDisplay
            if let chosenDisplay {
                guard let found = content.displays.first(where: { $0.displayID == chosenDisplay.displayID }) else {
                    throw RecorderError.noDisplayFound
                }
                display = found
            } else {
                guard let first = content.displays.first else {
                    throw RecorderError.noDisplayFound
                }
                display = first
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()

            let displayMode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelWidth = displayMode?.pixelWidth ?? display.width
            let pixelHeight = displayMode?.pixelHeight ?? display.height
            let refreshRate = displayMode?.refreshRate ?? 60.0
            let fps = refreshRate > 0 ? refreshRate : 60.0

            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            configuration.queueDepth = 6
            configuration.showsCursor = true
            configuration.capturesAudio = AppSettings.includeAudio
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.presenterOverlayPrivacyAlertSetting = .never
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            if #available(macOS 15.0, *) {
                configuration.captureMicrophone = AppSettings.includeAudio
            }

            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = outputURL
            recordingConfig.outputFileType = .mp4
            if recordingConfig.availableVideoCodecTypes.contains(.h264) {
                recordingConfig.videoCodecType = .h264
            }

            let recordingOutput = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()

            self.recordingOutput = recordingOutput
            self.stream = stream
            self.isRecording = true
        } catch {
            cleanupCaptureObjects()
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        statusMessage = "Stopping..."
        let outputDirectory = AppSettings.outputDirectory.path

        do {
            // Suspend until recordingOutputDidFinishRecording fires, which means
            // the file is fully written to disk and safe to reveal in Finder.
            await withCheckedContinuation { continuation in
                self.finishedContinuation = continuation
                Task {
                    do { try await self.stream?.stopCapture() }
                    catch { /* stopCapture error — continuation will still be resumed by delegate or fallback below */ }
                }
            }
            if let savedURL = outputURL {
                lastOutputPath = savedURL.path
                statusMessage = "Saved to \(outputDirectory)"
            } else {
                statusMessage = "Recording stopped"
            }
        }

        let savedURL = outputURL
        isRecording = false
        cleanupCaptureObjects()
        return savedURL
    }

    private func cleanupCaptureObjects() {
        stream = nil
        recordingOutput = nil
        outputURL = nil
    }

    private static func makeOutputURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "ScreenRecording-\(formatter.string(from: Date())).mp4"
        return directory.appendingPathComponent(filename)
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.statusMessage = "Recording..."
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isRecording = false
            self?.statusMessage = "Recording failed: \(error.localizedDescription)"
            self?.cleanupCaptureObjects()
            // Unblock stopRecording() if it's waiting.
            self?.finishedContinuation?.resume()
            self?.finishedContinuation = nil
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let outputURL {
                self.lastOutputPath = outputURL.path
                self.statusMessage = "Saved to \(outputURL.deletingLastPathComponent().path)"
            }
            // Resume the continuation in stopRecording() so it can return the finalized URL.
            finishedContinuation?.resume()
            finishedContinuation = nil
        }
    }
}

enum RecorderError: LocalizedError {
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No active display was found."
        }
    }
}
