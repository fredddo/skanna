import AVFoundation
import Foundation
import Speech

/// Håll mellanslag i chattrutan = prata in texten (svensk taligenkänning, på enheten när Macen klarar det).
/// Texten kommer löpande medan man pratar; släpp mellanslag så avslutas inspelningen.
final class Diktering: ObservableObject {
    @Published private(set) var lyssnar = false
    @Published var fel: String?

    private let motor = AVAudioEngine()
    private var begaran: SFSpeechAudioBufferRecognitionRequest?
    private var uppgift: SFSpeechRecognitionTask?
    private let igenkannare = SFSpeechRecognizer(locale: Locale(identifier: "sv-SE")) ?? SFSpeechRecognizer()
    private var slutat = false

    /// Startar inspelningen. `text` anropas med hela den hittills tolkade texten (på huvudtråden).
    func starta(text: @escaping (String) -> Void) {
        guard !lyssnar else { return }
        fel = nil
        slutat = false
        lyssnar = true
        if ProcessInfo.processInfo.environment["SKANNA_INGEN_MIK"] != nil { print("diktering: startar (ingen mik i test)"); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.avbryt("Taligenkänning är inte tillåten – slå på den för \(Hem.appNamn) i Systeminställningar → Integritet och säkerhet → Taligenkänning.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.avbryt("Mikrofonen är inte tillåten – slå på den för \(Hem.appNamn) i Systeminställningar → Integritet och säkerhet → Mikrofon.")
                            return
                        }
                        guard !self.slutat else { self.lyssnar = false; return }   // mellanslag släpptes medan dialogen visades
                        self.spelaIn(text: text)
                    }
                }
            }
        }
    }

    private func spelaIn(text: @escaping (String) -> Void) {
        guard let ig = igenkannare, ig.isAvailable else { avbryt("Taligenkänningen är inte tillgänglig just nu."); return }
        let b = SFSpeechAudioBufferRecognitionRequest()
        b.shouldReportPartialResults = true
        if ig.supportsOnDeviceRecognition { b.requiresOnDeviceRecognition = true }   // stannar på Macen när det går
        b.addsPunctuation = true
        begaran = b
        let ingang = motor.inputNode
        let format = ingang.outputFormat(forBus: 0)
        ingang.removeTap(onBus: 0)
        ingang.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in b.append(buf) }
        motor.prepare()
        do { try motor.start() } catch { avbryt("Kunde inte starta mikrofonen: \(error.localizedDescription)"); return }
        uppgift = ig.recognitionTask(with: b) { [weak self] res, err in
            DispatchQueue.main.async {
                if let res { text(res.bestTranscription.formattedString) }
                if err != nil || res?.isFinal == true { self?.stang() }
            }
        }
    }

    /// Mellanslag släppt: sluta lyssna, den sista tolkningen kommer strax efter.
    func stoppa() {
        slutat = true
        guard motor.isRunning else { if uppgift == nil { lyssnar = false }; return }
        motor.stop()
        motor.inputNode.removeTap(onBus: 0)
        begaran?.endAudio()
        lyssnar = false
    }

    private func stang() {
        if motor.isRunning { motor.stop(); motor.inputNode.removeTap(onBus: 0) }
        begaran = nil
        uppgift = nil
        lyssnar = false
    }

    private func avbryt(_ t: String) {
        fel = t
        uppgift?.cancel()
        stang()
    }
}
