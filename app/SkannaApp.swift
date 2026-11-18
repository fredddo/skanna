// Skanna (Beta) – skanna delar till mm-exakta modeller och modellera nya delar, med Claude via filprotokollet (AGENT.md).
import AppKit
import SwiftUI

@main
struct SkannaApp: App {
    @StateObject private var run = Runner()
    @AppStorage("followPhotos") private var followPhotos = false

    var body: some Scene {
        Window(Hem.appNamn, id: "huvud") {
            ContentView(run: run).frame(minWidth: 1080, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nytt modellprojekt …") { run.showNewProject = true }.keyboardShortcut("n")
                Button("Ny skanning från video …") { run.screen = .nySkanning }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Guidad skanning …") { run.screen = .guidad }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Importera foton …") { run.importPhotos() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Öppna mapp …") { run.openOther() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(run.undoName.map { "Ångra \($0)" } ?? "Ångra") { run.undoCommand(redo: false) }.keyboardShortcut("z")
                Button(run.redoName.map { "Gör om \($0)" } ?? "Gör om") { run.undoCommand(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Projekt") {
                Button("Bygg om delarna") { run.rebuild() }.keyboardShortcut("b").disabled(!run.canEdit)
                Button("Skriv ut i Bambu Studio") { run.exportAll() }.keyboardShortcut("e").disabled(run.parts.isEmpty)
                Menu("Lägg till del från mall") {
                    ForEach(run.mallar) { m in Button(m.namn) { run.addPart(from: m) } }
                }.disabled(run.output == nil)
                Divider()
                Button("Kopiera uppdrag till Claude") { run.copyClaudeText() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(run.output == nil)
                Button("Visa projektet i Finder") { run.revealProject() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(run.output == nil)
                Button("Visa bilder i projektet …") { if let o = run.output { NSWorkspace.shared.open(o.appendingPathComponent("bilder")) } }
                    .disabled(run.imageCount == 0)
                Divider()
                Button("Referensark (PDF)") { run.printSheet() }
            }
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Hela modellen") { run.request("Hela") }.keyboardShortcut("0")
                    Button("Topp") { run.request("Topp") }.keyboardShortcut("1")
                    Button("Fram (−Y)") { run.request("−Y") }.keyboardShortcut("2")
                    Button("Höger (+X)") { run.request("+X") }.keyboardShortcut("3")
                    Button("Bak (+Y)") { run.request("+Y") }.keyboardShortcut("4")
                    Button("Vänster (−X)") { run.request("−X") }.keyboardShortcut("5")
                    Button("Botten") { run.request("Botten") }.keyboardShortcut("6")
                    Button("Perspektiv") { run.request("Persp") }.keyboardShortcut("7")
                    Toggle("Fotoläge", isOn: $followPhotos).keyboardShortcut("k")
                }
            }
            CommandGroup(replacing: .help) {
                Button("Kortkommandon") { run.showShortcuts = true }.keyboardShortcut("/")
                Button("Start och skanningsguide") { run.screen = .valkommen }
                Button("Protokollet för Claude (AGENT.md)") { NSWorkspace.shared.open(Hem.agentProtokoll) }
            }
        }
    }
}
