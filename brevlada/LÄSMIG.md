# Brevlådan

En liten mottagare för kommentarer från webbvisaren. Besökaren skickar kommentarerna krypterade (SKD1, delningens
nyckel), så tjänsten kan aldrig läsa dem. Ägaren (`cad/dela.py`) öppnar en låda per delning, hämtar breven och tar
bort lådan vid "Sluta dela". API:t står i `PLAN-webbvisare.md` under "Brevlådan".

Två utföranden med samma API – välj ett:

- **Cloudflare Worker** (`worker.js`, lagrar i Workers KV). Inget att underhålla, gratisnivån räcker.
- **Egen Ubuntu-maskin** (`server.py`, ren Python 3.10+, lagrar i en mapp) bakom en omvänd tunnel.

Gränser: id = 22 tecken base64url, brev högst 64 kB och måste börja med `SKD1`, högst 200 brev per låda, högst 1000
lådor (`--max-lador` / `MAX_LADOR`).

## 1. Skapa hemligheten

En lång slumpad text som bara du har (minst 24 tecken; tjänsten startar inte utan den):

```sh
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## 2a. Cloudflare Worker

```sh
cd brevlada
npx wrangler login
npx wrangler kv namespace create BREV        # skriv in id:t som skrivs ut i wrangler.toml
npx wrangler secret put BREVLADA_HEMLIG      # klistra in hemligheten
npx wrangler deploy
```

Adressen blir `https://skanna-brevlada.<ditt-konto>.workers.dev`. KV är "till slut konsistent", så 200-gränsen kan
överskridas något om många brev kommer samtidigt.

## 2b. Ubuntu + omvänd tunnel

Kopiera `server.py` till t.ex. `/opt/brevlada/` och skapa en användare och en datamapp:

```sh
sudo useradd --system --home /var/lib/brevlada --create-home brevlada
sudo install -d -o brevlada -m 700 /var/lib/brevlada/data
sudo install -m 644 server.py /opt/brevlada/server.py
echo "BREVLADA_HEMLIG=<hemligheten>" | sudo tee /etc/brevlada.env >/dev/null
sudo chmod 600 /etc/brevlada.env
```

`/etc/systemd/system/brevlada.service`:

```ini
[Unit]
Description=Skanna brevlåda
After=network.target

[Service]
User=brevlada
EnvironmentFile=/etc/brevlada.env
ExecStart=/usr/bin/python3 /opt/brevlada/server.py --port 8787 --mapp /var/lib/brevlada/data
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/brevlada
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now brevlada
curl -i -X OPTIONS http://127.0.0.1:8787/b/AAAAAAAAAAAAAAAAAAAAAA   # ska ge 204
```

Tjänsten lyssnar bara på 127.0.0.1. Gör den nåbar utifrån över HTTPS med en omvänd tunnel, till exempel:

- **cloudflared** (Cloudflare Tunnel, kräver ett eget domännamn hos Cloudflare):
  ```sh
  cloudflared tunnel login
  cloudflared tunnel create brevlada
  cloudflared tunnel route dns brevlada brevlada.<din-domän>
  cloudflared tunnel run --url http://127.0.0.1:8787 brevlada
  ```
  (kör den som tjänst med `sudo cloudflared service install` när den fungerar)
- **ssh -R** mot en egen värd med publik adress, där en webbserver (t.ex. Caddy) tar hand om HTTPS och skickar vidare
  till den lokala porten på värden:
  ```sh
  ssh -N -R 127.0.0.1:8787:127.0.0.1:8787 du@din-vard.example   # gärna via autossh eller en systemd-enhet
  ```
  Caddyfile på värden: `brevlada.<din-domän> { reverse_proxy 127.0.0.1:8787 }`

Webbvisaren skickar breven från en HTTPS-sida, så brevlådan måste också nås över HTTPS.

## 3. Koppla in i Skanna

Lägg adressen (utan `/b/…`) och hemligheten i `~/.config/skanna/delning.json`, bredvid eventuella andra inställningar:

```json
{
  "brevlada_url": "https://skanna-brevlada.<ditt-konto>.workers.dev",
  "brevlada_hemlig": "<hemligheten>"
}
```

```sh
chmod 600 ~/.config/skanna/delning.json
```

Nya delningar får då en brevlåda (`<brevlada_url>/b/<id>`). Utan `brevlada_url` används svarslänken som reserv.

## Prova lokalt

```sh
BREVLADA_HEMLIG=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))") python3 server.py --port 8787 --mapp /tmp/brev
cd tester/python && ../../.venv/bin/python -m unittest test_brevlada -v
```
