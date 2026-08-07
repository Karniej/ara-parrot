import AVFoundation
import Foundation
import Speech

/// One utterance = one streaming recognition task. `requiresOnDeviceRecognition`
/// is non-negotiable — it *is* the privacy label; if on-device recognition is
/// unavailable for the locale, dictation is unavailable, never server-assisted.
///
/// SFSpeech types are non-Sendable and their callbacks arrive on an arbitrary
/// queue; everything is confined here behind `@MainActor`, with the one
/// documented exception: `SFSpeechAudioBufferRecognitionRequest.append` is
/// safe from the audio thread, reached through the `@unchecked Sendable` box.
@MainActor
final class SpeechService {
    private var task: SFSpeechRecognitionTask?
    private var box: RequestBox?

    static var onDeviceAvailable: Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// Starts an utterance. `onPartial` fires on the main actor with rolling
    /// text; `onFinal` fires exactly once — on the recognizer's final result,
    /// on error, or on cancel (with the best text so far).
    func begin(onPartial: @escaping @MainActor (String) -> Void,
               onFinal: @escaping @MainActor (Result<String, Error>) -> Void)
        -> (@Sendable (AVAudioPCMBuffer) -> Void)?
    {
        guard let recognizer = SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition else {
            onFinal(.failure(SpeechError.onDeviceUnavailable))
            return nil
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let box = RequestBox(request)
        self.box = box
        // Reference type because the callback below mutates it from spawned
        // main-actor tasks — captured `var`s can't cross that boundary.
        let utterance = UtteranceState()
        task = recognizer.recognitionTask(with: request) { result, error in
            // Callback queue is the recognizer's; hop before touching state.
            let text = result.map { $0.bestTranscription.formattedString }
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard !utterance.finished else { return }
                if let text {
                    utterance.best = text
                    onPartial(text)
                }
                if isFinal {
                    utterance.finished = true
                    onFinal(.success(utterance.best))
                } else if let error {
                    utterance.finished = true
                    // A stopped stream often "errors" after endAudio with the
                    // final text already delivered; the best text wins over
                    // the error when there is any.
                    if utterance.best.isEmpty {
                        onFinal(.failure(error))
                    } else {
                        onFinal(.success(utterance.best))
                    }
                }
            }
        }
        return { @Sendable buffer in box.request.append(buffer) }
    }

    /// Ends the audio stream; the final result arrives via `onFinal`.
    func endUtterance() {
        box?.request.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        box = nil
    }
}

enum SpeechError: LocalizedError {
    case onDeviceUnavailable

    var errorDescription: String? {
        "on-device recognition unavailable for this language"
    }
}

/// `append` is documented thread-safe; the box exists so a `@Sendable` tap
/// closure can hold the non-Sendable request without Swift 6 objecting.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

@MainActor
private final class UtteranceState {
    var best = ""
    var finished = false
}
