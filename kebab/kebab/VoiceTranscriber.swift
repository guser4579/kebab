//
//  VoiceTranscriber.swift
//  kebab
//

import Foundation
import Combine
import AVFoundation
import Speech

/// Streams live speech-to-text into the composer. One instance per composer.
///
/// Uses SFSpeechRecognizer with partial results so words appear as they're
/// spoken; on-device recognition is required whenever the current locale
/// supports it (no audio leaves the phone), falling back to Apple's speech
/// service otherwise. The transcript is delivered through `onTranscript` as
/// the full running text of the current dictation session — the composer
/// decides how to merge it with any text already typed.
@MainActor
final class VoiceTranscriber: ObservableObject {

    @Published private(set) var isRecording = false
    /// Set when the user has denied microphone or speech permission; the
    /// composer surfaces an alert pointing to Settings.
    @Published var permissionDenied = false
    /// Set when dictation can't start for a non-permission reason (recognizer
    /// unavailable, audio engine failure). Never fail silently — the composer
    /// shows a brief alert.
    @Published var startFailed = false

    /// Full transcript of the current session, called on every partial result.
    var onTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Toggle

    func start() async {
        guard !isRecording else { return }

        guard await requestPermissions() else {
            permissionDenied = true
            return
        }

        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            startFailed = true
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.onTranscript?(result.bestTranscription.formattedString)
                    }
                    if error != nil || result?.isFinal == true {
                        self.teardown()
                    }
                }
            }
        } catch {
            print("Voice transcription failed to start:", error)
            startFailed = true
            teardown()
        }
    }

    func stop() {
        guard isRecording else { return }
        // endAudio lets the recognizer finalize; teardown runs on the final
        // result (or immediately below if the task already ended).
        recognitionRequest?.endAudio()
        teardown()
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { return false }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return speechStatus == .authorized
    }
}
