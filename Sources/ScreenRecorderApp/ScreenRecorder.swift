import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

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

    func startRecording() async {
        guard !isRecording else { return }

        do {
            let outputURL = Self.makeOutputURL(in: AppSettings.outputDirectory)
            self.outputURL = outputURL
            self.lastOutputPath = nil
            self.statusMessage = "Starting..."

            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw RecorderError.noDisplayFound
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 6
            configuration.showsCursor = true
            configuration.capturesAudio = AppSettings.includeAudio
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.presenterOverlayPrivacyAlertSetting = .never
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
            try await stream?.stopCapture()
            if let savedURL = outputURL {
                lastOutputPath = savedURL.path
                statusMessage = "Saved to \(outputDirectory)"
            } else {
                statusMessage = "Recording stopped"
            }
        } catch {
            statusMessage = "Failed to stop cleanly: \(error.localizedDescription)"
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
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let outputURL {
                self.lastOutputPath = outputURL.path
                self.statusMessage = "Saved to \(outputURL.deletingLastPathComponent().path)"
            }
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
