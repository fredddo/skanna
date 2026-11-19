// Tooltips via AppKit. SwiftUI:s .help registrerade inga tooltips i appens fönster (HSplitView + 3D-vyn ovanpå),
// så varje .tips(...) lägger en genomskinlig AppKit-vy med toolTip över kontrollen. Vyn tar inga klick (hitTest = nil).
import AppKit
import SwiftUI

final class TipsVy: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
}

struct TipsLager: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TipsVy { let v = TipsVy(); v.toolTip = text.isEmpty ? nil : text; return v }
    func updateNSView(_ v: TipsVy, context: Context) {
        let t: String? = text.isEmpty ? nil : text
        if v.toolTip != t { v.toolTip = t }
    }
}

extension View {
    /// Tooltip som alltid visas (se ovan). Används i stället för .help överallt utom i menyinnehåll.
    func tips(_ text: String) -> some View { overlay(TipsLager(text: text).allowsHitTesting(false)) }
}
