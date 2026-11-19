// Egna tooltips. Varken SwiftUI:s .help eller AppKits toolTip visades i appens fönster (3D-vyn renderar hela tiden
// och SwiftUI bygger om vyerna ofta, vilket nollställer AppKits tooltip-timer). I stället följer varje .tips(...)
// musen med ett eget spårningsområde och visar texten i ett litet eget fönster efter en kort stund.
import AppKit
import SwiftUI

/// Ett delat, klickgenomsläppligt fönster som visar en tooltiptext nära pekaren.
@MainActor
enum Tips {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var timer: Timer?
    private static weak var agare: AnyObject?
    private static var klickMonitor: Any?

    /// Visa `text` efter `dröjsmål` sekunder om ägaren fortfarande vill (anropa `dolj(agare)` när musen går ut).
    static func visa(_ text: String, agare a: AnyObject, efter drojsmal: TimeInterval = 0.5) {
        timer?.invalidate()
        agare = a
        if panel?.isVisible == true { oppna(text); return }   // redan synlig: byt text direkt
        timer = Timer.scheduledTimer(withTimeInterval: drojsmal, repeats: false) { _ in
            MainActor.assumeIsolated { if agare === a { oppna(text) } }
        }
    }
    static func dolj(_ a: AnyObject? = nil) {
        if let a, agare !== a { return }
        timer?.invalidate(); timer = nil
        agare = nil
        panel?.orderOut(nil)
    }
    nonisolated static var synligText: String? { MainActor.assumeIsolated { synligText0 } }
    private static var synligText0: String? { panel?.isVisible == true ? label?.stringValue : nil }

    private static func oppna(_ text: String) {
        if klickMonitor == nil {
            klickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { e in
                MainActor.assumeIsolated { Tips.dolj() }; return e
            }
        }
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.ignoresMouseEvents = true; p.level = .popUpMenu; p.hidesOnDeactivate = true
            p.collectionBehavior = [.transient, .ignoresCycle]
            let bg = NSVisualEffectView()
            bg.material = .toolTip; bg.state = .active; bg.wantsLayer = true
            bg.layer?.cornerRadius = 5; bg.layer?.masksToBounds = true
            let l = NSTextField(wrappingLabelWithString: "")
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .labelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 7),
                l.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -7),
                l.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
                l.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
            ])
            p.contentView = bg
            panel = p; label = l
            return p
        }()
        guard let l = label else { return }
        l.stringValue = text
        l.preferredMaxLayoutWidth = 340
        let s = l.fittingSize
        let size = NSSize(width: min(s.width, 340) + 14, height: s.height + 8)
        // under och lite till höger om pekaren; håll inom skärmen
        let m = NSEvent.mouseLocation
        var o = NSPoint(x: m.x + 10, y: m.y - 22 - size.height)
        if let sk = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) })?.visibleFrame {
            o.x = min(max(o.x, sk.minX + 4), sk.maxX - size.width - 4)
            if o.y < sk.minY + 4 { o.y = m.y + 16 }
        }
        p.setFrame(NSRect(origin: o, size: size), display: true)
        p.orderFrontRegardless()
    }
}

/// Genomskinlig vy över en kontroll: följer musen själv (spårningsområde), tar inga klick (hitTest = nil).
final class TipsVy: NSView {
    var text: String = "" { didSet { if text != oldValue, inne { text.isEmpty ? Tips.dolj(self) : Tips.visa(text, agare: self) } } }
    private var inne = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) {
        inne = true
        // ett ark (sheet) ovanpå fönstret: visa inte tips för kontroller som ligger under det
        if window?.attachedSheet != nil { return }
        if !text.isEmpty { Tips.visa(text, agare: self) }
    }
    override func mouseExited(with event: NSEvent) { inne = false; Tips.dolj(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { inne = false; Tips.dolj(self) } }
    override func viewDidHide() { super.viewDidHide(); inne = false; Tips.dolj(self) }
}

struct TipsLager: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TipsVy { let v = TipsVy(); v.text = text; return v }
    func updateNSView(_ v: TipsVy, context: Context) { v.text = text }
    static func dismantleNSView(_ v: TipsVy, coordinator: ()) { Tips.dolj(v) }
}

extension View {
    /// Tooltip som alltid visas (se ovan). Används i stället för .help överallt utom i menyinnehåll.
    func tips(_ text: String) -> some View { overlay(TipsLager(text: text).allowsHitTesting(false)) }
}

extension NSView {
    /// Tips direkt vid pekaren (3D-vyn: kant/yta/hörn under musen). nil döljer.
    func satTips(_ s: String?) {
        if let s, !s.isEmpty { Tips.visa(s, agare: self, efter: 0.35) } else { Tips.dolj(self) }
    }
}
