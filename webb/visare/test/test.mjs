#!/usr/bin/env node
// Test av visarens rena logik i node (ingen npm): node webb/visare/test/test.mjs  → kod ≠ 0 vid fel.
import { createDecipheriv, createHash, createHmac, randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";

import { krypteraSKD1, packa } from "./gor-paket.mjs";
import { b64urlAvkoda, b64urlKoda, dekryptera, hamtaPaket, kryptera, lasFragment, oppnaPaket, tolkaLank, VisarFel } from "../js/paket.js";
import { avkodaSvar, brevBlob, brevData, kodaSvar, lasLagrat, nyKommentar, skickaBrev, sparaLagrat, svarslank } from "../js/kommentarer.js";
import { byggModell } from "../js/modell.js";
import { fallUtTillValt, gruppNyckel, radTand, tradRader, valdRad, valdStig, vaxlaOga } from "../js/trad.js";
import { borjaDra, dra, explodeVector, placeraBlad, sprangGrupp, synlig, synligaMatt } from "../js/sprang.js";
import { byggBVH, stralBVH, stralMotModell, triangelTraff } from "../js/stralar.js";
import { fastKandidater, fastpunkter, kantKandidater, matFaste, matt, tal, ytInfo } from "../js/matt.js";
import { Kamera } from "../js/kamera.js";
import { harledKanter } from "../js/kanter.js";

const HAR = dirname(fileURLToPath(import.meta.url));
const REPO = join(HAR, "..", "..", "..");
let ok = 0, fel = 0;
const grupper = [];

function test(namn, fn) { grupper.push([namn, fn]); }
function sant(v, text) { if (!v) throw new Error(text || "förväntade sant"); }
function lika(a, b, text) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${text || "olika"}: ${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`);
}
function nara(a, b, tol = 1e-6, text = "") {
  const A = Array.isArray(a) ? a : [a], B = Array.isArray(b) ? b : [b];
  if (A.length !== B.length || A.some((x, i) => !(Math.abs(x - B[i]) <= tol))) throw new Error(`${text} ${JSON.stringify(a)} ≉ ${JSON.stringify(b)}`);
}
async function kastar(fn, kod) {
  try { await fn(); } catch (e) {
    if (kod && !(e instanceof VisarFel && e.kod === kod)) throw new Error(`fel kod: ${e.kod || e.message}, väntade ${kod}`);
    return e;
  }
  throw new Error(`kastade inte (${kod})`);
}

// ---------- testdata ----------

/** En låda som 6 plana ytor (som export_faces): id från startId, kropp k, med kanter om kanter = true. */
function lada(lo, hi, startId = 0, k = 0) {
  const [x0, y0, z0] = lo, [x1, y1, z1] = hi;
  const sidor = [
    [[0, 0, -1], [[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0]]],
    [[0, 0, 1], [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]],
    [[0, -1, 0], [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]]],
    [[0, 1, 0], [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0]]],
    [[-1, 0, 0], [[x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]]],
    [[1, 0, 0], [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]]],
  ];
  return sidor.map(([n, p], i) => {
    const area = Math.hypot(...[0, 1, 2].map((a) => p[1][a] - p[0][a])) * Math.hypot(...[0, 1, 2].map((a) => p[3][a] - p[0][a]));
    const c = [0, 1, 2].map((a) => (p[0][a] + p[2][a]) / 2);
    return { id: startId + i, typ: "plan", area, centrum: c, normal: n, radie: null, kropp: k, v: p.flat(), t: [0, 1, 2, 0, 2, 3] };
  });
}

function ladKanter(lo, hi, startId = 0) {
  const P = (i) => [i & 1 ? hi[0] : lo[0], i & 2 ? hi[1] : lo[1], i & 4 ? hi[2] : lo[2]];
  const ut = [];
  for (let i = 0; i < 8; i++) for (const b of [1, 2, 4]) if (!(i & b)) {
    const a = P(i), c = P(i | b);
    ut.push({ id: startId + ut.length, typ: "linje", langd: Math.hypot(c[0] - a[0], c[1] - a[1], c[2] - a[2]), radie: null, centrum: null,
      mitt: a.map((x, j) => (x + c[j]) / 2), p: [...a, ...c], ytor: [] });
  }
  return ut;
}

function del(id, kroppar, extra = {}) {
  // kroppar: [[lo, hi, {namn, grupp}]]
  const ytor = [], kanter = [], kl = [];
  kroppar.forEach(([lo, hi, info = {}], k) => {
    ytor.push(...lada(lo, hi, ytor.length, k));
    kanter.push(...ladKanter(lo, hi, kanter.length).map((e) => ({ ...e, ytor: [6 * k] })));
    kl.push({ id: k, namn: info.namn || `Kropp ${k + 1}`, ...(info.grupp ? { grupp: info.grupp } : {}) });
  });
  return { id, namn: extra.namn || id, farg: "#336699", foralder: null, roll: "design", dold: false, ytor, kanter, kroppar: kl, ...extra };
}

const paket = (delar) => ({ version: 1, namn: "Test", enhet: "mm", fran: null, brevlada: null, delar });
const tomt = () => ({ dolda: new Set(), utfallda: new Set(), t: 1, flytt: new Map(), sprangFlytt: new Map() });

// ---------- paket och krypto ----------

test("base64url fram och tillbaka", () => {
  for (const n of [0, 1, 2, 3, 16, 32, 100]) {
    const b = new Uint8Array(randomBytes(n));
    lika([...b64urlAvkoda(b64urlKoda(b))], [...b]);
    lika(b64urlKoda(b), Buffer.from(b).toString("base64url"), "samma som node");
  }
});

test("avkryptering runt-och-tillbaka (node krypterar, visaren läser)", async () => {
  const nyckel = randomBytes(32);
  const p = paket([del("a", [[[0, 0, 0], [1, 1, 1]]])]);
  const blob = krypteraSKD1(gzipSync(Buffer.from(JSON.stringify(p))), nyckel);
  const ut = await oppnaPaket(new Uint8Array(blob), new Uint8Array(nyckel));
  lika(ut, p);
});

test("fel nyckel och ändrad fil avvisas före avkryptering", async () => {
  const nyckel = randomBytes(32);
  const blob = krypteraSKD1(gzipSync(Buffer.from("{}")), nyckel);
  await kastar(() => dekryptera(new Uint8Array(blob), new Uint8Array(randomBytes(32))), "fel-nyckel");
  const andrad = Buffer.from(blob); andrad[30] ^= 1;
  await kastar(() => dekryptera(new Uint8Array(andrad), new Uint8Array(nyckel)), "fel-nyckel");
  const fel = Buffer.from(blob); fel[0] = 0x58;
  await kastar(() => dekryptera(new Uint8Array(fel), new Uint8Array(nyckel)), "trasig");
  await kastar(() => dekryptera(new Uint8Array(10), new Uint8Array(nyckel)), "trasig");
  // fel version
  const v2 = krypteraSKD1(gzipSync(Buffer.from(JSON.stringify({ version: 2, delar: [] }))), nyckel);
  await kastar(() => oppnaPaket(new Uint8Array(v2), new Uint8Array(nyckel)), "trasig");
});

test("visarens kryptering läses av node (samma SKD1 som dela.py)", async () => {
  const nyckel = randomBytes(32);
  const data = new TextEncoder().encode("hej brevlådan ".repeat(20));
  const blob = Buffer.from(await kryptera(data, new Uint8Array(nyckel)));
  lika(blob.subarray(0, 4).toString(), "SKD1");
  const kEnc = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-enc")])).digest();
  const kMac = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-mac")])).digest();
  const mac = createHmac("sha256", kMac).update(blob.subarray(0, blob.length - 32)).digest();
  sant(mac.equals(blob.subarray(blob.length - 32)), "mac");
  const d = createDecipheriv("aes-256-cbc", kEnc, blob.subarray(4, 20));
  const klar = Buffer.concat([d.update(blob.subarray(20, blob.length - 32)), d.final()]);
  lika(klar.toString(), new TextDecoder().decode(data));
  // och tillbaka med visaren
  lika(new TextDecoder().decode(await dekryptera(new Uint8Array(blob), new Uint8Array(nyckel))), new TextDecoder().decode(data));
});

test("länken: fragment, saknad/ogiltig nyckel", async () => {
  const k = Buffer.from(randomBytes(32)).toString("base64url");
  lika(lasFragment(`#d=abcdefghijklmnopqrstuv&k=${k}&c=xyz`), { d: "abcdefghijklmnopqrstuv", k, c: "xyz" });
  const t = tolkaLank(lasFragment(`#d=abcdefghijklmnopqrstuv&k=${k}`));
  lika(t.nyckel.length, 32);
  await kastar(() => tolkaLank(lasFragment("#d=abcdefghijklmnopqrstuv")), "ingen-nyckel");
  await kastar(() => tolkaLank(lasFragment("#d=abcdefghijklmnopqrstuv&k=kort")), "fel-nyckel");
  await kastar(() => tolkaLank(lasFragment("#d=abcdefghijklmnopqrstuv&k=!!!")), "fel-nyckel");
  await kastar(() => tolkaLank(lasFragment(`#k=${k}`)), "ogiltig-lank");
  await kastar(() => tolkaLank(lasFragment(`#d=../../etc&k=${k}`)), "ogiltig-lank");
});

test("hämtning: 404 → borttagen, nätverksfel, relativ sökväg utan fragment", async () => {
  let url = null, opt = null;
  const svara = (status) => async (u, o) => { url = u; opt = o; return { status, ok: status < 300, arrayBuffer: async () => new ArrayBuffer(4) }; };
  await kastar(() => hamtaPaket("abcdefghijklmnopqrstuv", { hamta: svara(404) }), "borttagen");
  lika(url, "../d/abcdefghijklmnopqrstuv.skd");
  lika(opt.referrerPolicy, "no-referrer");
  await kastar(() => hamtaPaket("abcdefghijklmnopqrstuv", { hamta: async () => { throw new TypeError("x"); } }), "natverk");
  await kastar(() => hamtaPaket("abcdefghijklmnopqrstuv", { hamta: svara(500) }), "natverk");
  lika((await hamtaPaket("abcdefghijklmnopqrstuv", { hamta: svara(200) })).length, 4);
});

// ---------- kommentarer ----------

test("svarslänk: kodning och avkodning", async () => {
  const k1 = nyKommentar({ text: "Här är det för tunt", punkt: [1.23456, -2, 3], del: "lada", kropp: null });
  const k2 = nyKommentar({ text: "Åäö – \"citat\" & <tagg>", punkt: [0, 0, 0], del: "fotter", kropp: 2 });
  const data = brevData("Anna", [k1, { ...k2, skickad: "x" }]);
  lika(Object.keys(data.kommentarer[1]).sort(), ["del", "id", "kropp", "punkt", "text", "tid"]);
  lika(k1.punkt, [1.235, -2, 3]);
  const lank = await svarslank("https://x.example/visare/", "abcdefghijklmnopqrstuv", "NYCKEL", data);
  const f = lasFragment(new URL(lank).hash);
  lika(f.d, "abcdefghijklmnopqrstuv"); lika(f.k, "NYCKEL");
  const ut = await avkodaSvar(f.c);
  lika(ut.fran, "Anna");
  lika(ut.kommentarer, data.kommentarer);
  // node kan läsa c= (som dela.py las_svarslank)
  lika(JSON.parse(gunzipSync(Buffer.from(f.c, "base64url")).toString()), data);
  // trasiga poster sorteras bort
  const smutsig = await kodaSvar({ fran: 5, kommentarer: [{ text: "ok", punkt: [1, 2, 3] }, { text: "nej", punkt: [1, 2] }, null, { punkt: [1, 2, 3] }] });
  const s = await avkodaSvar(smutsig);
  lika(s.fran, null); lika(s.kommentarer.length, 1);
});

test("brev till brevlådan: SKD1(gzip(JSON)) och POST", async () => {
  const nyckel = new Uint8Array(randomBytes(32));
  const data = brevData("Bo", [nyKommentar({ text: "x", punkt: [1, 2, 3], del: "a" })]);
  const blob = await brevBlob(data, nyckel);
  lika(JSON.parse(new TextDecoder().decode(gunzipSync(await dekryptera(blob, nyckel)))), data);
  let anrop = null;
  await skickaBrev("https://b.example/b/abc", blob, async (u, o) => { anrop = { u, o }; return { ok: true, status: 201 }; });
  lika(anrop.o.method, "POST"); lika(anrop.o.headers["Content-Type"], "application/octet-stream"); lika(anrop.o.referrerPolicy, "no-referrer");
  await kastar(() => skickaBrev("https://b.example/b/abc", blob, async () => ({ ok: false, status: 404 })));
  await kastar(() => skickaBrev("http://b.example/b/abc", blob, async () => ({ ok: true })));
  await kastar(() => skickaBrev("https://b.example/b/abc", new Uint8Array(70000), async () => ({ ok: true })));
});

test("lagring per delning", () => {
  const minne = new Map();
  const lagring = { getItem: (k) => minne.get(k) ?? null, setItem: (k, v) => minne.set(k, v) };
  lika(lasLagrat("x", lagring), { namn: "", kommentarer: [] });
  const k = nyKommentar({ text: "a", punkt: [1, 2, 3], del: "d" });
  sant(sparaLagrat("x", { namn: "Cia", kommentarer: [k] }, lagring));
  lika(lasLagrat("x", lagring).kommentarer[0].text, "a");
  lika(lasLagrat("y", lagring).kommentarer.length, 0);
  const trasig = { getItem: () => { throw new Error("blockerad"); }, setItem: () => { throw new Error("full"); } };
  lika(lasLagrat("x", trasig).kommentarer.length, 0);
  lika(sparaLagrat("x", {}, trasig), false);
});

// ---------- modell och träd ----------

const TESTLADA = join(REPO, "tester", ".bygg", "Testlåda");

test("Testlåda: paket → modell", () => {
  if (!existsSync(join(TESTLADA, "cad", "delar.json"))) { console.log("    (hoppar över: tester/.bygg/Testlåda saknas)"); return; }
  const m = byggModell(packa(TESTLADA));
  lika(m.delar.map((d) => d.id), ["fotter", "insats", "lock", "lada"]);
  lika(m.blad.map((l) => l.id), ["fotter#0", "fotter#1", "fotter#2", "fotter#3", "insats", "lock", "lada"]);
  lika(m.delAv.get("insats").foralder, "lada");
  nara(m.bladAv.get("fotter#1").lo, [-28, -18, -6], 1e-3);
  nara(m.bladAv.get("lada").hi, [30, 20, 20], 1e-3);
  sant(m.bladAv.get("lada").kanter.length === 24 && m.bladAv.get("fotter#0").kanter.length === 3, "kanter per kropp");
  const r = tradRader(m, new Set());
  lika(r.map((x) => [x.nyckel, x.indrag, x.sub]), [["fotter", 0, "4 kroppar"], ["lock", 0, "Lock ovanför"], ["lada", 0, "+ Insats"]]);
  const r2 = tradRader(m, new Set(["lada", "fotter"]));
  lika(r2.map((x) => x.nyckel), ["fotter", "fotter#0", "fotter#1", "fotter#2", "fotter#3", "lock", "lada", "insats"]);
  lika(r2.find((x) => x.nyckel === "lada").sub, "Testlådan");
  // insats följer lådan i sprängvyn när lådan är hopfälld, går själv när den är utfälld
  lika(sprangGrupp(m, m.bladAv.get("insats"), new Set()), "lada");
  lika(sprangGrupp(m, m.bladAv.get("insats"), new Set(["lada"])), "insats");
  lika(sprangGrupp(m, m.bladAv.get("fotter#2"), new Set()), "fotter");
  lika(sprangGrupp(m, m.bladAv.get("fotter#2"), new Set(["fotter"])), "fotter#2");
  // släckt förälder släcker barnet
  sant(!synlig(m, m.bladAv.get("insats"), new Set(["lada"])));
});

test("trädet: komponentgrupper, ögon, vald rad", () => {
  const m = byggModell(paket([
    del("ram", [
      [[0, 0, 0], [1, 1, 1], { namn: "Skruv 1", grupp: ["Fäste", "Skruvar"] }],
      [[2, 0, 0], [3, 1, 1], { namn: "Skruv 2", grupp: ["Fäste", "Skruvar"] }],
      [[4, 0, 0], [5, 1, 1], { namn: "Platta", grupp: ["Fäste"] }],
      [[6, 0, 0], [7, 1, 1], { namn: "Lös" }],
    ], { roll: "referens" }),
    del("lock", [[[0, 0, 5], [7, 1, 6]]]),
  ]));
  let r = tradRader(m, new Set());
  lika(r.map((x) => x.nyckel), ["#referens", "ram", "#konstruktion", "lock"]);
  const gF = gruppNyckel("ram", ["Fäste"]), gS = gruppNyckel("ram", ["Fäste", "Skruvar"]);
  r = tradRader(m, new Set(["ram", gF, gS]));
  lika(r.map((x) => [x.nyckel, x.typ, x.indrag ?? null]), [
    ["#referens", "rubrik", null], ["ram", "del", 0], [gF, "grupp", 1], [gS, "grupp", 2], ["ram#0", "kropp", 3], ["ram#1", "kropp", 3],
    ["ram#2", "kropp", 2], ["ram#3", "kropp", 1], ["#konstruktion", "rubrik", null], ["lock", "del", 0]]);
  const grupp = r.find((x) => x.nyckel === gF);
  lika(grupp.ogon, ["ram#0", "ram#1", "ram#2"]); lika(grupp.sub, "3 kroppar");
  let dolda = vaxlaOga(grupp, new Set());
  lika([...dolda].sort(), ["ram#0", "ram#1", "ram#2"]);
  sant(!radTand(grupp, dolda));
  dolda = vaxlaOga(grupp, new Set(["ram#0"]));            // en tänd → släck alla
  lika(dolda.size, 3);
  dolda = vaxlaOga(grupp, dolda);                           // alla släckta → tänd alla
  lika(dolda.size, 0);
  // vald rad: kropp 1 under hopfällda grupper visas på delen; utfällt ända ner visas kroppen
  const val = { del: "ram", objekt: "ram#1" };
  lika(valdStig(m, val), ["ram", gF, gS, "ram#1"]);
  lika(valdRad(m, val, new Set()), "ram");
  lika(valdRad(m, val, new Set(["ram"])), gF);
  lika(valdRad(m, val, new Set(["ram", gF, gS])), "ram#1");
  lika([...fallUtTillValt(m, val, new Set())].sort(), ["ram", gF, gS].sort());
  // sprängenheter följer grupperna
  const b1 = m.bladAv.get("ram#1"), b3 = m.bladAv.get("ram#3");
  lika(sprangGrupp(m, b1, new Set()), "ram");
  lika(sprangGrupp(m, b1, new Set(["ram"])), gF);
  lika(sprangGrupp(m, b1, new Set(["ram", gF])), gS);
  lika(sprangGrupp(m, b1, new Set(["ram", gF, gS])), "ram#1");
  lika(sprangGrupp(m, b3, new Set(["ram"])), "ram#3");
});

test("kroppar ur hörn när 'kropp' saknas, och härledda kanter", () => {
  const ytor = [...lada([0, 0, 0], [1, 1, 1], 0), ...lada([5, 0, 0], [6, 1, 1], 6)].map(({ kropp, ...f }) => f);
  const m = byggModell(paket([{ id: "x", namn: "X", farg: "#ff0000", ytor }]));
  lika(m.blad.map((l) => l.id), ["x#0", "x#1"]);
  lika(m.bladAv.get("x#1").ytIds, [6, 7, 8, 9, 10, 11]);
  // en kub utan kanter i filen: 12 raka kanter
  lika(m.bladAv.get("x#0").kanter.length, 12);
  sant(m.bladAv.get("x#0").kanter.every((e) => e.typ === "linje" && Math.abs(e.langd - 1) < 1e-6));
  lika(harledKanter(lada([0, 0, 0], [2, 3, 4])).map((e) => Math.round(e.langd)).sort(), [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]);
});

test("nätdel (skanning) utan ytor", () => {
  const m = byggModell(paket([{ id: "skanning", namn: "Skanning", farg: "#9AA4AE", dold: true, nat: { v: [0, 0, 0, 1, 0, 0, 0, 1, 0], t: [0, 1, 2] } }]));
  lika(m.blad.length, 1); lika(m.blad[0].ytIds, []); lika([...m.blad[0].nat.triYta], [-1]);
  const h = stralMotModell(m.blad, new Map(), () => true, [0.2, 0.2, 5], [0, 0, -1]);
  lika(h.yta, null); nara(h.lokal, [0.2, 0.2, 0]);
});

// ---------- sprängvy ----------

test("sprängvyn: två lådor (handräknat)", () => {
  const m = byggModell(paket([del("A", [[[0, 0, 0], [10, 10, 10]]]), del("B", [[[20, 0, 0], [30, 10, 10]]])]));
  const S = Math.sqrt(30 * 30 + 10 * 10 + 10 * 10) / 2;           // synligas halva diagonal = 16,583
  const { centrum, storlek } = synligaMatt(m, new Set());
  nara(centrum, [15, 5, 5]); nara(storlek, S);
  // A: mitt (5,5,5), d = (−10,0,0), l = 10 < S → |e| = t·(0,4·S + 0,5·l)
  const e = 0.4 * S + 0.5 * 10;                                    // 11,633
  nara(placeraBlad(m, tomt()).get("A"), [-e, 0, 0], 1e-9);
  nara(placeraBlad(m, tomt()).get("B"), [e, 0, 0], 1e-9);
  nara(placeraBlad(m, { ...tomt(), t: 0.5 }).get("B"), [e / 2, 0, 0], 1e-9);
  nara(placeraBlad(m, { ...tomt(), t: 0 }).get("B"), [0, 0, 0]);
  // B släckt: A är ensam synlig, ligger i mitten → ingen förskjutning; släckta står kvar
  const b = placeraBlad(m, { ...tomt(), dolda: new Set(["B"]) });
  nara(b.get("A"), [0, 0, 0]); nara(b.get("B"), [0, 0, 0]);
  // explodeVector direkt: l > storlek → rel = 1
  nara(explodeVector(true, [100, 0, 0], [0, 0, 0], 10, 1), [10 * 0.9, 0, 0]);
  nara(explodeVector(false, [100, 0, 0], [0, 0, 0], 10, 1), [0, 0, 0]);
  nara(explodeVector(true, [0, 0, 0.0005], [0, 0, 0], 10, 1), [0, 0, 0]);
});

test("sprängvyn: hopfälld del sprängs som en enhet (handräknat)", () => {
  const m = byggModell(paket([
    del("P", [[[0, 0, 0], [10, 10, 10]], [[20, 0, 0], [30, 10, 10]]]),
    del("Q", [[[0, 0, 40], [30, 10, 50]]]),
  ]));
  const S = Math.sqrt(30 * 30 + 10 * 10 + 50 * 50) / 2;           // 29,580
  // hopfälld: P:s mitt (15,5,5), centrum (15,5,25) → d = (0,0,−20)
  const e = 0.4 * S + 0.5 * 20;
  const h = placeraBlad(m, tomt());
  nara(h.get("P#0"), [0, 0, -e], 1e-9); nara(h.get("P#1"), [0, 0, -e], 1e-9); nara(h.get("Q"), [0, 0, e], 1e-9);
  // utfälld: P#0 mitt (5,5,5) → d = (−10,0,−20), l = √500
  const l = Math.sqrt(500), k = (0.4 * S + 0.5 * l) / l;
  const u = placeraBlad(m, { ...tomt(), utfallda: new Set(["P"]) });
  nara(u.get("P#0"), [-10 * k, 0, -20 * k], 1e-9);
  nara(u.get("P#1"), [10 * k, 0, -20 * k], 1e-9);
  nara(u.get("Q"), [0, 0, e], 1e-9);
  // flytt: delens flytt + kroppens flytt, sprängflytt skalas med t
  const lg = { ...tomt(), t: 0.5, flytt: new Map([["P", [1, 0, 0]], ["P#1", [0, 2, 0]]]), sprangFlytt: new Map([["P", [0, 0, 4]], ["Q", [6, 0, 0]]]) };
  const f = placeraBlad(m, lg);
  nara(f.get("P#1"), [1, 2, -e / 2 + 2], 1e-9);
  nara(f.get("P#0"), [1, 0, -e / 2 + 2], 1e-9);
  nara(f.get("Q"), [3, 0, e / 2], 1e-9);
});

test("sprängvyn: barndel följer hopfälld förälder", () => {
  const m = byggModell(paket([
    del("bas", [[[0, 0, 0], [10, 10, 10]]]),
    del("barn", [[[0, 0, 10], [10, 10, 12]]], { foralder: "bas" }),
    del("annan", [[[0, 0, 30], [10, 10, 40]]]),
  ]));
  const h = placeraBlad(m, tomt());
  nara(h.get("bas"), h.get("barn"), 1e-9, "samma förskjutning");
  const u = placeraBlad(m, { ...tomt(), utfallda: new Set(["bas"]) });
  sant(Math.abs(u.get("bas")[2] - u.get("barn")[2]) > 1, "isär när utfälld");
});

test("flytta: dra en del, i sprängvyn skalat med t", () => {
  const m = byggModell(paket([del("P", [[[0, 0, 0], [1, 1, 1]], [[3, 0, 0], [4, 1, 1]]]), del("Q", [[[0, 0, 5], [1, 1, 6]]])]));
  const lg = { ...tomt(), t: 0 };
  const d = borjaDra(m, m.bladAv.get("P#1"), lg);
  lika(d.nyckel, "P");                       // hopfälld del: hela delen följer med
  dra(d, [1, 2, 3], lg);
  lika(lg.flytt.get("P"), [1, 2, 3]);
  const lg2 = { ...tomt(), t: 0.5, utfallda: new Set(["P"]) };
  const d2 = borjaDra(m, m.bladAv.get("P#1"), lg2);
  lika(d2.nyckel, "P#1");
  dra(d2, [1, 0, 0], lg2);
  lika(lg2.sprangFlytt.get("P#1"), [2, 0, 0]);
  lika(borjaDra(m, m.bladAv.get("P#1"), lg2, true).nyckel, "P");   // ⌥: hela delen
});

// ---------- strålkastning ----------

test("strålkastning mot en kub", () => {
  const m = byggModell(paket([del("k", [[[0, 0, 0], [10, 10, 10]]])]));
  const leaf = m.blad[0];
  const h = stralMotModell(m.blad, new Map(), () => true, [5, 5, 100], [0, 0, -1]);
  nara(h.t, 90); lika(h.yta, 1); nara(h.lokal, [5, 5, 10]);
  const s = stralMotModell(m.blad, new Map(), () => true, [-50, 3, 4], [1, 0, 0]);
  nara(s.t, 50); lika(s.yta, 4);
  lika(stralMotModell(m.blad, new Map(), () => true, [20, 20, 100], [0, 0, -1]), null);
  lika(stralMotModell(m.blad, new Map(), () => false, [5, 5, 100], [0, 0, -1]), null);
  // förskjuten del: träffen i världen, "lokal" i modellens koordinater
  const f = stralMotModell(m.blad, new Map([["k", [100, 0, 0]]]), () => true, [105, 5, 100], [0, 0, -1]);
  nara(f.varld, [105, 5, 10]); nara(f.lokal, [5, 5, 10]);
  // inifrån: närmaste vägg framför
  nara(stralMotModell(m.blad, new Map(), () => true, [5, 5, 5], [0, 0, 1]).t, 5);
  nara(stralMotModell(m.blad, new Map(), () => true, [5, 5, 50], [0, 0, -1], 30), null);   // tmax
  sant(leaf.bvh, "BVH byggd");
});

test("BVH ger samma träffar som att pröva alla trianglar", () => {
  // en skrynklig yta med många trianglar
  const N = 40, v = [], t = [];
  for (let j = 0; j <= N; j++) for (let i = 0; i <= N; i++) v.push(i, j, Math.sin(i * 0.7) * Math.cos(j * 0.5) * 3);
  for (let j = 0; j < N; j++) for (let i = 0; i < N; i++) { const a = j * (N + 1) + i; t.push(a, a + 1, a + N + 2, a, a + N + 2, a + N + 1); }
  const pos = new Float32Array(v), idx = new Uint32Array(t);
  const bvh = byggBVH(pos, idx);
  let slump = 12345;
  const r = () => ((slump = (slump * 1103515245 + 12345) % 2147483648) / 2147483648);
  for (let k = 0; k < 300; k++) {
    const o = [r() * 50 - 5, r() * 50 - 5, 20 + r() * 10], d = [r() - 0.5, r() - 0.5, -1];
    let bast = Infinity;
    for (let i = 0; i < idx.length / 3; i++) bast = Math.min(bast, triangelTraff(pos, idx[3 * i], idx[3 * i + 1], idx[3 * i + 2], o, d));
    const h = stralBVH(bvh, o, d);
    if (bast === Infinity) lika(h, null, `stråle ${k}`); else nara(h.t, bast, 1e-9, `stråle ${k}`);
  }
});

// ---------- fäste och mätning ----------

test("fäste mot hörn och kant, mätning dx/dy/dz", () => {
  const m = byggModell(paket([del("k", [[[0, 0, 0], [10, 10, 10]]])]));
  const leaf = m.blad[0];
  const punkter = fastpunkter(leaf, m.delAv.get("k"));
  sant(punkter.filter((p) => p.typ === "hörn").length === 24 && punkter.filter((p) => p.typ === "kantmitt").length === 12
    && punkter.filter((p) => p.typ === "ytcentrum").length === 6, "fästpunkter");
  // ovanifrån, 10 px per mm, origo i (100,100) – y nedåt
  const proj = (p) => [100 + p[0] * 10, 100 - p[1] * 10, 100 - p[2]];
  const blad = [{ leaf, forskjutning: [0, 0, 0], punkter }];
  const aldrig = () => false;
  // nära hörnet (10,10,·): fäster
  const h = matFaste(blad, proj, [203, 3], aldrig);
  lika(h.typ, "hörn"); nara(h.lokal.slice(0, 2), [10, 10]);
  // mitt på en kant, långt från hörn och kantmitt: punkt på kanten
  const k = matFaste(blad, proj, [130, 2], aldrig);
  lika(k.typ, "på kanten"); nara(k.lokal.slice(0, 2), [3, 10], 1e-6);
  // mitt i ytan: ytcentrum ligger inom 5 px
  lika(matFaste(blad, proj, [151, 51], aldrig).typ, "ytcentrum");
  // långt från allt: inget fäste
  lika(matFaste(blad, proj, [170, 75], aldrig), null);
  // skymda hörn hoppas över
  const z0 = matFaste(blad, proj, [203, 3], (p) => p[2] > 5);
  sant(z0 && z0.varld[2] === 0, "tar det oskymda hörnet");
  // förskjuten del
  const fl = fastKandidater([{ leaf, forskjutning: [5, 0, 0], punkter }], proj, [253, 3], 5);
  nara(fl[0].varld.slice(0, 2), [15, 10]); nara(fl[0].lokal.slice(0, 2), [10, 10]);
  lika(kantKandidater(blad, proj, [150, 50], 8).length, 0);
  const mm = matt([0, 0, 0], [3, -4, 12]);
  nara([mm.avstand, mm.dx, mm.dy, mm.dz], [13, 3, -4, 12]);
  lika(tal(-1.25, 1), "−1,3"); lika(tal(-0.01, 1), "0,0"); lika(tal(12.5, 2), "12,50");
});

test("ytinfo: typ, area, radie/diameter", () => {
  lika(ytInfo({ typ: "cylinder", area: 94.25, radie: 3 }), [["Yta", "Cylinder"], ["Area", "94,25 mm²"], ["Radie", "3,00 mm"], ["Diameter", "⌀ 6,00 mm"]]);
  lika(ytInfo({ typ: "plan", area: 800, normal: [0, 0, 1] })[1], ["Area", "800,0 mm²"]);
});

// ---------- kamera ----------

test("kamera: projektion och stråle hör ihop, standardvyer", () => {
  const k = new Kamera();
  k.radie = 50;
  k.passaIn([1, 2, 3], 50, 800, 600);
  for (const orto of [null, "Topp"]) {
    k.orto = orto;
    for (const [x, y] of [[400, 300], [10, 20], [790, 590]]) {
      const s = k.stråle(x, y, 800, 600);
      const p = [0, 1, 2].map((i) => s.o[i] + s.d[i] * (k.dist + (orto ? 400 : 0)));
      const q = k.projicera(p, 800, 600);
      nara(q.slice(0, 2), [x, y], 1e-6, `orto=${orto}`);
    }
  }
  nara(k.projicera([1, 2, 3], 800, 600).slice(0, 2), [400, 300], 1e-9);
  k.standardvy("Topp", [0, 0, 0], 10, 800, 600);
  const b = k.bas();
  nara(b.bak, [0, 0, 1], 1e-9); nara(b.upp, [0, 1, 0], 1e-9); nara(b.hoger, [1, 0, 0], 1e-9);
  k.standardvy("−Y", [0, 0, 0], 10, 800, 600);
  nara(k.bas().upp, [0, 0, 1], 1e-9); nara(k.bas().hoger, [1, 0, 0], 1e-9);
  // zoom mot en punkt håller punkten stilla på skärmen
  k.standardvy("Persp", [0, 0, 0], 10, 800, 600);
  const p = [3, -2, 1], fore = k.projicera(p, 800, 600);
  k.zooma(0.5, p);
  nara(k.projicera(p, 800, 600).slice(0, 2), fore.slice(0, 2), 1e-6);
});

// ---------- kör ----------

for (const [namn, fn] of grupper) {
  try { await fn(); ok++; console.log(`  ok   ${namn}`); } catch (e) { fel++; console.log(`  FEL  ${namn}\n       ${e.stack.split("\n").slice(0, 3).join("\n       ")}`); }
}
console.log(`\n${ok} ok, ${fel} fel`);
process.exit(fel ? 1 : 0);
