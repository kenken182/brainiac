//
//  AudioRecorder.swift
//  Mindflow — records mic input to a .wav file while hotkey is held.
//

import AVFoundation
import Foundation

enum AudioRecorderError: Error {
    case couldNotStart
    case notRecording
    case permissionDenied
}

@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func start() async throws {
        // Explicitly request mic permission — AVAudioRecorder doesn't always trigger the TCC prompt on macOS.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[AudioRecorder] mic auth status: \(status.rawValue)")
        switch status {
        case .authorized:
            break
        case .notDetermined:
            print("[AudioRecorder] requesting mic access...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("[AudioRecorder] mic access granted: \(granted)")
            if !granted { throw AudioRecorderError.permissionDenied }
        case .denied, .restricted:
            print("[AudioRecorder] mic denied/restricted — enable in System Settings > Privacy & Security > Microphone")
            throw AudioRecorderError.permissionDenied
        @unknown default:
            throw AudioRecorderError.permissionDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindflow-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        r.prepareToRecord()
        guard r.record() else {
            print("[AudioRecorder] AVAudioRecorder.record() returned false")
            throw AudioRecorderError.couldNotStart
        }
        print("[AudioRecorder] recording to \(url.path)")
        self.recorder = r
        self.currentURL = url
    }

    func stop() async throws -> URL {
        guard let r = recorder, let url = currentURL else {
            print("[AudioRecorder] stop() called but no active recorder")
            throw AudioRecorderError.notRecording
        }
        r.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        print("[AudioRecorder] stopped, wrote \(size) bytes")
        self.recorder = nil
        self.currentURL = nil
        return url
    }
}
