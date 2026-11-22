// Ritar Skannas appikon: swift ikon/rita_ikon.swift <ut.png>  (1024 × 1024). ikon/bygg_ikon.sh gör app/AppIcon.icns.
// Motiv: en isometrisk kub (CAD-delen) vars ena sida håller på att skannas – punktmoln som blir rena ytor – och en skanningslinje.
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS-form: rundad kvadrat med marginal (824 pt i 1024-rutan)
let ram = NSRect(x: 100, y: 100, width: 824, height: 824)
let form = NSBezierPath(roundedRect: ram, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let skugga = NSShadow(); skugga.shadowColor = NSColor.black.withAlphaComponent(0.35); skugga.shadowBlurRadius = 24; skugga.shadowOffset = NSSize(width: 0, height: -10)
skugga.set()
NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.32, alpha: 1).setFill(); form.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
form.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.40, alpha: 1)])!.draw(in: ram, angle: -70)

// isometrisk kub
let c = CGPoint(x: 512, y: 500), a: CGFloat = 230
let dx = a * cos(.pi / 6), dy = a * sin(.pi / 6)
let topp = CGPoint(x: c.x, y: c.y + a), v = CGPoint(x: c.x - dx, y: c.y + dy), h = CGPoint(x: c.x + dx, y: c.y + dy)
let vb = CGPoint(x: c.x - dx, y: c.y - dy), hb = CGPoint(x: c.x + dx, y: c.y - dy), botten = CGPoint(x: c.x, y: c.y - a)
let ovan = CGPoint(x: c.x, y: c.y + 2 * a - a)   // = topp
func yta(_ p: [CGPoint], _ f: NSColor) { let b = NSBezierPath(); b.move(to: p[0]); p.dropFirst().forEach { b.line(to: $0) }; b.close(); f.setFill(); b.fill() }
let ovre = [c, v, CGPoint(x: c.x, y: c.y + 2 * dy), h]
yta(ovre, NSColor.white.withAlphaComponent(0.95))
yta([c, h, hb, botten], NSColor(calibratedRed: 0.80, green: 0.88, blue: 1.0, alpha: 0.92))
// vänster sida: punktmoln (skanningen) som blir yta upptill
let vansterSida = [c, botten, vb, v]
yta(vansterSida, NSColor.white.withAlphaComponent(0.10))
var rng = SystemRandomNumberGenerator()
for i in 0..<14 { for j in 0..<14 {
    let s = (CGFloat(i) + 0.5) / 14, t = (CGFloat(j) + 0.5) / 14
    // punkt i parallellogrammen c→botten (s), c→v (t)
    let p = CGPoint(x: c.x + (v.x - c.x) * t + (botten.x - c.x) * s, y: c.y + (v.y - c.y) * t + (botten.y - c.y) * s)
    let j1 = CGFloat.random(in: -4...4, using: &rng), j2 = CGFloat.random(in: -4...4, using: &rng)
    let r: CGFloat = s < 0.35 ? 0 : 7.5
    if r > 0 { NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x + j1 - r, y: p.y + j2 - r, width: 2 * r, height: 2 * r)).fill() }
}}
let skannad = [c, CGPoint(x: c.x + (botten.x - c.x) * 0.35, y: c.y + (botten.y - c.y) * 0.35),
               CGPoint(x: v.x + (botten.x - c.x) * 0.35, y: v.y + (botten.y - c.y) * 0.35), v]
yta(skannad, NSColor(calibratedRed: 0.70, green: 0.82, blue: 1.0, alpha: 0.95))
// kanter
let kant = NSBezierPath(); kant.lineWidth = 14; kant.lineJoinStyle = .round; kant.lineCapStyle = .round
for (p, q) in [(c, v), (c, h), (c, botten), (v, CGPoint(x: c.x, y: c.y + 2 * dy)), (h, CGPoint(x: c.x, y: c.y + 2 * dy)), (h, hb), (hb, botten)] { kant.move(to: p); kant.line(to: q) }
NSColor.white.setStroke(); kant.stroke()
let streck = NSBezierPath(); streck.lineWidth = 10; streck.setLineDash([22, 16], count: 2, phase: 0)
streck.move(to: v); streck.line(to: vb); streck.line(to: botten); NSColor.white.withAlphaComponent(0.7).setStroke(); streck.stroke()
// skanningslinje
let ly = c.y + (botten.y - c.y) * 0.35
NSGraphicsContext.saveGraphicsState()
let glod = NSShadow(); glod.shadowColor = NSColor(calibratedRed: 0.4, green: 1, blue: 1, alpha: 1); glod.shadowBlurRadius = 30; glod.set()
let linje = NSBezierPath(); linje.lineWidth = 12; linje.lineCapStyle = .round
linje.move(to: CGPoint(x: 190, y: ly + 60)); linje.line(to: CGPoint(x: 560, y: ly - 150))
NSColor(calibratedRed: 0.45, green: 1, blue: 0.95, alpha: 1).setStroke(); linje.stroke()
NSGraphicsContext.restoreGraphicsState()
_ = (topp, ovan, ctx)
NSGraphicsContext.restoreGraphicsState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
