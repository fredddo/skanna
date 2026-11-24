#!/usr/bin/env node
// En liten låtsasbrevlåda för att prova "Skicka kommentarer" lokalt (samma API som brevlada/ i planen, i minnet).
// Avkrypterar och skriver ut varje brev om nyckeln anges.
//   node webb/visare/test/brevlada-prov.mjs [--port 8766] [--nyckel <nyckel ur länken>]
import { createDecipheriv, createHash, createHmac, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { gunzipSync } from "node:zlib";

const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; };
const port = +arg("port", 8766);
const nyckel = arg("nyckel") ? Buffer.from(arg("nyckel"), "base64url") : null;
const lador = new Map();

function oppna(blob) {
  const kEnc = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-enc")])).digest();
  const kMac = createHash("sha256").update(Buffer.concat([nyckel, Buffer.from("skanna-mac")])).digest();
  const mac = createHmac("sha256", kMac).update(blob.subarray(0, blob.length - 32)).digest();
  if (!timingSafeEqual(mac, blob.subarray(blob.length - 32))) return "(fel mac)";
  const d = createDecipheriv("aes-256-cbc", kEnc, blob.subarray(4, 20));
  return gunzipSync(Buffer.concat([d.update(blob.subarray(20, blob.length - 32)), d.final()])).toString();
}

createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  const m = /^\/b\/([A-Za-z0-9_-]{22})$/.exec(req.url);
  if (req.method === "OPTIONS") { res.writeHead(204).end(); return; }
  if (!m) { res.writeHead(404).end(); return; }
  const id = m[1];
  const delar = [];
  req.on("data", (d) => delar.push(d));
  req.on("end", () => {
    const kropp = Buffer.concat(delar);
    if (req.method === "PUT") { lador.set(id, lador.get(id) || []); res.writeHead(201).end(); return; }
    if (req.method === "GET") { res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ brev: (lador.get(id) || []).map((b) => ({ tid: b.tid, data: b.data.toString("base64") })) })); return; }
    if (req.method !== "POST") { res.writeHead(405).end(); return; }
    // provbrevlådan öppnar lådan själv vid första brevet (den riktiga kräver PUT från ägaren)
    if (!lador.has(id)) lador.set(id, []);
    if (kropp.length > 64 * 1024) { res.writeHead(413).end(); return; }
    if (lador.get(id).length >= 200) { res.writeHead(429).end(); return; }
    lador.get(id).push({ tid: new Date().toISOString(), data: kropp });
    console.log(`brev till ${id}: ${kropp.length} byte ${kropp.subarray(0, 4)}`);
    if (nyckel) console.log(oppna(kropp));
    res.writeHead(201).end();
  });
}).listen(port, "127.0.0.1", () => console.log(`provbrevlåda på http://127.0.0.1:${port}/b/<id>`));
