// Bildkontroll för fotogrammetri: skärpa, exponering och blanka reflexer – per bild och för en hel mapp.
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

struct Bildkvalitet: Equatable {
    var skarpa: Double          // varians av Laplace på gråskala (högre = skarpare), ungefär 0–2000
    var ljus: Double            // medelljus 0–1
    var overexp: Double         // andel pixlar ≥ 0.98
    var underexp: Double        // andel pixlar ≤ 0.02
    var reflexer: Double        // andel nästan vita pixlar i bildens mitt (blanka ytor)
    var bredd: Int
    var hojd: Int

    /// Problem i klartext, jämfört med mappens median-skärpa (om känd).
    func problem(medianSkarpa: Double? = nil) -> [String] {
        var p: [String] = []
        if let m = medianSkarpa, m > 0, skarpa < 0.55 * m { p.append("suddig (skärpa \(Int(skarpa)) mot median \(Int(m)))") }
        else if medianSkarpa == nil && skarpa < 25 { p.append("suddig eller ofokuserad") }
        if ljus < 0.18 || underexp > 0.35 { p.append("för mörk") }
        if ljus > 0.85 || overexp > 0.08 { p.append("överexponerad") }
        if reflexer > 0.006 { p.append(String(format: "blanka reflexer (%.1f %% av mitten) – korspolarisera eller matta ytan", reflexer * 100)) }
        if max(bredd, hojd) < 1500 { p.append("låg upplösning (\(bredd)×\(hojd))") }
        return p
    }
}

enum Kvalitet {
    /// Analysera en bild (nedskalad till ~1024 px i gråskala).
    static func analysera(_ cg: CGImage, fullBredd: Int? = nil, fullHojd: Int? = nil) -> Bildkvalitet {
        let maxSide = 1024.0
        let s = min(1, maxSide / Double(max(cg.width, cg.height)))
        let w = max(8, Int(Double(cg.width) * s)), h = max(8, Int(Double(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return Bildkvalitet(skarpa: 0, ljus: 0, overexp: 0, underexp: 0, reflexer: 0, bredd: cg.width, hojd: cg.height) }
        var sum = 0.0, over = 0, under = 0
        for v in px { sum += Double(v); if v >= 250 { over += 1 }; if v <= 5 { under += 1 } }
        let n = Double(w * h)
        // Laplace (4-granne), varians
        var lsum = 0.0, lsq = 0.0, ln = 0.0
        for y in 1..<(h - 1) {
            let r = y * w
            for x in 1..<(w - 1) {
                let c = Int(px[r + x]) * 4
                let l = c - Int(px[r + x - 1]) - Int(px[r + x + 1]) - Int(px[r - w + x]) - Int(px[r + w + x])
                let d = Double(l)
                lsum += d; lsq += d * d; ln += 1
            }
        }
        let mean = lsum / max(ln, 1)
        let lap = lsq / max(ln, 1) - mean * mean
        // reflexer: nästan vitt i mittersta 60 %
        var spec = 0, cn = 0
        for y in Int(Double(h) * 0.2)..<Int(Double(h) * 0.8) {
            for x in Int(Double(w) * 0.2)..<Int(Double(w) * 0.8) {
                cn += 1
                if px[y * w + x] >= 248 { spec += 1 }
            }
        }
        return Bildkvalitet(skarpa: lap, ljus: sum / n / 255, overexp: Double(over) / n, underexp: Double(under) / n,
                            reflexer: Double(spec) / Double(max(cn, 1)), bredd: fullBredd ?? cg.width, hojd: fullHojd ?? cg.height)
    }

    static func analysera(url: URL) -> Bildkvalitet? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let W = props?[kCGImagePropertyPixelWidth] as? Int, H = props?[kCGImagePropertyPixelHeight] as? Int
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return analysera(cg, fullBredd: W, fullHojd: H)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

/// Kontroll av alla bilder i en mapp: lista med problem, och knapp för att flytta bort dåliga bilder.
struct ImageCheckSheet: View {
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var results: [(URL, Bildkvalitet)] = []
    @State private var done = false
    @State private var moved = 0

    var body: some View {
        let med = Kvalitet.median(results.map { $0.1.skarpa })
        let bad = results.filter { !$0.1.problem(medianSkarpa: med).isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            Text("Bildkontroll").font(.title2.bold())
            if !done { ProgressView("Kontrollerar \(results.count) bilder …") }
            else {
                Text("\(results.count) bilder · \(bad.count) med anmärkning" + (med.map { " · median-skärpa \(Int($0))" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            List(bad, id: \.0) { u, q in
                HStack(alignment: .top) {
                    Thumb(url: u).frame(width: 64, height: 48)
                    VStack(alignment: .leading) {
                        Text(u.lastPathComponent).font(.callout.monospaced())
                        Text(q.problem(medianSkarpa: med).joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(minHeight: 260)
            if moved > 0 { Text("\(moved) bilder flyttade till bilder-bortvalda/.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Flytta bort suddiga bilder") { moveBlurry(med) }
                    .disabled(!done || bad.isEmpty)
                    .help("Flyttar bilder som är klart suddigare än de andra till en egen mapp (går att ångra i Finder)")
                Spacer()
                Button("Klar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await run() }
    }

    private func run() async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { bildandelser.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let q = await Task.detached(priority: .userInitiated) { Kvalitet.analysera(url: f) }.value
            if let q { results.append((f, q)) }
        }
        done = true
    }

    private func moveBlurry(_ med: Double?) {
        guard let med else { return }
        let dest = folder.deletingLastPathComponent().appendingPathComponent("bilder-bortvalda")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (u, q) in results where q.skarpa < 0.55 * med {
            if (try? FileManager.default.moveItem(at: u, to: dest.appendingPathComponent(u.lastPathComponent))) != nil { moved += 1 }
        }
        results.removeAll { !FileManager.default.fileExists(atPath: $0.0.path) }
    }
}

struct Thumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Rectangle().fill(Color.secondary.opacity(0.15)) }
        }
        .task(id: url) {
            image = await Task.detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: 256,
                                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}
