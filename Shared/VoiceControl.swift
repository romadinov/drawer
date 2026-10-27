import AVFoundation
import DrawerCore
import Speech
import SwiftUI

/// Listens for spoken commands ("add a database called orders", "connect shop to orders") and applies them.
/// Stops by itself after a short pause, or when the mic button is pressed again.
@MainActor
@Observable
final class VoiceControl {
    private(set) var isListening = false
    private(set) var transcript = ""
    /// What the last command did (or why nothing happened); cleared after a few seconds.
    private(set) var feedback: String?

    @ObservationIgnored weak var document: DrawerDocument?
    /// Undo, redo, layout and zoom are carried out by the view that owns them.
    @ObservationIgnored var onAppAction: (VoiceCommand) -> Void = { _ in }

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Timer?
    @ObservationIgnored private var feedbackTimer: Timer?

    static let examples = ["add a database called orders", "connect web app to orders labelled reads",
                           "API calls payments", "rename shop to storefront", "make orders a queue", "delete payments", "undo", "auto layout"]

    func toggle() { isListening ? finish() : start() }

    func start() {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.show("Speech recognition is off for Drawer. Turn it on in Settings › Privacy & Security › Speech Recognition.")
                    return
                }
                #if os(macOS)
                self.begin()
                #else
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in granted ? self.begin() : self.show("Microphone access is off for Drawer. Turn it on in Settings › Privacy & Security › Microphone.") }
                }
                #endif
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { show("Speech recognition isn’t available right now."); return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            // Names already in the diagram and element types are much easier to recognise when hinted.
            let names = document?.parsed.nodes.map(\.title) ?? []
            request.contextualStrings = names + NodeKind.allCases.map(\.displayName) + ["connect", "rename", "labelled", "auto layout"]
            Self.installTap(on: engine, feeding: request)
            engine.prepare()
            try engine.start()
            self.request = request
            task = Self.recognitionTask(recognizer, request) { [weak self] text, isFinal, failed in
                guard let self, self.isListening else { return }
                if let text { self.transcript = text; self.restartSilenceTimer() }
                if isFinal || failed { self.finish() }
            }
            transcript = ""
            feedback = nil
            isListening = true
        } catch {
            stopAudio()
            show("Couldn’t start listening: \(error.localizedDescription)")
        }
    }

    // Audio and recognition callbacks arrive on background queues; keep those closures out of the main actor.
    nonisolated private static func installTap(on engine: AVAudioEngine, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognitionTask(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                                    update: @escaping @MainActor (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in update(text, isFinal, failed) }
        }
    }

    private func restartSilenceTimer() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// Stops listening and carries out whatever was said.
    func finish() {
        guard isListening else { return }
        isListening = false
        silence?.invalidate()
        stopAudio()
        execute(transcript)
    }

    private func stopAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func execute(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { show("Didn’t hear anything. Try “\(Self.examples.randomElement()!)”."); return }
        guard let doc = document else { return }
        let commands = VoiceCommand.parse(text, knownNames: doc.parsed.nodes.map(\.title))
        guard !commands.isEmpty else { show("“\(text)” — try “\(Self.examples.randomElement()!)”."); return }
        var outcome = VoiceCommand.Outcome()
        doc.change("Voice Command") { state, _ in outcome = VoiceCommand.apply(commands, to: &state, measure: appMeasurer) }
        if !outcome.touched.isEmpty {
            doc.selection = Set(outcome.touched)
            doc.selectionOrigin = .canvas
        }
        outcome.appActions.forEach(onAppAction)
        let done = outcome.messages + outcome.appActions.map {
            switch $0 { case .undo: "Undone"; case .redo: "Redone"; case .autoLayout: "Arranged"; default: "" }
        }.filter { !$0.isEmpty }
        show(done.joined(separator: "\n"))
    }

    private func show(_ message: String) {
        feedback = message.isEmpty ? nil : message
        feedbackTimer?.invalidate()
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedback = nil }
        }
    }
}

/// The live transcript while listening, then what happened.
struct VoiceOverlay: View {
    let voice: VoiceControl

    var body: some View {
        Group {
            if voice.isListening {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(.red)
                    Text(voice.transcript.isEmpty ? "Listening… e.g. “\(VoiceControl.examples[0])”" : voice.transcript)
                        .lineLimit(2)
                        .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                    Button("Done") { voice.finish() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else if let feedback = voice.feedback {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").foregroundStyle(.tint)
                    Text(feedback).lineLimit(4)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 560)
        .opacity(voice.isListening || voice.feedback != nil ? 1 : 0)
        .animation(.snappy, value: voice.isListening)
        .animation(.snappy, value: voice.feedback)
        .padding(.top, 12)
    }
}
