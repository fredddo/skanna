#!/usr/bin/env node
// Gör ett testpaket enligt PLAN-webbvisare.md ur en projektmapps cad/ (delar.json + *-ytor.json), krypterar det i SKD1
// med node:crypto och skriver <ut>/d/<id>.skd. Länkar <ut>/visare → webb/visare (symlänk) och skriver ut länken.
// (Den riktiga exporten är cad/dela.py – det här skriptet är bara för test av visaren.)
//
//   node webb/visare/test/gor-paket.mjs <projekt> <ut> [--med skanning,<delid>] [--fran Namn] [--brevlada URL]
//                                       [--bas http://127.0.0.1:8765/visare/] [--id ID --nyckel NYCKEL]
import { createCipheriv, createHash, createHmac, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const b64url = (b) => Buffer.from(b).toString("base64url");

export function krypteraSKD1(data, nyckel, iv = randomBytes(16)) {
  const kEnc = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-enc")])).digest();
  const kMac = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-mac")])).digest();
  const c = createCipheriv("aes-256-cbc", kEnc, iv);
  const chiffer = Buffer.concat([c.update(data), c.final()]);
  const kropp = Buffer.concat([Buffer.from("SKD1"), iv, chiffer]);
  return Buffer.concat([kropp, createHmac("sha256", kMac).update(kropp).digest()]);
}

/** STL (binär eller ascii) → {v, t} med sammanslagna hörn (bara för test av nätdelar). */
function lasSTL(buf) {
  const v = [], t = [], index = new Map();
  const hörn = (x, y, z) => {
    const k = `${x.toFixed(4)},${y.toFixed(4)},${z.toFixed(4)}`;
    if (!index.has(k)) { index.set(k, v.length / 3); v.push(+x.toFixed(4), +y.toFixed(4), +z.toFixed(4)); }
    return index.get(k);
  };
  const n = buf.length >= 84 ? buf.readUInt32LE(80) : 0;
  if (buf.length === 84 + n * 50) {
    for (let i = 0; i < n; i++) {
      const o = 84 + i * 50 + 12;
      for (let j = 0; j < 3; j++) t.push(hörn(buf.readFloatLE(o + j * 12), buf.readFloatLE(o + j * 12 + 4), buf.readFloatLE(o + j * 12 + 8)));
    }
  } else {
    for (const m of buf.toString("utf8").matchAll(/vertex\s+(\S+)\s+(\S+)\s+(\S+)/g)) t.push(hörn(+m[1], +m[2], +m[3]));
  }
  return { v, t };
}

export function packa(projekt, { med = [], fran = null, brevlada = null } = {}) {
  const cad = join(projekt, "cad");
  const delar = JSON.parse(readFileSync(join(cad, "delar.json"), "utf8")).delar || [];
  let objekt = {};
  try { objekt = JSON.parse(readFileSync(join(cad, "objekt.json"), "utf8")); } catch { /* inget sparat läge */ }
  const dolda = new Set(objekt.dolda || []), borttagna = new Set(objekt.borttagna || []), namn = objekt.namn || {};
  const rang = new Map((objekt.ordning || []).map((id, i) => [id, i]));
  const ordnade = delar.filter((d) => !borttagna.has(d.id)).map((d, i) => [rang.get(d.id) ?? 100000 + i, d]).sort((a, b) => a[0] - b[0]).map((x) => x[1]);
  const ut = [];
  for (const d of ordnade) {
    const fil = d.fil || "";
    const post = { id: d.id, namn: namn[d.id] || d.namn || d.id, farg: d.farg || "#9AA4AE", foralder: d.foralder || null, roll: d.roll || null,
      dold: dolda.has(d.id) };
    if (d.beskrivning) post.beskrivning = d.beskrivning;
    if (fil.endsWith(".json")) {
      const p = join(cad, fil);
      if (!existsSync(p)) continue;
      const y = JSON.parse(readFileSync(p, "utf8"));
      Object.assign(post, { ytor: y.ytor || [], kanter: y.kanter || [], kroppar: y.kroppar || [] });
    } else if (/\.(stl|obj|3mf)$/i.test(fil)) {
      if (!med.includes(d.id) || !fil.toLowerCase().endsWith(".stl")) continue;
      post.nat = lasSTL(readFileSync(join(cad, fil)));
    } else continue;
    ut.push(post);
  }
  if (med.includes("skanning")) {
    const stl = readdirSync(projekt).find((f) => f.toLowerCase().endsWith(".stl"));
    if (stl) ut.push({ id: "skanning", namn: "Skanning", farg: "#9AA4AE", nat: lasSTL(readFileSync(join(projekt, stl))), dold: true });
  }
  const projNamn = projekt.replace(/\/+$/, "").split("/").pop().replace(/\.(modell|skanning)$/, "");
  return { version: 1, namn: projNamn, skapad: new Date().toISOString(), enhet: "mm", fran, brevlada, delar: ut };
}

function main(argv) {
  const pos = [], opt = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) opt[argv[i].slice(2)] = argv[++i]; else pos.push(argv[i]);
  }
  if (pos.length < 2) {
    console.error("Användning: gor-paket.mjs <projekt> <ut> [--med skanning,id] [--fran Namn] [--brevlada URL] [--bas URL] [--id ID --nyckel NYCKEL]");
    process.exit(2);
  }
  const [projekt, utMapp] = pos.map((p) => resolve(p));
  const id = opt.id || b64url(randomBytes(16));
  const brevlada = opt.brevlada ? opt.brevlada.replace("{id}", id) : null;   // t.ex. http://127.0.0.1:8766/b/{id}
  const paket = packa(projekt, { med: (opt.med || "").split(",").filter(Boolean), fran: opt.fran || null, brevlada });
  const nyckel = opt.nyckel ? Buffer.from(opt.nyckel, "base64url") : randomBytes(32);
  const klar = gzipSync(Buffer.from(JSON.stringify(paket)));
  mkdirSync(join(utMapp, "d"), { recursive: true });
  writeFileSync(join(utMapp, "d", `${id}.skd`), krypteraSKD1(klar, nyckel));
  const visare = join(utMapp, "visare");
  if (!existsSync(visare)) symlinkSync(resolve(dirname(fileURLToPath(import.meta.url)), ".."), visare, "dir");
  const bas = opt.bas || "http://127.0.0.1:8765/visare/";
  console.error(`${paket.delar.length} delar, ${(klar.length / 1024).toFixed(0)} kB gzip → ${join(utMapp, "d", id + ".skd")}`);
  console.log(`${bas}#d=${id}&k=${b64url(nyckel)}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
