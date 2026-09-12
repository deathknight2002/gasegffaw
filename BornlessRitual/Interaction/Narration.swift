//
//  Narration.swift
//  Bornless Ritual — spoken ritual text (ARCHITECTURE §1 "AVFoundation allowed for
//  non-render-path work", §8 narration toggle, §10 the current stage's lines in the
//  selected edition; App/RitualTextProvider.swift for the lookup).
//
//  Role: an `AVSpeechSynthesizer` that speaks a stage's lines (one utterance per line,
//  rate 0.42, pitch 0.85, an English voice) when the feedback monitor reports that a
//  stage started, and stops immediately when the toggle is switched off or the stage
//  changes. Capture runs launch with `-narration 0` (the default), so nothing speaks
//  during critic evidence unless asked.
//
//  Threading: call from the main thread; the synthesizer's delegate callbacks are only
//  used for bookkeeping of the current batch of utterances.
//

import Foundation
import AVFoundation
import RitualCore
import os

/// Speaks ritual stage lines.
final class Narration: NSObject, AVSpeechSynthesizerDelegate {
    /// Speech rate (0 … 1; `AVSpeechUtteranceDefaultSpeechRate` is 0.5).
    static let speechRate: Float = 0.42
    /// Pitch multiplier (0.5 … 2.0).
    static let pitchMultiplier: Float = 0.85
    /// Pause after each line, seconds.
    static let pauseBetweenLines: TimeInterval = 0.25
    /// Voice languages tried in order.
    static let preferredLanguages = ["en-GB", "en-US"]

    /// Ritual text source.
    let text: RitualTextProvider

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterances = Set<AVSpeechUtterance>()
    private var sessionActive = false
    private let log = Logger(subsystem: "BornlessRitual", category: "Narration")

    /// Stage currently being narrated, if any.
    private(set) var currentStage: RitualStage?
    /// Edition of the current narration, if any.
    private(set) var currentEdition: RitualTextEdition?

    /// Creates the narrator over a text provider.
    init(text: RitualTextProvider) {
        self.text = text
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Whether utterances are queued or being spoken.
    var isSpeaking: Bool {
        synthesizer.isSpeaking || !currentUtterances.isEmpty
    }

    // MARK: Speaking

    /// Stops anything in progress and speaks `stage`'s lines in `edition`.
    ///
    /// A stage without lines (or a missing RitualText.json) speaks nothing.
    func speak(stage: RitualStage, edition: RitualTextEdition) {
        stop()
        let lines = text.lines(for: stage, edition: edition)
        guard !lines.isEmpty else { return }
        activateSession()
        currentStage = stage
        currentEdition = edition
        let utterances = Narration.utterances(for: lines, voice: Narration.voice())
        currentUtterances = Set(utterances)
        for utterance in utterances {
            synthesizer.speak(utterance)
        }
    }

    /// Stops speaking immediately and releases the audio session.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterances.removeAll()
        currentStage = nil
        currentEdition = nil
        deactivateSession()
    }

    /// One utterance per line with the narration's rate, pitch and voice.
    static func utterances(for lines: [String], voice: AVSpeechSynthesisVoice?) -> [AVSpeechUtterance] {
        lines.map { line in
            let utterance = AVSpeechUtterance(string: line)
            utterance.rate = speechRate
            utterance.pitchMultiplier = pitchMultiplier
            utterance.postUtteranceDelay = pauseBetweenLines
            utterance.voice = voice
            return utterance
        }
    }

    /// The first available preferred voice, else the device language's voice.
    static func voice() -> AVSpeechSynthesisVoice? {
        for language in preferredLanguages {
            if let voice = AVSpeechSynthesisVoice(language: language) {
                return voice
            }
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: Audio session

    private func activateSession() {
        guard !sessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            log.error("Audio session activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log.debug("Audio session deactivation failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentUtterances.remove(utterance)
        if currentUtterances.isEmpty {
            currentStage = nil
            currentEdition = nil
            deactivateSession()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        currentUtterances.remove(utterance)
    }
}
