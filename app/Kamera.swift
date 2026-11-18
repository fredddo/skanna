// Kameran för guidad skanning: iPhonen som Continuity Camera (trådlöst eller med sladd) – eller valfri kamera.
// Stillbilder tas med AVCapturePhotoOutput i högsta upplösning formatet medger, och sparas direkt i projektets bilder/.
// Inget startas förrän användaren trycker "Anslut kamera" (då frågar macOS om kameratillstånd första gången).
import AppKit
import AVFoundation
import CoreImage
import SwiftUI

final class Kamera: NSObject, ObservableObject {
    enum Status: Equatable { case av, behorighetNekad, soker, redo, fotar, fel(String) }

    @Published var status: Status = .av
    @Published var enheter: [AVCaptureDevice] = []
    @Published var valdId: String?
    @Published var upplosning = ""
    @Published var lasta = false
    @Published var rorelse: Double = 0          // skillnad mellan förhandsbilder (för autofoto)
    @Published var senaste: (URL, Bildkvalitet)?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "kamera.session")
    private let videoQueue = DispatchQueue(label: "kamera.video")
    private var input: AVCaptureDeviceInput?
    private var pending: [Int64: (URL, (Result<(URL, Bildkvalitet), Error>) -> Void)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var lastThumb: [UInt8] = []

    var enhet: AVCaptureDevice? { enheter.first { $0.uniqueID == valdId } }
    var arIphone: Bool { enhet?.isContinuityCamera ?? false }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.status != .av else { return }
            self.uppdateraEnheter()
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.status != .av else { return }
            if let d = n.object as? AVCaptureDevice, d.uniqueID == self.valdId { self.status = .fel("Kameran kopplades bort (\(d.localizedName))") }
            self.uppdateraEnheter()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Första steget – kan visa macOS dialog om kameratillstånd.
    func anslut() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: starta()
        case .notDetermined:
            status = .soker
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { ok ? self.starta() : (self.status = .behorighetNekad) } }
        default: status = .behorighetNekad
        }
    }

    func stang() {
        sessionQueue.async { self.session.stopRunning() }
        status = .av
    }

    func uppdateraEnheter() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.insert(.continuityCamera, at: 0) }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        enheter = found.sorted { ($0.isContinuityCamera ? 0 : 1, $0.localizedName) < ($1.isContinuityCamera ? 0 : 1, $1.localizedName) }
        if valdId == nil || !enheter.contains(where: { $0.uniqueID == valdId }) { valdId = enheter.first?.uniqueID }
    }

    private func starta() {
        status = .soker
        uppdateraEnheter()
        guard let d = enhet else {
            status = .fel("Ingen kamera hittad. iPhone: lås den, sätt den på stativet nära Macen (samma Apple-konto, wifi och Bluetooth på) – eller koppla in den med sladd.")
            return
        }
        valj(d.uniqueID)
    }

    /// Byt kamera och konfigurera för högsta stillbildsupplösning.
    func valj(_ id: String) {
        valdId = id
        guard let d = enhet else { return }
        status = .soker
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if AVCaptureDevice.centerStageControlMode != .app { AVCaptureDevice.centerStageControlMode = .app }
                AVCaptureDevice.isCenterStageEnabled = false      // Center Stage beskär och flyttar bilden – förstör fotogrammetrin
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let old = self.input { self.session.removeInput(old) }
                let inp = try AVCaptureDeviceInput(device: d)
                guard self.session.canAddInput(inp) else { throw NSError(domain: "Skanna", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kameran kan inte användas"]) }
                self.session.addInput(inp)
                self.input = inp
                if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                if !self.session.outputs.contains(self.videoOutput), self.session.canAddOutput(self.videoOutput) {
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                    self.session.addOutput(self.videoOutput)
                }
                // välj formatet med störst stillbild
                try d.lockForConfiguration()
                let best = d.formats.max { a, b in Kamera.maxPixels(a) < Kamera.maxPixels(b) }
                if let best, Kamera.maxPixels(best) > Kamera.maxPixels(d.activeFormat) { d.activeFormat = best }
                d.unlockForConfiguration()
                if let dims = d.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                    self.photoOutput.maxPhotoDimensions = dims
                }
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                let dims = self.photoOutput.maxPhotoDimensions
                DispatchQueue.main.async {
                    self.upplosning = "\(dims.width) × \(dims.height)" + String(format: " (%.1f MP)", Double(dims.width) * Double(dims.height) / 1e6)
                    self.status = .redo
                    self.lasta = false
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = .fel("Kunde inte starta kameran: \(error.localizedDescription)") }
            }
        }
    }

    static func maxPixels(_ f: AVCaptureDevice.Format) -> Int {
        f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
    }

    /// Lås fokus, exponering och vitbalans (om kameran tillåter det) så att alla bilder blir lika.
    func lasInstallningar(_ on: Bool) {
        guard let d = enhet else { return }
        sessionQueue.async {
            var did = false
            do {
                try d.lockForConfiguration()
                if on {
                    if d.isFocusModeSupported(.locked) { d.focusMode = .locked; did = true }
                    if d.isExposureModeSupported(.locked) { d.exposureMode = .locked; did = true }
                    if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked; did = true }
                } else {
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                }
                d.unlockForConfiguration()
            } catch {}
            DispatchQueue.main.async { self.lasta = on && did }
        }
    }

    var kanLasa: Bool {
        guard let d = enhet else { return false }
        return d.isFocusModeSupported(.locked) || d.isExposureModeSupported(.locked)
    }

    /// Ta en stillbild och spara den (HEIC om möjligt) i url (utan ändelse – ändelsen väljs efter format).
    func fota(till base: URL, klar: @escaping (Result<(URL, Bildkvalitet), Error>) -> Void) {
        guard status == .redo else { klar(.failure(NSError(domain: "Skanna", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kameran är inte redo"]))); return }
        status = .fotar
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let heic = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            let settings = heic ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) : AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            let url = base.appendingPathExtension(heic ? "heic" : "jpg")
            DispatchQueue.main.async { self.pending[settings.uniqueID] = (url, klar) }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension Kamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        let cg = photo.cgImageRepresentation()
        DispatchQueue.main.async {
            guard let (url, klar) = self.pending.removeValue(forKey: id) else { return }
            self.status = .redo
            if let error { klar(.failure(error)); return }
            guard let data else { klar(.failure(NSError(domain: "Skanna", code: 3, userInfo: [NSLocalizedDescriptionKey: "Tom bild från kameran"]))); return }
            do {
                try data.write(to: url, options: .atomic)
                let q = cg.map { Kvalitet.analysera($0) } ?? Kvalitet.analysera(url: url)
                    ?? Bildkvalitet(skarpa: 0, ljus: 0, overexp: 0, underexp: 0, reflexer: 0, bredd: 0, hojd: 0)
                self.senaste = (url, q)
                klar(.success((url, q)))
            } catch { klar(.failure(error)) }
        }
    }
}

extension Kamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Liten gråskalebild (32×24) per förhandsbild → hur mycket bilden rör sig (för "fota när skivan står still").
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var thumb = [UInt8](repeating: 0, count: 32 * 24)
        for ty in 0..<24 {
            for tx in 0..<32 {
                let x = tx * w / 32 + w / 64, y = ty * h / 24 + h / 48
                let o = y * bpr + x * 4
                thumb[ty * 32 + tx] = UInt8((Int(p[o]) + 2 * Int(p[o + 1]) + Int(p[o + 2])) / 4)
            }
        }
        let diff = Rorelse.skillnad(lastThumb, thumb)
        lastThumb = thumb
        DispatchQueue.main.async { self.rorelse = diff }
    }
}

/// Rörelsedetektering för autofoto: vänta på att bilden rört sig (skivan vreds) och sedan stått still en stund.
enum Rorelse {
    static func skillnad(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count) / 255
    }

    /// Tillståndsmaskin: matas med rörelsevärden (≈30/s). Returnerar true exakt en gång när det är dags att fota.
    struct Vakt {
        var rorlig = 0.02       // över detta = något rör sig
        var stilla = 0.006      // under detta = stilla
        var stillaTid = 0.8     // sekunder stillhet efter rörelse
        private(set) var harRortSig = false
        private var stillaSedan: Date?

        mutating func aterstall() { harRortSig = false; stillaSedan = nil }

        mutating func mata(_ v: Double, nu: Date = Date()) -> Bool {
            if v > rorlig { harRortSig = true; stillaSedan = nil; return false }
            guard harRortSig else { return false }
            if v < stilla {
                if stillaSedan == nil { stillaSedan = nu }
                if nu.timeIntervalSince(stillaSedan!) >= stillaTid { aterstall(); return true }
            } else { stillaSedan = nil }
            return false
        }
    }
}

/// Förhandsbild från kameran.
struct KameraForhandsvisning: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
