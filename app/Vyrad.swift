// Sparade vyer: en rad miniatyrer (som appikoner) till vänster om vykuben, och en plusknapp som sparar hela viewporten –
// kamera, synliga lager, flytt/explode, opacitet, färgschema och snitt – med en ögonblicksbild av canvasen.
import AppKit
import SwiftUI

struct VyRad: View {
    @ObservedObject var run: Runner
    @State private var bilder: [String: NSImage] = [:]
    @State private var dopas: SparadVy?
    @State private var nyttNamn = ""
    static let sida: CGFloat = 44

    var body: some View {
        HStack(spacing: 7) {
            if !run.vyer.isEmpty {
                ScrollViewReader { sc in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(run.vyer) { v in miniatyr(v).id(v.id) }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 2)
                    }
                    .frame(maxWidth: CGFloat(min(run.vyer.count, 6)) * (VyRad.sida + 7) + 4, maxHeight: VyRad.sida + 8)
                    .onAppear { sc.scrollTo(run.vyer.last?.id, anchor: .trailing) }
                    .onChange(of: run.vyer.count) { _, _ in withAnimation { sc.scrollTo(run.vyer.last?.id, anchor: .trailing) } }
                }
            }
            Button { run.request("spara-vy") } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.secondary.opacity(0.35))
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: VyRad.sida, height: VyRad.sida)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tips("Spara vyn: kamera eller bildruta, synliga lager, sprängvy (och uppspelning), snitt – med en miniatyr")
        }
        .alert("Byt namn på vyn", isPresented: Binding(get: { dopas != nil }, set: { if !$0 { dopas = nil } })) {
            TextField("Namn", text: $nyttNamn)
            Button("Spara") { if let d = dopas { run.renameVy(d.id, nyttNamn) }; dopas = nil }
            Button("Avbryt", role: .cancel) { dopas = nil }
        }
    }

    private func miniatyr(_ v: SparadVy) -> some View {
        let img = bilder[v.id] ?? run.vyBild(v)
        return Button { run.showVy(v) } label: {
            ZStack {
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: VyRad.sida, height: VyRad.sida)
            .overlay(alignment: .bottomTrailing) {
                if v.spelar == true {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(.black.opacity(0.55))).padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { if bilder[v.id] == nil, let img { bilder[v.id] = img } }
        .tips("\(v.namn)\(v.foto != nil ? " · fotoläge" : "")\(v.spelar == true ? " · spelar sprängvyn" : "")\(v.snitt != nil ? " · med snitt" : "")\(v.dolda.isEmpty ? "" : " · \(v.dolda.count) dolda") – klicka för att gå hit (högerklick: byt namn, ta bort)")
        .contextMenu {
            Button("Gå till \(v.namn)") { run.showVy(v) }
            Button("Byt namn …") { nyttNamn = v.namn; dopas = v }
            Divider()
            Button("Ta bort", role: .destructive) { bilder[v.id] = nil; run.deleteVy(v.id) }
        }
    }
}
