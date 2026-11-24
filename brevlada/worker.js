// Brevlådan som Cloudflare Worker – samma API som brevlada/server.py (se PLAN-webbvisare.md, "Brevlådan").
//
//   PUT    /b/<id>  + X-Brevlada-Hemlig   öppnar en låda
//   POST   /b/<id>  kropp: SKD1-blob       lägger ett brev (404 om lådan saknas, 429 efter 200 brev)
//   GET    /b/<id>  + X-Brevlada-Hemlig   {"brev": [{"tid": "…", "data": "<base64>"}]}
//   DELETE /b/<id>  + X-Brevlada-Hemlig   tar bort lådan och breven
//   OPTIONS /b/<id>                        CORS för webbläsaren
//
// Bindningar: KV-namnrymd BREV, secret BREVLADA_HEMLIG (minst 24 tecken), valfritt MAX_LADOR (standard 1000).
// Nycklar i KV: "l:<id>" = lådan finns, "b:<id>:<tid>-<slump>" = ett brev (bytes, tid i metadata).
// OBS: KV är bara "till slut konsistent", så 200-gränsen och lådgränsen är ungefärliga vid många samtidiga brev.
// Inget innehåll loggas.

const ID_FORM = /^\/b\/([A-Za-z0-9_-]{22})$/;
const MAX_KROPP = 64 * 1024;
const MAX_BREV = 200;
const MAX_LADOR = 1000;
const MIN_HEMLIG = 24;
const MAGI = [0x53, 0x4b, 0x44, 0x31]; // "SKD1"

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

class Fel extends Error {
  constructor(kod, text) {
    super(text);
    this.kod = kod;
  }
}

function svar(kod, data, cors) {
  const h = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...(cors ? CORS : {}) };
  if (data === null) return new Response(null, { status: kod, headers: h });
  h["Content-Type"] = "application/json; charset=utf-8";
  return new Response(JSON.stringify(data), { status: kod, headers: h });
}

async function sha256(text) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

// jämförelse i konstant tid: hasha båda (lika långa) och jämför alla byte
async function lika(a, b) {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

async function kravHemlig(req, env) {
  const hemlig = env.BREVLADA_HEMLIG || "";
  if (hemlig.length < MIN_HEMLIG) throw new Fel(500, "tjänsten saknar hemlighet");
  if (!(await lika(req.headers.get("X-Brevlada-Hemlig") || "", hemlig))) {
    throw new Fel(401, "fel eller saknad hemlighet");
  }
}

// läser högst MAX_KROPP byte ur strömmen; mer än så avbryts utan att resten läses
async function lasKropp(req) {
  const n = req.headers.get("Content-Length");
  if (n !== null && Number(n) > MAX_KROPP) throw new Fel(413, "brevet är för stort");
  if (!req.body) return new Uint8Array(0);
  const lasare = req.body.getReader();
  const delar = [];
  let langd = 0;
  for (;;) {
    const { done, value } = await lasare.read();
    if (done) break;
    langd += value.byteLength;
    if (langd > MAX_KROPP) {
      try { await lasare.cancel(); } catch (_) { /* ignoreras */ }
      throw new Fel(413, "brevet är för stort");
    }
    delar.push(value);
  }
  const ut = new Uint8Array(langd);
  let pos = 0;
  for (const d of delar) { ut.set(d, pos); pos += d.byteLength; }
  return ut;
}

async function listaAlla(kv, prefix, max) {
  const nycklar = [];
  let cursor;
  for (;;) {
    const r = await kv.list({ prefix, cursor });
    nycklar.push(...r.keys);
    if (r.list_complete || (max !== undefined && nycklar.length >= max)) return nycklar;
    cursor = r.cursor;
  }
}

function base64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

// löpnummer inom denna instans, så att brev som kommer samma millisekund behåller ordningen
let lopnr = 0;

function slump() {
  const b = crypto.getRandomValues(new Uint8Array(4));
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

async function oppna(id, env) {
  if (await env.BREV.get("l:" + id) !== null) return svar(200, { ok: true });
  const max = Number(env.MAX_LADOR) || MAX_LADOR;
  if ((await listaAlla(env.BREV, "l:", max)).length >= max) throw new Fel(507, "för många brevlådor");
  await env.BREV.put("l:" + id, new Date().toISOString());
  return svar(201, { ok: true });
}

async function lagg(id, req, env) {
  const data = await lasKropp(req);
  if (data.length < 4 || MAGI.some((x, i) => data[i] !== x)) throw new Fel(400, "brevet ska vara ett SKD1-paket");
  if (await env.BREV.get("l:" + id) === null) throw new Fel(404, "ingen sådan brevlåda");
  if ((await listaAlla(env.BREV, `b:${id}:`, MAX_BREV)).length >= MAX_BREV) throw new Fel(429, "brevlådan är full");
  const nu = new Date();
  const nyckel = `b:${id}:${String(nu.getTime()).padStart(15, "0")}-${String(lopnr++ % 1e6).padStart(6, "0")}-${slump()}`;
  await env.BREV.put(nyckel, data, { metadata: { tid: nu.toISOString() } });
  return svar(201, { ok: true }, true);
}

async function hamta(id, env) {
  if (await env.BREV.get("l:" + id) === null) throw new Fel(404, "ingen sådan brevlåda");
  const nycklar = (await listaAlla(env.BREV, `b:${id}:`)).sort((a, b) => (a.name < b.name ? -1 : 1));
  const brev = [];
  for (const k of nycklar) {
    const v = await env.BREV.get(k.name, "arrayBuffer");
    if (v === null) continue;
    brev.push({ tid: (k.metadata && k.metadata.tid) || "", data: base64(new Uint8Array(v)) });
  }
  return svar(200, { brev });
}

async function taBort(id, env) {
  const fanns = (await env.BREV.get("l:" + id)) !== null;
  for (const k of await listaAlla(env.BREV, `b:${id}:`)) await env.BREV.delete(k.name);
  await env.BREV.delete("l:" + id);
  return svar(200, { ok: true, fanns });
}

export default {
  async fetch(req, env) {
    const metod = req.method;
    const cors = metod === "POST" || metod === "OPTIONS";
    try {
      const m = ID_FORM.exec(new URL(req.url).pathname);
      if (!m) throw new Fel(404, "okänd adress");
      const id = m[1];
      switch (metod) {
        case "OPTIONS":
          return svar(204, null, true);
        case "POST":
          return await lagg(id, req, env);
        case "PUT":
          await kravHemlig(req, env);
          return await oppna(id, env);
        case "GET":
          await kravHemlig(req, env);
          return await hamta(id, env);
        case "DELETE":
          await kravHemlig(req, env);
          return await taBort(id, env);
        default:
          throw new Fel(405, "metoden stöds inte");
      }
    } catch (e) {
      if (e instanceof Fel) return svar(e.kod, { fel: e.message }, cors);
      return svar(500, { fel: "internt fel" }, cors);
    }
  },
};
