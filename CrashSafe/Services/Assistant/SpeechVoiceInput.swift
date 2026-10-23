import AVFoundation
import Foundation
import os
import Speech

/// The microphone, transcribed with Apple's speech recognizer: on the phone when it can (private, works
/// offline), otherwise Apple's server. What it hears goes to Pulse; nothing is recorded or kept.
@MainActor
final class SpeechVoiceInput: VoiceInputService {
    enum Failure: LocalizedError {
        case notAllowed, unavailable, heardNothing
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Microphone or speech recognition is off for CrashSafe in Settings."
            case .unavailable: "Speech recognition isn't available right now."
            case .heardNothing: "I didn't catch that."
            }
        }
    }

    private static let log = Logger(subsystem: "org.cac.crashsafe", category: "voice")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalText: String?
    private var lastChange = Date.distantPast
    private(set) var partial = ""
    private(set) var isRecording = false

    // MARK: VoiceInputService

    /// One question: listens until the speaker pauses (1.4 s), up to 15 s.
    func listen() async throws -> String {
        try await start()
        let began = Date.now
        while isRecording {
            try? await Task.sleep(for: .milliseconds(150))
            let quiet = Date.now.timeIntervalSince(lastChange)
            if !partial.isEmpty && quiet > 1.4 { break }
            if partial.isEmpty && Date.now.timeIntervalSince(began) > 7 { break }
            if Date.now.timeIntervalSince(began) > 15 { break }
        }
        return try await finish()
    }

    func start() async throws {
        cancel()
        guard await Self.authorize() else { throw Failure.notAllowed }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        partial = ""
        finalText = nil
        lastChange = .now

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: Self.tap(feeding: UncheckedRequest(request)))
        engine.prepare()
        try engine.start()
        isRecording = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, isFinal in
            guard let self else { return }
            if let text, text != self.partial {
                self.partial = text
                self.lastChange = .now
            }
            if isFinal { self.finalText = self.partial }
        })
    }

    /// Stops listening and returns what was said.
    func finish() async throws -> String {
        guard isRecording || request != nil else { throw Failure.heardNothing }
        stopAudio()
        request?.endAudio()
        // The final transcript follows endAudio shortly; don't wait long for it.
        for _ in 0..<12 where finalText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let text = (finalText ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        task = nil
        request = nil
        Self.log.info("heard \(text.split(separator: " ").count, privacy: .public) words")
        guard !text.isEmpty else { throw Failure.heardNothing }
        return text
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopAudio() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Callbacks built off the main actor
    //
    // The audio tap and the recognizer call back on their own threads. Closures created inside this
    // main-actor class would inherit main-actor isolation and trap there (the same Swift 6 crash Core
    // Motion caused), so they are built in nonisolated functions and hop to the main actor explicitly.

    nonisolated private struct UncheckedRequest: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    nonisolated private static func tap(feeding box: UncheckedRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in box.request.append(buffer) }
    }

    nonisolated private static func results(_ deliver: @escaping @MainActor (String?, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in deliver(text, isFinal) }
        }
    }

    /// Permission callbacks arrive on a background queue: this runs off the main actor on purpose.
    @concurrent nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
