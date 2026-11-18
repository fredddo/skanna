// Skanningsguiden (visas på startsidan).
import SwiftUI

struct Guide: View {
    let printSheet: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text("Guidad (stativ + vridskiva)").tag(0)
                Text("Video (gå runt)").tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 420)
            if tab == 0 { guided } else { video }
        }
    }

    private var guided: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, "Utrustning", [
                "iPhone på stativ, liggande. Den används som kamera för Macen (Continuity Camera) – lås den och ställ den nära Macen, eller koppla in den med sladd.",
                "Vridskivan: två utskrivna delar, 24 snäpplägen, inga köpdelar – knappen Skriv ut vridskivan i Guidad skanning öppnar den i Bambu Studio.",
                "Polfilm på lampan och ett polfilter framför iPhonens lins (korspolarisering).",
                "Matt enfärgad bakgrund, t.ex. svart kartong.",
            ])
            step(2, "Korspolarisera", [
                "Tänd bara lampan/lamporna med polfilm. Titta på förhandsbilden i appen.",
                "Vrid polfiltret framför linsen tills de blanka reflexerna på delen försvinner. Bilden blir mörkare – öka ljuset hellre än exponeringen.",
            ])
            step(3, "Fota", [
                "Delen mitt på skivan. Ställ skärpan på delen och lås fokus/exponering i appen.",
                "Appen säger vilken vinkel som är nästa. Vrid ett snäpp, tryck mellanslag (eller använd Autofoto, som tar bilden när skivan stått still).",
                "Efter varje varv: flytta kameran till nästa höjd. Sist: vänd delen och ta en omgång till.",
            ])
            step(4, "Bygg", [
                "Kontrollera bilderna (suddiga flyttas bort med ett klick), skriv längsta mått och tryck Bygg 3D-modell.",
            ], button: ("Öppna referensark", printSheet))
        }
    }

    private var video: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, "Förbered (en gång)", [
                "Skriv ut referensarket i 100 % och kontrollera 100 mm-strecket.",
                "iPhone: Kamera → Spela in video → 4K 60 bps (eller 30). Stäng av HDR-video.",
            ], button: ("Öppna referensark", printSheet))
            step(2, "Gör ytan matt", [
                "Blank eller svart plast: tunt lager torrschampo, fotpuder eller scanningspray.",
                "Mät delens längsta mått med skjutmått.",
            ])
            step(3, "Ställ upp", ["Arket plant på bordet, delen mitt på.", "Jämnt, mjukt ljus. Inga hårda skuggor, ingen blixt."])
            step(4, "Filma", [
                "Video. Håll fingret på delen tills AE/AF-LÅS visas.",
                "Gå långsamt tre varv: lågt, snett ovanifrån, högt. ~20–30 s per varv. Delen stor i bild men alltid helt synlig.",
                "Vänd delen och filma ett klipp till.",
            ])
            step(5, "För över och skanna", [
                "Sladd: lås upp iPhone, \"Lita på\", öppna Bildinsamling och importera till Hämtade filer.",
                "Dra in klippen i Ny skanning, skriv längsta mått, tryck Skanna.",
            ])
        }
    }

    private func step(_ n: Int, _ title: String, _ lines: [String], button: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.headline).frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(lines, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if let button { Button(button.0, action: button.1).padding(.top, 2) }
            }
        }
    }
}
