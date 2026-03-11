import AppKit
import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Delegate (race-free via actor)

actor SignalBox {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result {
            try result.get()
            return
        }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    nonisolated func signal() {
        Task { await self._signal(.success(())) }
    }

    nonisolated func fail(_ error: Error) {
        Task { await self._signal(.failure(error)) }
    }

    private func _signal(_ r: Result<Void, Error>) {
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let started = SignalBox()
    let finished = SignalBox()

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        started.signal()
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished.signal()
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        started.fail(error)
        finished.fail(error)
    }
}

// MARK: - Recorder

@MainActor
final class AudioTestRecorder: NSObject {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let outputURL: URL
    private let delegate = RecordingDelegate()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func record(durationSeconds: Double) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw TestError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.presenterOverlayPrivacyAlertSetting = .never
        config.captureMicrophone = true

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = outputURL
        recConfig.outputFileType = .mp4
        if recConfig.availableVideoCodecTypes.contains(.h264) {
            recConfig.videoCodecType = .h264
        }

        let recordingOutput = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()
        self.stream = stream
        self.recordingOutput = recordingOutput

        // Wait for recording to actually start (race-free: signal may arrive before or after)
        try await delegate.started.wait()
        print("[TEST] Recording started, capturing \(durationSeconds)s...")

        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))

        try await stream.stopCapture()
        // Wait for SCRecordingOutput to finish flushing to disk
        try await delegate.finished.wait()
    }
}

enum TestError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "No display found" }
}

// MARK: - Verification

struct VerificationResult {
    let passed: Bool
    let audioTrackCount: Int
    let duration: Double
    let sampleRate: Double?
    let channelCount: Int?
    let failureReason: String?
}

func verifyAudio(at url: URL) async -> VerificationResult {
    let asset = AVURLAsset(url: url)
    do {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            return VerificationResult(passed: false, audioTrackCount: 0, duration: 0,
                                      sampleRate: nil, channelCount: nil,
                                      failureReason: "No audio tracks in output file")
        }
        let track = tracks[0]
        let timeRange = try await track.load(.timeRange)
        let formatDescs = try await track.load(.formatDescriptions)

        var sampleRate: Double?
        var channelCount: Int?
        if let desc = formatDescs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            sampleRate = Double(asbd.mSampleRate)
            channelCount = Int(asbd.mChannelsPerFrame)
        }

        let durationSecs = timeRange.duration.seconds
        let passed = durationSecs > 0
        return VerificationResult(
            passed: passed,
            audioTrackCount: tracks.count,
            duration: durationSecs,
            sampleRate: sampleRate,
            channelCount: channelCount,
            failureReason: passed ? nil : "Audio track present but has zero duration"
        )
    } catch {
        return VerificationResult(passed: false, audioTrackCount: 0, duration: 0,
                                  sampleRate: nil, channelCount: nil,
                                  failureReason: "AVFoundation error: \(error)")
    }
}

// MARK: - Test runner

@MainActor
func runTest() async -> Int32 {
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-test-\(Int(Date().timeIntervalSince1970)).mp4")

    print("[TEST] Output: \(tmpURL.path)")
    print("[TEST] capturesAudio=true, sampleRate=48000, channelCount=2")
    print("[TEST] Starting 7-second recording...")

    let recorder = AudioTestRecorder(outputURL: tmpURL)
    do {
        try await recorder.record(durationSeconds: 7)
    } catch {
        print("[FAIL] Recording error: \(error.localizedDescription)")
        return 1
    }

    guard FileManager.default.fileExists(atPath: tmpURL.path) else {
        print("[FAIL] Output file not created")
        return 1
    }

    let attrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path)
    let fileSize = attrs?[.size] as? Int ?? 0
    print("[TEST] File size: \(fileSize) bytes")

    let result = await verifyAudio(at: tmpURL)

    print("")
    print("--- DIAGNOSTICS ---")
    print("Audio tracks : \(result.audioTrackCount)")
    print("Duration     : \(String(format: "%.3f", result.duration))s")
    if let sr = result.sampleRate   { print("Sample rate  : \(Int(sr)) Hz") }
    if let ch = result.channelCount { print("Channels     : \(ch)") }
    print("-------------------")
    print("")

    if result.passed {
        print("[PASS] Audio track verified with non-zero duration")
        try? FileManager.default.removeItem(at: tmpURL)
        return 0
    } else {
        print("[FAIL] \(result.failureReason ?? "Unknown failure")")
        print("[INFO] File retained at: \(tmpURL.path)")
        return 1
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    let code = await runTest()
    exit(code)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
