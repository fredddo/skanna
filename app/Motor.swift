// Skanna-motorn (motor/, Python i Skanna-hemmet, se PLAN-motor.md): appen startar den som barnprocess på en slumpad port
// och låter den ändra de delade projektfilerna (svar.json, mått, kantbehandling, utskrift) och bygga projekten. Motorn
// skriver atomiskt under projektets lås, så appen, byggskripten och Claude inte skriver över varandra.
import Foundation

final class Motor {
    static let delad = Motor()

    struct Fel: Error, CustomStringConvertible { let description: String }

    private var proc: Process?
    private var port: Int?
    private let nyckel = UUID().uuidString
    private let lock = NSLock()

    /// Avsluta motorn (appen stängs). Motorn avslutar sig också själv när appens process försvinner.
    func stoppa() {
        lock.lock(); defer { lock.unlock() }
        proc?.terminate(); proc = nil; port = nil
    }

    private func sakerstall() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if let port, proc?.isRunning == true { return port }
        let py = Hem.url.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: py.path) else { throw Fel(description: "Python-miljön saknas (\(py.path))") }
        let p = Process()
        p.executableURL = py
        p.arguments = ["-m", "motor", "--foralder", String(getpid())]
        p.currentDirectoryURL = Hem.url
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_HEM"] = Hem.url.path
        env["SKANNA_MOTOR_NYCKEL"] = nyckel
        env["PYTHONUTF8"] = "1"
        env.removeValue(forKey: "SKANNA_BYGGLAS")
        p.environment = env
        let ut = Pipe()
        p.standardOutput = ut
        p.standardError = FileHandle.nullDevice
        try p.run()
        // första raden: "MOTOR <port>"
        var rad: String?
        let klar = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var buf = Data()
            while true {
                let d = ut.fileHandleForReading.availableData
                if d.isEmpty { break }
                buf.append(d)
                if let nl = buf.firstIndex(of: 10) { rad = String(decoding: buf[..<nl], as: UTF8.self); break }
            }
            klar.signal()
            while !ut.fileHandleForReading.availableData.isEmpty {}   // töm resten så att motorn aldrig blockerar
        }
        guard klar.wait(timeout: .now() + 15) == .success, let r = rad, r.hasPrefix("MOTOR "), let n = Int(r.dropFirst(6)) else {
            p.terminate()
            throw Fel(description: "Motorn startade inte (\(rad ?? "inget svar"))")
        }
        proc = p; port = n
        return n
    }

    /// Ett anrop till motorn (synkront, lokalt och snabbt). Startar motorn vid behov, och en gång till om den dött.
    @discardableResult
    func anrop(_ metod: String, _ sokvag: String, query: [String: String] = [:], kropp: [String: Any]? = nil,
               timeout: TimeInterval = 15) throws -> [String: Any] {
        do { return try anropEn(metod, sokvag, query: query, kropp: kropp, timeout: timeout) } catch let e as URLError {
            lock.lock(); proc?.terminate(); proc = nil; port = nil; lock.unlock()
            do { return try anropEn(metod, sokvag, query: query, kropp: kropp, timeout: timeout) } catch { throw Fel(description: "Motorn svarar inte: \(e.localizedDescription)") }
        }
    }

    private func anropEn(_ metod: String, _ sokvag: String, query: [String: String], kropp: [String: Any]?, timeout: TimeInterval) throws -> [String: Any] {
        let port = try sakerstall()
        var c = URLComponents()
        c.scheme = "http"; c.host = "127.0.0.1"; c.port = port; c.path = sokvag
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = metod
        req.setValue(nyckel, forHTTPHeaderField: "X-Skanna-Nyckel")
        if let kropp {
            req.httpBody = try JSONSerialization.data(withJSONObject: kropp)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var resultat: Result<(Data, Int), Error> = .failure(Fel(description: "inget svar"))
        let klar = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { resultat = .failure(e) } else { resultat = .success((d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 0)) }
            klar.signal()
        }.resume()
        if klar.wait(timeout: .now() + timeout + 1) == .timedOut { throw URLError(.timedOut) }
        let (data, kod) = try resultat.get()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard kod == 200 else { throw Fel(description: (json["fel"] as? String) ?? "motorn svarade \(kod)") }
        return json
    }

    // MARK: Bekvämligheter

    static func dict<T: Encodable>(_ v: T) -> [String: Any] {
        (try? JSONEncoder().encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

/// Reserv när motorn inte går att starta: projektets skrivlås (samma fil som cad/lagring.py använder) från Swift.
enum ProjektLas {
    static func medLas<T>(_ projekt: URL, _ namn: String = "skriv", _ jobb: () throws -> T) rethrows -> T {
        let dir = projekt.appendingPathComponent(".skanna", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(namn + ".las").path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try jobb()
    }
}
