import Foundation
import AVFoundation
import WatchKit

enum Haptics {
    @MainActor
    static func play(_ type: WKHapticType, _ settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }
}

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()
    private let synth = AVSpeechSynthesizer()
    @Published private(set) var speakingID: UUID?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String, id: UUID? = nil) {
        stop()
        let plain = Self.plainText(text)
        guard !plain.isEmpty else { return }
        let u = AVSpeechUtterance(string: plain)
        let hasCJK = plain.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        u.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speakingID = id
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }

    static func plainText(_ md: String) -> String {
        var s = md
        // 去掉代码块
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: "（代码已省略）", options: .regularExpression)
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[#*`>|_~]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "-{3,}", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
