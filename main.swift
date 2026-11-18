// skanna: video eller foton (valfri kamera, även iPhone utan LiDAR) -> 3D-modell i millimeter,
// med Apples Object Capture (PhotogrammetrySession) på Macen.
//
//   skanna <video.mov ...| fotomapp> [--ut utmapp] [--langd MM] [--bilder N] [--detalj full|raw|medium|reduced|preview] [--maskning on|off]
//   skanna ark <ut.pdf>         utskrivbart A4-referensark (mönster + mätkors + 100 mm-kontroll)
//
// --langd MM: delens längsta mått, uppmätt med skjutmått. Modellen skalas så att längsta axeln blir exakt det,
// och räta upp: X = längsta, Y = mellersta, Z = kortaste axeln, centrerad i origo. Resultat: modell/modell-mm.obj.
// Utan --langd är skalan okänd (ingen LiDAR) och modell-mm.obj skrivs inte.

import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers

@main
struct Skanna {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write("FEL: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static let usage = """
    användning:
      skanna <video.mov ...| fotomapp> [--ut utmapp] [--langd MM] [--bilder N] [--detalj full|raw|medium|reduced|preview] [--maskning on|off]
             [--ordning oordnad|sekventiell] [--beskar on|off]
      skanna ark <ut.pdf>
      skanna skala <skanningsmapp> <längsta mått mm>
      skanna poser <bildmapp> <ut.json>
    """

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let interactive = args.isEmpty
        if interactive { args = try pickInteractively() }
        if args.first == "skala" {
            // skala om en färdig skanning i efterhand: skanna skala <utmapp> <längsta mått mm>
            guard args.count == 3, let length = Double(args[2].replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }) else {
                throw Fel("användning: skanna skala <skanningsmapp> <längsta mått i mm>")
            }
            let folder = url(args[1]).appendingPathComponent("modell", isDirectory: true)
            guard let obj = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "obj" && $0.lastPathComponent != "modell-mm.obj" }) else {
                throw Fel("Ingen OBJ i \(folder.path)")
            }
            try scaleAndAlign(obj: obj, length: length)
            return
        }
        if args.first == "poser" {
            guard args.count == 3 else { throw Fel("användning: skanna poser <bildmapp> <ut.json>") }
            try await cameraPoses(images: url(args[1]), out: url(args[2]))
            return
        }
        if args.first == "ark" {
            guard args.count == 2 else { throw Fel(usage) }
            try referenceSheet(to: url(args[1]))
            return
        }
        var inputs: [URL] = []
        while let next = args.first, !next.hasPrefix("--") { inputs.append(url(next)); args.removeFirst() }
        guard !inputs.isEmpty, args.count % 2 == 0 else { throw Fel(usage) }
        var opts: [String: String] = [:]
        for i in stride(from: 0, to: args.count, by: 2) { opts[args[i]] = args[i + 1] }
        guard Set(opts.keys).isSubset(of: ["--langd", "--bilder", "--detalj", "--maskning", "--ut", "--ordning", "--beskar"]) else { throw Fel(usage) }
        let length = try opts["--langd"].map { s -> Double in
            let cleaned = s.lowercased().replacingOccurrences(of: ",", with: ".")
                .filter { "0123456789.".contains($0) }
            guard let v = Double(cleaned), v > 0 else { throw Fel("--langd ska vara mm, t.ex. 112.4 (fick \"\(s)\")") }
            return v
        }
        let target = Int(opts["--bilder"] ?? "150") ?? 150
        let detailName = opts["--detalj"] ?? "full"
        let detail: PhotogrammetrySession.Request.Detail
        switch detailName {
        case "preview": detail = .preview
        case "reduced": detail = .reduced
        case "medium": detail = .medium
        case "full": detail = .full
        case "raw": detail = .raw
        default: throw Fel(usage)
        }
        guard PhotogrammetrySession.isSupported else { throw Fel("Den här Macen stöder inte Object Capture.") }

        var dirs: [URL] = [], videos: [URL] = []
        for input in inputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir) else { throw Fel("Hittar inte \(input.path)") }
            if isDir.boolValue { dirs.append(input) } else { videos.append(input) }
        }
        guard dirs.isEmpty || (dirs.count == 1 && videos.isEmpty) else { throw Fel("Ange antingen en fotomapp eller en eller flera videor.") }
        let output = opts["--ut"].map(url) ?? inputs[0].deletingPathExtension().appendingPathExtension("modell")
        // Ett projekt (projekt.json) utan modell får vara utmapp – t.ex. en guidad skanning med bilderna i <projekt>/bilder.
        let isProject = FileManager.default.fileExists(atPath: output.appendingPathComponent("projekt.json").path)
        if isProject && FileManager.default.fileExists(atPath: output.appendingPathComponent("modell/modell-mm.obj").path) {
            throw Fel("\(output.path) har redan en modell (modell/modell-mm.obj); ta bort mappen modell/ först.")
        }
        if FileManager.default.fileExists(atPath: output.path) && !isProject { throw Fel("\(output.path) finns redan; välj en annan med --ut eller ta bort den.") }
        if isProject { try? FileManager.default.removeItem(at: output.appendingPathComponent("modell")) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let images: URL
        if let dir = dirs.first {
            images = dir
        } else {
            images = output.appendingPathComponent("bilder", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for (i, video) in videos.enumerated() {
                print("1/3  Väljer de skarpaste bildrutorna ur \(video.lastPathComponent) (\(i + 1)/\(videos.count)) …")
                let n = try await extractFrames(video: video, to: images, prefix: "klipp\(i + 1)", target: target)
                print("     \(n) bilder")
            }
        }
        let count = try FileManager.default.contentsOfDirectory(atPath: images.path)
            .filter { ["heic", "jpg", "jpeg", "png", "tif", "tiff", "dng"].contains(($0 as NSString).pathExtension.lowercased()) }.count
        guard count >= 20 else { throw Fel("Bara \(count) bilder; filma längre (minst ~1 min) eller ta fler foton.") }

        let modelFolder = output.appendingPathComponent("modell", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        print("2/3  Bygger 3D-modell av \(count) bilder (detalj: \(detailName)) …")
        try await reconstruct(images: images, modelFolder: modelFolder,
                              usdz: detail == .raw ? nil : output.appendingPathComponent("modell.usdz"),
                              detail: detail, masking: (opts["--maskning"] ?? "on") == "on",
                              crop: (opts["--beskar"] ?? "on") == "on", sequential: opts["--ordning"] == "sekventiell")

        print("3/3  Mått och skala …")
        guard let obj = FileManager.default.enumerator(at: modelFolder, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "obj" }) else {
            throw Fel("Ingen OBJ i \(modelFolder.path)")
        }
        try scaleAndAlign(obj: obj, length: length)
        print("\nKlart: \(output.path)")
        if ProcessInfo.processInfo.environment["SKANNA_APP"] == nil { _ = try? osascript(["display notification \"Modellen är klar\" with title \"skanna\" sound name \"Glass\""]) }
        if interactive { _ = try? osascript(["do shell script \"open \" & quoted form of \"\(output.path)\""]) }
    }

    // MARK: Utan argument: välj klipp och mått i vanliga Mac-dialoger

    static func pickInteractively() throws -> [String] {
        guard let picked = try osascript([
            "set fs to choose file with prompt \"Välj videoklippen (håll ⌘ för att välja flera)\" of type {\"public.movie\"} with multiple selections allowed",
            "set out to \"\"",
            "repeat with f in fs",
            "set out to out & POSIX path of f & linefeed",
            "end repeat",
            "return out",
        ]) else { print("Avbrutet."); exit(0) }
        let files = picked.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !files.isEmpty else { print("Inga filer valda."); exit(0) }
        print("Valda klipp:")
        files.forEach { print("  \($0)") }
        guard let length = try osascript([
            "text returned of (display dialog \"Delens längsta mått i mm (från skjutmåttet).\\nLämna tomt om du inte har mätt.\" default answer \"\" buttons {\"Avbryt\", \"Skanna\"} default button \"Skanna\" cancel button \"Avbryt\")",
        ]) else { print("Avbrutet."); exit(0) }
        let trimmed = length.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? files : files + ["--langd", trimmed]
    }

    /// Kör AppleScript-rader; nil om användaren avbröt.
    static func osascript(_ lines: [String]) throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = lines.flatMap { ["-e", $0] }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Video → skarpaste bildrutan per tidsfönster

    static func extractFrames(video: URL, to dir: URL, prefix: String, target: Int) async throws -> Int {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Fel("Filen har inget videospår.") }
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw Fel("Videon är tom.") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? Fel("Kan inte läsa videon.") }

        let window = duration / Double(max(target, 1))
        let context = CIContext(options: [.cacheIntermediates: false])
        var currentWindow = -1
        var bestScore = -1.0
        var best: CGImage?
        var written = 0

        func flush() throws {
            if let image = best {
                written += 1
                try writeJPEG(image, dir.appendingPathComponent("\(prefix)_" + String(format: "%04d.jpg", written)))
            }
            best = nil
            bestScore = -1
        }

        while let sample = out.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let w = min(Int(t / window), target - 1)
            if w != currentWindow {
                try flush()
                currentWindow = w
                print("\r     \(Int(100 * t / duration)) %", terminator: "")
                fflush(stdout)
            }
            let score = sharpness(pixels)
            if score > bestScore {
                let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                if let image = context.createCGImage(CIImage(cvPixelBuffer: pixels), from: rect) {
                    bestScore = score
                    best = image
                }
            }
        }
        try flush()
        print("\r     100 %")
        if reader.status == .failed { throw reader.error ?? Fel("Videoläsningen misslyckades.") }
        return written
    }

    /// Laplace-energi i mitten av bilden (där delen är). Högre = skarpare.
    static func sharpness(_ pixels: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(pixels) else { return 0 }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let bpr = CVPixelBufferGetBytesPerRow(pixels)
        let cw = min(w, 1400), ch = min(h, 1400)
        let x0 = (w - cw) / 2, y0 = (h - ch) / 2
        @inline(__always) func lum(_ x: Int, _ y: Int) -> Int {
            let p = base + y * bpr + x * 4
            return Int(p[0]) + 2 * Int(p[1]) + Int(p[2])
        }
        var sum = 0.0
        for y in stride(from: y0 + 1, to: y0 + ch - 1, by: 2) {
            for x in stride(from: x0 + 1, to: x0 + cw - 1, by: 2) {
                let l = 4 * lum(x, y) - lum(x - 1, y) - lum(x + 1, y) - lum(x, y - 1) - lum(x, y + 1)
                sum += Double(l * l)
            }
        }
        return sum
    }

    static func writeJPEG(_ image: CGImage, _ url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Fel("Kan inte skriva \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Fel("Kan inte skriva \(url.path)") }
    }

    // MARK: Kamerapositioner

    /// Kamerapose (kamera → rekonstruktion, ARKit-konvention: kameran tittar mot −Z, Y upp) och intrinsics per bild,
    /// plus en snabb modell (preview) i SAMMA session/ram, så att poserna kan passas in mot en annan modell.
    static func cameraPoses(images: URL, out: URL) async throws {
        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = .unordered
        config.featureSensitivity = .high
        config.isObjectMaskingEnabled = true
        let session = try PhotogrammetrySession(input: images, configuration: config)
        let preview = out.deletingLastPathComponent().appendingPathComponent("poser-modell", isDirectory: true)
        try? FileManager.default.removeItem(at: preview)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try session.process(requests: [.poses, .modelFile(url: preview, detail: .preview)])
        var rows: [[String: Any]] = []
        for try await event in session.outputs {
            switch event {
            case .requestProgress(_, let f):
                print("\r     \(Int(f * 100)) %", terminator: ""); fflush(stdout)
            case .requestComplete(_, let result):
                if case .poses(let poses) = result {
                    for (id, pose) in poses.posesBySample.sorted(by: { $0.key < $1.key }) {
                        let m = pose.transform.matrix
                        var row: [String: Any] = [
                            "id": id,
                            "bild": poses.urlsBySample[id]?.lastPathComponent ?? "",
                            "kamera_till_modell": (0..<4).map { r in (0..<4).map { c in Double(m[c][r]) } },  // radvis
                        ]
                        if #available(macOS 26.0, *), let k = pose.intrinsics {
                            row["K"] = (0..<3).map { r in (0..<3).map { c in Double(k[c][r]) } }            // radvis
                        }
                        rows.append(row)
                    }
                }
            case .requestError(_, let error): throw error
            case .processingComplete:
                let data = try JSONSerialization.data(withJSONObject: ["poser": rows, "snabbmodell": preview.path], options: [.prettyPrinted])
                try data.write(to: out)
                print("\n     \(rows.count) kamerapositioner → \(out.path)")
                return
            default: break
            }
        }
    }

    // MARK: Fotogrammetri

    static func reconstruct(images: URL, modelFolder: URL, usdz: URL?, detail: PhotogrammetrySession.Request.Detail, masking: Bool,
                            crop: Bool = true, sequential: Bool = false) async throws {
        var config = PhotogrammetrySession.Configuration()
        // sekventiell: stillbilder i följd (vridskiva) – snabbare och säkrare matchning mellan grannbilder
        config.sampleOrdering = sequential ? .sequential : .unordered
        config.featureSensitivity = .high
        config.isObjectMaskingEnabled = masking
        let session = try PhotogrammetrySession(input: images, configuration: config)
        // Pass 1 (vid beskärning): snabbmodell i samma session → hitta bordsplanet och objektet ovanför det.
        let preview = modelFolder.deletingLastPathComponent().appendingPathComponent(".snabbmodell", isDirectory: true)
        var plane: (SIMD3<Float>, Float, Float)?   // normal, d, tolerans (sessionens enheter)
        var finalRequests: [PhotogrammetrySession.Request] = []
        func requests(_ geometry: PhotogrammetrySession.Request.Geometry?) -> [PhotogrammetrySession.Request] {
            var r: [PhotogrammetrySession.Request] = [.modelFile(url: modelFolder, detail: detail, geometry: geometry)]
            if let usdz { r.append(.modelFile(url: usdz, detail: detail, geometry: geometry)) }
            return r
        }
        var pass = crop ? 1 : 2
        if crop {
            try? FileManager.default.removeItem(at: preview)
            try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
            print("     pass 1: snabbmodell för att hitta objektet …")
            try session.process(requests: [.modelFile(url: preview, detail: .preview)])
        } else {
            finalRequests = requests(nil)
            try session.process(requests: finalRequests)
        }
        var skipped = 0
        var lastPercent = -1
        for try await event in session.outputs {
            switch event {
            case .requestProgress(_, let fraction):
                let percent = Int(fraction * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    print("\r     \(percent) %", terminator: "")
                    fflush(stdout)
                }
            case .requestComplete(_, let result):
                if case .modelFile(let url) = result, pass == 2 { print("\r     klar: \(url.lastPathComponent)") }
            case .invalidSample(let id, let reason):
                print("\n     ogiltig bild \(id): \(reason)")
            case .skippedSample:
                skipped += 1
            case .requestError(_, let error):
                throw error
            case .processingComplete:
                if pass == 1 {
                    pass = 2
                    var geometry: PhotogrammetrySession.Request.Geometry?
                    if let obj = FileManager.default.enumerator(at: preview, includingPropertiesForKeys: nil)?
                        .compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "obj" }),
                       let found = findObject(obj: obj) {
                        plane = found.plane
                        geometry = .init(bounds: found.bounds)
                        print("\r     objektet hittat ovanför bordsplanet – bygger bara inom dess volym")
                    } else {
                        print("\r     hittade inget tydligt bordsplan – bygger hela scenen")
                    }
                    try? FileManager.default.removeItem(at: preview)
                    print("     pass 2: full modell …")
                    try session.process(requests: requests(geometry))
                    continue
                }
                if skipped > 0 { print("     \(skipped) bilder kunde inte placeras och hoppades över") }
                if let plane, let obj = FileManager.default.enumerator(at: modelFolder, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "obj" && $0.lastPathComponent != "modell-mm.obj" }) {
                    let removed = try removePlane(obj: obj, normal: plane.0, d: plane.1, tol: plane.2)
                    print("     tog bort \(removed) trianglar av bordet/arket")
                }
                return
            case .processingCancelled:
                throw Fel("avbruten")
            default:
                break
            }
        }
    }

    /// Bordsplanet (RANSAC) och det största sammanhängande objektet ovanför det, i snabbmodellens (=sessionens) ram.
    static func findObject(obj: URL) -> (bounds: BoundingBox, plane: (SIMD3<Float>, Float, Float))? {
        guard let text = try? String(contentsOf: obj, encoding: .utf8) else { return nil }
        var pts: [SIMD3<Float>] = []
        for line in text.split(separator: "\n") where line.hasPrefix("v ") {
            let f = line.split(separator: " ").dropFirst().prefix(3).compactMap { Float($0) }
            if f.count == 3 { pts.append(SIMD3(f[0], f[1], f[2])) }
        }
        guard pts.count > 500 else { return nil }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let diag = simd_length(hi - lo)
        let thr = diag * 0.006
        let sample = stride(from: 0, to: pts.count, by: max(1, pts.count / 15000)).map { pts[$0] }
        var best = (n: SIMD3<Float>(0, 0, 1), d: Float(0), count: 0)
        for _ in 0..<500 {
            let a = sample.randomElement()!, b = sample.randomElement()!, c = sample.randomElement()!
            let cr = simd_cross(b - a, c - a)
            let l = simd_length(cr)
            if l < 1e-12 { continue }
            let n = cr / l, d = simd_dot(n, a)
            var cnt = 0
            for p in sample where abs(simd_dot(n, p) - d) < thr { cnt += 1 }
            if cnt > best.count { best = (n, d, cnt) }
        }
        // planet måste vara dominant (arket/bordet)
        guard Double(best.count) > Double(sample.count) * 0.25 else { return nil }
        var n = best.n, d = best.d
        let offs = pts.map { simd_dot(n, $0) - d }
        let up = offs.filter { $0 > 3 * thr }.count, down = offs.filter { $0 < -3 * thr }.count
        if down > up { n = -n; d = -d }
        let above = pts.indices.filter { simd_dot(n, pts[$0]) - d > 3 * thr }
        guard above.count > 100 else { return nil }
        let u = simd_normalize(simd_cross(n, abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
        let w = simd_cross(n, u)
        let cell = diag / 90
        var grid: [SIMD2<Int32>: [Int]] = [:]
        for i in above {
            let p = pts[i]
            grid[SIMD2(Int32((simd_dot(p, u) / cell).rounded(.down)), Int32((simd_dot(p, w) / cell).rounded(.down))), default: []].append(i)
        }
        var seen = Set<SIMD2<Int32>>()
        var bestComp: [Int] = []
        for k in grid.keys where !seen.contains(k) {
            var comp: [Int] = []
            var queue = [k]
            seen.insert(k)
            while let c = queue.popLast() {
                comp += grid[c]!
                for dx in Int32(-1)...1 { for dy in Int32(-1)...1 {
                    let nk = SIMD2<Int32>(c.x + dx, c.y + dy)
                    if grid[nk] != nil, !seen.contains(nk) { seen.insert(nk); queue.append(nk) }
                } }
            }
            if comp.count > bestComp.count { bestComp = comp }
        }
        guard bestComp.count > 100 else { return nil }
        var olo = SIMD3<Float>(repeating: .infinity), ohi = SIMD3<Float>(repeating: -.infinity)
        for i in bestComp {
            let p = pts[i]
            // ta med objektets fot ner till (strax under) planet
            let foot = p - (simd_dot(n, p) - d + thr) * n
            olo = simd_min(olo, simd_min(p, foot)); ohi = simd_max(ohi, simd_max(p, foot))
        }
        let margin = simd_length(ohi - olo) * 0.05
        return (BoundingBox(min: olo - margin, max: ohi + margin), (n, d, diag * 0.0025))
    }

    /// Tar bort trianglar som ligger helt i bordsplanet (arket under objektet). Hörnen lämnas kvar men används inte.
    static func removePlane(obj: URL, normal n: SIMD3<Float>, d: Float, tol: Float) throws -> Int {
        let text = try String(contentsOf: obj, encoding: .utf8)
        var verts: [SIMD3<Float>] = []
        var out: [Substring] = []
        var removed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("v ") {
                let f = line.split(separator: " ").dropFirst().prefix(3).compactMap { Float($0) }
                verts.append(f.count == 3 ? SIMD3(f[0], f[1], f[2]) : .zero)
            } else if line.hasPrefix("f ") {
                let idx = line.split(separator: " ").dropFirst().compactMap { Int($0.split(separator: "/").first ?? "") }
                if !idx.isEmpty, idx.allSatisfy({ i in i >= 1 && i <= verts.count && abs(simd_dot(n, verts[i - 1]) - d) < tol }) {
                    removed += 1
                    continue
                }
            }
            out.append(line)
        }
        try out.joined(separator: "\n").write(to: obj, atomically: true, encoding: .utf8)
        return removed
    }

    // MARK: Skala till mm och räta upp längs huvudaxlarna

    static func scaleAndAlign(obj: URL, length: Double?) throws {
        let text = try String(contentsOf: obj, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var allPoints: [SIMD3<Double>] = []
        var used = Set<Int>()
        allPoints.reserveCapacity(lines.count / 2)
        for line in lines {
            if line.hasPrefix("v ") {
                let f = line.split(separator: " ").dropFirst().prefix(3).compactMap { Double($0) }
                allPoints.append(f.count == 3 ? SIMD3(f[0], f[1], f[2]) : .zero)
            } else if line.hasPrefix("f ") {
                for tok in line.split(separator: " ").dropFirst() { if let i = Int(tok.split(separator: "/").first ?? "") { used.insert(i - 1) } }
            }
        }
        // mått och axlar bara ur hörn som används av trianglar (borttaget bord/ark räknas inte)
        let points = used.isEmpty ? allPoints : used.filter { $0 >= 0 && $0 < allPoints.count }.sorted().map { allPoints[$0] }
        guard points.count > 3 else { throw Fel("OBJ saknar hörn") }

        var mean = SIMD3<Double>(repeating: 0)
        for p in points { mean += p }
        mean /= Double(points.count)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in points {
            let d = p - mean
            for i in 0..<3 { for j in 0..<3 { cov[i][j] += d[i] * d[j] } }
        }
        // Start: huvudaxlar (PCA). Förfina sedan till minsta omslutande låda – det skjutmåttet mäter – genom att
        // vrida runt en axel i taget till minsta tvärsnittsarea (exakt via 2D-konvext hölje).
        var frame = eigenvectors(cov)
        frame[2] = simd_normalize(simd_cross(frame[0], frame[1]))
        for _ in 0..<4 {
            for a in 0..<3 {
                let b = (a + 1) % 3, c = (a + 2) % 3
                let flat = points.map { SIMD2(simd_dot($0, frame[b]), simd_dot($0, frame[c])) }
                let phi = minAreaAngle(hull2D(flat))
                let nb = frame[b] * cos(phi) + frame[c] * sin(phi)
                let nc = frame[c] * cos(phi) - frame[b] * sin(phi)
                frame[b] = simd_normalize(nb)
                frame[c] = simd_normalize(nc)
            }
        }
        let axesUnsorted = frame
        // Utbredning längs varje axel; sortera längst → kortast.
        func extent(_ a: SIMD3<Double>) -> (Double, Double) {
            var lo = Double.infinity, hi = -Double.infinity
            for p in points { let s = simd_dot(p, a); lo = min(lo, s); hi = max(hi, s) }
            return (lo, hi)
        }
        let ranked = axesUnsorted.map { a -> (SIMD3<Double>, Double, Double) in let e = extent(a); return (a, e.0, e.1) }
            .sorted { ($0.2 - $0.1) > ($1.2 - $1.1) }
        let x = ranked[0].0, y = ranked[1].0
        let z = simd_cross(x, y)  // högerhänt
        let sizes = ranked.map { $0.2 - $0.1 }
        let center = x * (ranked[0].1 + ranked[0].2) / 2 + y * (ranked[1].1 + ranked[1].2) / 2
            + z * { let e = extent(z); return (e.0 + e.1) / 2 }()

        guard let length else {
            let r = sizes[1] / sizes[0], s = sizes[2] / sizes[0]
            print("     Proportioner (längsta = 1): 1 × \(fmt(r, 3)) × \(fmt(s, 3))")
            print("     Ingen --langd angiven: skalan är okänd. Mät delens längsta mått med skjutmått och kör om med --langd MM,")
            print("     eller skala i Fusion. (Bilderna och modellen ligger kvar; omkörning går fort med en mapp: skanna <utmapp>/bilder …)")
            return
        }
        let k = length / sizes[0]
        print("     Mått: \(fmt(sizes[0] * k, 2)) × \(fmt(sizes[1] * k, 2)) × \(fmt(sizes[2] * k, 2)) mm  (X × Y × Z)")
        print("     Kontrollera gärna ett av de två andra måtten med skjutmåttet; stämmer det är skalan rätt.")

        var outLines: [String] = []
        outLines.reserveCapacity(lines.count + 4)
        outLines.append("# skanna: skalad till mm (längsta axeln = \(fmt(length, 3)) mm), X längsta, Z kortaste, centrerad")
        for line in lines {
            if line.hasPrefix("v ") || line.hasPrefix("vn ") {
                let parts = line.split(separator: " ")
                let f = parts.dropFirst().prefix(3).compactMap { Double($0) }
                guard f.count == 3 else { outLines.append(String(line)); continue }
                let p = SIMD3(f[0], f[1], f[2])
                if line.hasPrefix("v ") {
                    let d = (p - center) * k
                    var s = "v \(fmt(simd_dot(d, x), 4)) \(fmt(simd_dot(d, y), 4)) \(fmt(simd_dot(d, z), 4))"
                    for extra in parts.dropFirst(4) { s += " \(extra)" }  // ev. vertexfärg
                    outLines.append(s)
                } else {
                    outLines.append("vn \(fmt(simd_dot(p, x), 5)) \(fmt(simd_dot(p, y), 5)) \(fmt(simd_dot(p, z), 5))")
                }
            } else {
                outLines.append(String(line))
            }
        }
        let scaled = obj.deletingLastPathComponent().appendingPathComponent("modell-mm.obj")
        try outLines.joined(separator: "\n").write(to: scaled, atomically: true, encoding: .utf8)
        print("     Fusion: Insert → Insert Mesh → \(scaled.path)  (enhet: millimeter)")
    }

    /// Konvext hölje i 2D (monotone chain), moturs.
    static func hull2D(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Vinkel φ så att axlarna (cos φ, sin φ), (−sin φ, cos φ) ger minsta omslutande rektangel.
    /// Minsta rektangeln har alltid en sida längs en kant i höljet.
    static func minAreaAngle(_ hull: [SIMD2<Double>]) -> Double {
        guard hull.count > 2 else { return 0 }
        var bestArea = Double.infinity, bestPhi = 0.0
        for i in 0..<hull.count {
            let e = hull[(i + 1) % hull.count] - hull[i]
            guard simd_length(e) > 1e-12 else { continue }
            let phi = atan2(e.y, e.x)
            let u = SIMD2(cos(phi), sin(phi)), w = SIMD2(-sin(phi), cos(phi))
            var lu = Double.infinity, hu = -Double.infinity, lw = Double.infinity, hw = -Double.infinity
            for q in hull {
                let a = simd_dot(q, u), b = simd_dot(q, w)
                lu = min(lu, a); hu = max(hu, a); lw = min(lw, b); hw = max(hw, b)
            }
            let area = (hu - lu) * (hw - lw)
            if area < bestArea { bestArea = area; bestPhi = phi }
        }
        return bestPhi
    }

    /// Egenvektorer till en symmetrisk 3×3-matris (Jacobi).
    static func eigenvectors(_ m: [[Double]]) -> [SIMD3<Double>] {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<100 {
            var p = 0, q = 1
            if abs(a[0][2]) > abs(a[p][q]) { p = 0; q = 2 }
            if abs(a[1][2]) > abs(a[p][q]) { p = 1; q = 2 }
            if abs(a[p][q]) < 1e-18 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 { let kp = a[k][p], kq = a[k][q]; a[k][p] = c * kp - s * kq; a[k][q] = s * kp + c * kq }
            for k in 0..<3 { let pk = a[p][k], qk = a[q][k]; a[p][k] = c * pk - s * qk; a[q][k] = s * pk + c * qk }
            for k in 0..<3 { let kp = v[k][p], kq = v[k][q]; v[k][p] = c * kp - s * kq; v[k][q] = s * kp + c * kq }
        }
        return (0..<3).map { simd_normalize(SIMD3(v[0][$0], v[1][$0], v[2][$0])) }
    }

    // MARK: A4-referensark

    static func referenceSheet(to url: URL) throws {
        let mm = 72.0 / 25.4
        var box = CGRect(x: 0, y: 0, width: 210 * mm, height: 297 * mm)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Fel("Kan inte skapa \(url.path)") }
        ctx.beginPDFPage(nil)
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * mm, y: (297 - y) * mm) }  // mm från övre vänstra hörnet
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))

        let targets: [(String, Double, Double)] = [("A", 20, 25), ("B", 190, 25), ("C", 20, 277), ("D", 190, 277)]
        // Slumpmönster (fast frö) som ger fotogrammetrin gott om fästpunkter.
        var seed: UInt64 = 0x5EED_0F_5CA9
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var placed = 0
        while placed < 1800 {
            let x = 8 + rnd() * 194, y = 18 + rnd() * 271
            if targets.contains(where: { hypot($0.1 - x, $0.2 - y) < 13 }) { continue }
            if targets.contains(where: { t in
                let lx = t.1 + (t.1 < 100 ? 10 : -13) + 2, ly = t.2 + (t.2 < 100 ? 11 : -9) - 2
                return abs(lx - x) < 5 && abs(ly - y) < 5
            }) { continue }
            let r = 0.4 + pow(rnd(), 2) * 2.2
            ctx.fillEllipse(in: CGRect(x: (x - r) * mm, y: (297 - y - r) * mm, width: 2 * r * mm, height: 2 * r * mm))
            placed += 1
        }
        // Mätkors: svart/vit kvadrantcirkel, centrum exakt i hörnet mellan kvadranterna.
        for (name, x, y) in targets {
            let c = pt(x, y), r = 7 * mm
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - r - 2 * mm, y: c.y - r - 2 * mm, width: 2 * r + 4 * mm, height: 2 * r + 4 * mm))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for start in [0.0, Double.pi] {
                ctx.move(to: c)
                ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start + .pi / 2, clockwise: false)
                ctx.closePath()
            }
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(0.3 * mm)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            text(ctx, name, at: pt(x + (x < 100 ? 10 : -13), y + (y < 100 ? 11 : -9)), size: 11)
        }
        // 100 mm-kontroll längst upp.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: (297 - 17) * mm, width: 210 * mm, height: 17 * mm))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(0.25 * mm)
        ctx.move(to: pt(55, 9)); ctx.addLine(to: pt(155, 9))
        for i in 0...10 { let x = 55 + Double(i) * 10; ctx.move(to: pt(x, 9)); ctx.addLine(to: pt(x, i % 5 == 0 ? 5 : 7)) }
        ctx.strokePath()
        text(ctx, "100 mm — skriv ut i 100 % (inte \"anpassa\"). A–B = 170 mm, A–C = 252 mm vid korrekt utskrift.", at: pt(14, 14.5), size: 7.5)
        ctx.endPDFPage()
        ctx.closePDF()
        print("Referensark: \(url.path)")
        print("Skriv ut i 100 %, kontrollera 100 mm-strecket, lägg arket plant och delen mitt på.")
    }

    static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: Double) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    // MARK: Hjälp

    static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    static func fmt(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
}

struct Fel: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
