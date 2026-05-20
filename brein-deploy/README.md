# Brein — Open WebUI on Hetzner CX22

Family second-brain at `brein.marnixboersema.co.za`. Open WebUI behind Caddy, OpenAI + Anthropic via API, RAG via OpenAI embeddings, SQLite + Chroma defaults. Designed for one admin (you) and a handful of family accounts you create manually.

This README walks from "fresh MacBook" to "wife and kids using it on their phones". Copy-paste friendly.

---

## Table of contents

1. [What you'll do, in order](#what-youll-do-in-order)
2. [Phase A — SSH key on macOS](#phase-a--ssh-key-on-macos)
3. [Phase B — Hetzner Cloud Console](#phase-b--hetzner-cloud-console)
4. [Phase C — DNS](#phase-c--dns)
5. [Phase D — Deploy on the VPS](#phase-d--deploy-on-the-vps)
6. [Verify everything works](#verify-everything-works)
7. [Day-2 ops](#day-2-ops)
8. [Estimated monthly cost](#estimated-monthly-cost)
9. [Troubleshooting](#troubleshooting)

---

## What you'll do, in order

Read this checklist once before starting — each phase depends on the previous one.

- [ ] **Phase A** — Generate an SSH key on the Mac.
- [ ] **Phase B** — Create a Hetzner project, upload the SSH pubkey, create the CX22 VPS, set up the Cloud Firewall, note IPv4 + IPv6.
- [ ] **Phase C** — Add A + AAAA records at your domain registrar for `brein`. Wait for propagation.
- [ ] **Phase D** — SSH in, clone the repo, run `setup.sh`, fill `.env`, drop in PWA icons, install Caddyfile, `docker compose up -d`, install cron.
- [ ] **Verify** — TLS, both providers, RAG, healthcheck, PWA tile.
- [ ] **Create family accounts** in the admin UI.
- [ ] **Set a default system prompt** via Workspace > Models.
- [ ] **Set per-user rate limits** in Admin Panel.

Estimated wall time: 45–60 minutes if DNS propagates quickly.

---

## Phase A — SSH key on macOS

You don't have an SSH key yet. Generate one, register it with the macOS Keychain so you don't re-type the passphrase, and prepare an `~/.ssh/config` entry so you can just type `ssh brein`.

### A.1 Generate the keypair

```bash
ssh-keygen -t ed25519 -C "marnix@brein" -f ~/.ssh/id_ed25519_brein
```

- Press Enter to accept the default file location.
- Set a passphrase (recommended — the Keychain stores it).

You now have:
- `~/.ssh/id_ed25519_brein` — private key. **Never share.**
- `~/.ssh/id_ed25519_brein.pub` — public key. Safe to paste anywhere.

### A.2 Load into ssh-agent + macOS Keychain

```bash
eval "$(ssh-agent -s)"
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_brein
```

To make this persist across reboots, ensure `~/.ssh/config` contains the `UseKeychain` line below.

### A.3 Configure `~/.ssh/config`

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/config && chmod 600 ~/.ssh/config
```

Open `~/.ssh/config` in your editor and append:

```sshconfig
Host brein
    HostName REPLACE-WITH-IPV4-AFTER-PHASE-B
    User root
    IdentityFile ~/.ssh/id_ed25519_brein
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
    ServerAliveInterval 60
```

You'll fill in `HostName` after Phase B.

### A.4 Copy the pubkey to your clipboard

```bash
pbcopy < ~/.ssh/id_ed25519_brein.pub
```

The pubkey is now on the clipboard, ready for Hetzner.

---

## Phase B — Hetzner Cloud Console

Go to https://console.hetzner.cloud/ and sign in (create an account if needed).

### B.1 Create a project

- Top-left dropdown > **New project** > name it `brein`.

### B.2 Upload the SSH public key

- Left sidebar > **Security** > **SSH Keys** > **Add SSH key**.
- Paste from clipboard. Name it `mac-brein`. Save.

### B.3 Create the server

- Left sidebar > **Servers** > **Add Server**.
- **Location**: Falkenstein, Helsinki, or Nuremberg — pick the lowest-latency one for South Africa (Falkenstein usually wins). Keep the same for IPv6.
- **Image**: Ubuntu 24.04.
- **Type**: Shared vCPU > **CX22** (2 vCPU, 4 GB RAM, 40 GB NVMe).
- **Networking**: Public IPv4 + Public IPv6 both enabled (default).
- **SSH Keys**: tick `mac-brein`.
- **Volumes / Firewalls / Backups**: leave blank for now (we'll add a firewall next; Open WebUI's own backup script replaces Hetzner's paid backup feature).
- **Cloud config** (under "Advanced"): paste the entire contents of `brein-deploy/cloud-init.yaml`. The VPS will auto-install Docker + Caddy + UFW + fail2ban + swap + clone the repo on first boot (~2 minutes), so you can skip most of Phase D.1.
- **Name**: `brein`.
- **Create & Buy now**.

After ~20 seconds the server is up. Note the **IPv4** and **IPv6** addresses from the server overview page.

### B.4 Cloud Firewall (defence in depth on top of UFW)

- Left sidebar > **Firewalls** > **Create Firewall**.
- Name: `brein-edge`.
- **Inbound Rules** (delete everything else):
  - TCP/22 from `0.0.0.0/0, ::/0` — SSH
  - TCP/80 from `0.0.0.0/0, ::/0` — HTTP (Let's Encrypt + redirect)
  - TCP/443 from `0.0.0.0/0, ::/0` — HTTPS
- **Outbound Rules**: leave the default "allow all".
- **Apply to**: tick `brein`.
- Create.

### B.5 Update `~/.ssh/config` with the real IPv4

Back on the Mac, edit `~/.ssh/config` and replace `REPLACE-WITH-IPV4-AFTER-PHASE-B` with the IPv4 from B.3.

Test the connection:

```bash
ssh brein
```

You should land at `root@brein:~#`. Type `exit` for now — DNS first.

---

## Phase C — DNS

At Afrihost: log in to https://clientzone.afrihost.com → **My Domains** → click `marnixboersema.co.za` → **DNS Management** (sometimes labelled "Manage DNS" or "Advanced DNS"). Add two records on the zone:

| Type | Name  | Value                                | TTL  |
|------|-------|--------------------------------------|------|
| A    | brein | `<IPv4 from Phase B>`                | 300  |
| AAAA | brein | `<IPv6 from Phase B — full address>` | 300  |

Save. Then from the Mac, confirm propagation:

```bash
dig +short brein.marnixboersema.co.za A
dig +short brein.marnixboersema.co.za AAAA
```

Both must return the right addresses **before** you run Caddy in Phase D — Let's Encrypt's challenge will fail otherwise.

Propagation is usually under 5 minutes but can take up to 30 if your registrar is slow.

---

## Phase D — Deploy on the VPS

SSH in.

```bash
ssh brein
```

### D.1 Bootstrap the host

**If you pasted `cloud-init.yaml` into the Hetzner "Cloud config" field in Phase B.3:** the VPS bootstrapped itself on first boot. Check progress:

```bash
cloud-init status --wait     # blocks until done (typically ~2 min)
ls /opt/brein/.bootstrap-complete   # exists when finished
tail /var/log/brein-bootstrap.log
```

Skip to D.3.

**If you skipped the cloud-init step**, run the bootstrap manually:

```bash
apt-get update -y && apt-get install -y git
git clone https://github.com/marnixboersema/psychic-waffle.git /opt/brein-src
cd /opt/brein-src/brein-deploy
bash setup.sh
```

`setup.sh` is idempotent — safe to re-run if it gets interrupted. It installs Docker, Caddy, UFW, fail2ban, unattended-upgrades, creates a 2 GB swapfile, and prepares `/opt/brein/`, `/var/backups/brein/`, `/var/lib/brein/static/`.

### D.2 Copy the deploy files into place (skip if cloud-init did it)

```bash
cp -r /opt/brein-src/brein-deploy/. /opt/brein/
cd /opt/brein
```

### D.3 Create `.env` with secrets

```bash
cp .env.example .env
# generate session key and paste into WEBUI_SECRET_KEY
openssl rand -hex 32
nano .env
```

In `.env`, fill in:

- `WEBUI_SECRET_KEY` — the value `openssl rand -hex 32` just printed.
- `OPENAI_API_KEYS` — replace `sk-openai-REPLACE-ME` with your OpenAI key, and `sk-ant-REPLACE-ME` with your Anthropic key. Keep the semicolon between them and the same order as `OPENAI_API_BASE_URLS`.
- `RAG_OPENAI_API_KEY` — your OpenAI key again (same one, set explicitly).

Save and close.

### D.4 PWA icons + manifest

The manifest is already in the repo at `brein-deploy/static/manifest.webmanifest`. You need to provide three icon PNGs:

| File                                       | Size      |
|--------------------------------------------|-----------|
| `/var/lib/brein/static/icon-192.png`       | 192×192   |
| `/var/lib/brein/static/icon-512.png`       | 512×512   |
| `/var/lib/brein/static/apple-touch-icon.png` | 180×180 |

Any clean PNG works (a "B" on a dark background is fine). Upload from the Mac with `scp`:

```bash
scp icon-192.png icon-512.png apple-touch-icon.png brein:/var/lib/brein/static/
```

Then on the VPS, copy the manifest into place:

```bash
cp /opt/brein/static/manifest.webmanifest /var/lib/brein/static/
```

### D.5 Install the Caddyfile (skip if cloud-init did it)

```bash
cp /opt/brein/Caddyfile /etc/caddy/Caddyfile
systemctl reload caddy
journalctl -u caddy -n 30 --no-pager
```

Caddy will obtain the Let's Encrypt cert on first request to `brein.marnixboersema.co.za`. Wait until the journal shows `certificate obtained successfully`.

### D.6 Start Open WebUI

```bash
cd /opt/brein
docker compose pull
docker compose up -d
docker compose ps
```

Wait ~60 seconds for the container to go `healthy`. Then in a browser open:

> https://brein.marnixboersema.co.za

The first account you create on the signup page becomes the **admin**. Sign up with your email + a strong password.

After admin signup, signup is locked (`ENABLE_SIGNUP=false`) — you'll add the family via the admin UI.

### D.7 Install the weekly backup cron (skip if cloud-init did it)

```bash
crontab -l 2>/dev/null > /tmp/cron.tmp || true
cat /opt/brein/crontab.txt >> /tmp/cron.tmp
crontab /tmp/cron.tmp && rm /tmp/cron.tmp
crontab -l
```

Sundays at 03:00 server time, `backup.sh` will stop the container (~10 s pause), tar the volume to `/var/backups/brein/brein-YYYY-MM-DD.tar.gz`, restart, and prune to the 4 most recent archives.

Run it once manually to confirm it works:

```bash
bash /opt/brein/backup.sh
ls -lh /var/backups/brein/
```

---

## Verify everything works

Run through this checklist on the Mac and an iPhone.

| # | Test | How |
|---|------|-----|
| 1 | TLS | `curl -I https://brein.marnixboersema.co.za` returns `HTTP/2 200` plus the `strict-transport-security` header. |
| 2 | WebSocket streaming | Send a chat message in the UI. Tokens stream word-by-word (not all at once). |
| 3 | Both providers | Model picker lists `gpt-4o-mini` and `claude-sonnet-4-5`. Send one message to each. |
| 4 | RAG | Workspace > Knowledge > new collection > upload a small PDF. Ask a question whose answer is in the PDF. Confirm citations appear. |
| 5 | iPhone PWA | Open the URL in Safari > Share > **Add to Home Screen** > confirm the tile reads pure `Brein` (not `Open WebUI`). Open from the tile — runs full-screen. |
| 6 | Healthcheck | `docker compose ps` shows `(healthy)` next to `brein-open-webui`. |
| 7 | Firewall | From the Mac: `nc -zv <ipv4> 8080` → "Connection refused". `nc -zv <ipv4> 443` → "succeeded". |
| 8 | Backup | `ls -lh /var/backups/brein/` shows the `.tar.gz` from D.7. |

If any of these fail, see [Troubleshooting](#troubleshooting).

---

## Day-2 ops

### Add a family member

Admin Panel (top-right user menu > Admin Panel) > **Users** > **`+` Add user** > email, password, role `user`. Pass them the URL and credentials. They sign in directly — no email verification step.

### Set the default system prompt

Open WebUI has no `DEFAULT_SYSTEM_PROMPT` env var. Use a Workspace model wrapper:

1. **Workspace** > **Models** > **`+`** (create a model).
2. Base model: `gpt-4o-mini`.
3. **System prompt**: paste your Afrikaans family-tuned prompt. Keep it short — long prompts cost tokens on every message.
4. Name it e.g. `Brein (gesin)`. Save.
5. Admin Panel > Settings > Models > tick `Brein (gesin)` as accessible to all users.
6. Edit `/opt/brein/.env` and add the wrapper's ID to `DEFAULT_MODELS=` (front of the list), then `docker compose up -d` to restart.

Each user can still override their personal default in Settings > General > System Prompt.

### Upload to Knowledge

**Workspace** > **Knowledge** > **`+` Create collection** > name it (e.g. `Tuiskool — wiskunde graad 4`) > drag files in (PDF, DOCX, MD, TXT). Embeddings happen via OpenAI in the background — small spinner clears in seconds for short docs, a minute or two for a long textbook.

To query against a collection, in chat use `#` and pick the collection, or attach it from the input box's paperclip.

### Set per-user rate limits

Admin Panel > **Settings** > **General** > **User Permissions**. Cap chats/day or tokens/hour per role. For per-model limits, **Workspace** > **Models** > select model > **Permissions**.

### Update Open WebUI later (one command flow)

```bash
ssh brein
cd /opt/brein
bash backup.sh                    # always back up before upgrading
nano .env                         # bump WEBUI_DOCKER_TAG to the new release
docker compose pull
docker compose up -d
docker compose ps                 # wait for healthy
```

Release notes: https://github.com/open-webui/open-webui/releases. Pin to a `vX.Y.Z` tag — never `:main` or `:latest`.

If the new version breaks something, roll back: edit `.env` to the previous tag, `docker compose up -d`. If schema migrations ran, [restore from backup](#restore-from-backup).

### Restore from backup

```bash
ssh brein
cd /opt/brein
docker compose down
docker volume rm open-webui-data
docker volume create --name open-webui-data
docker run --rm \
    -v open-webui-data:/data \
    -v /var/backups/brein:/backup \
    alpine sh -c "cd / && tar xzf /backup/brein-YYYY-MM-DD.tar.gz"
docker compose up -d
```

Replace `brein-YYYY-MM-DD.tar.gz` with the archive you want. The container restarts pointing at the restored data.

### Where to monitor spend

- OpenAI: https://platform.openai.com/usage and https://platform.openai.com/account/limits — **set a monthly hard cap** to prevent runaway costs.
- Anthropic: https://console.anthropic.com/settings/usage — also set a spend limit.

---

## Estimated monthly cost

| Item | Range |
|---|---|
| Hetzner CX22 (Falkenstein) | ~€4.59 / ~R95 |
| OpenAI usage — family of 4, gpt-4o-mini default + occasional gpt-5 + embeddings on a slowly growing RAG corpus | R150 – R400 typical, R600 worst-case |
| Anthropic — used as fallback / specific tasks | R50 – R150 |
| Domain (already owned) | R0 |
| **Total realistic** | **R300 – R650 / month** |
| Upper bound with heavy daily research traffic | ~R1 000 / month |

`gpt-4o-mini` is intentionally the default — it's roughly 10× cheaper than `gpt-5` per token and good enough for most chat. Reserve `claude-sonnet-4-5` for tasks where it genuinely shines (long-form writing, code).

Watch the first month's OpenAI dashboard closely, then set a hard cap.

---

## Troubleshooting

### Caddy can't get a cert ("challenge failed")

- Check DNS: `dig +short brein.marnixboersema.co.za A AAAA` must return the VPS IPs.
- Check ports: `ss -lntp | grep -E ':80|:443'` should show Caddy.
- Check firewall: `ufw status` and the Hetzner Cloud Firewall both allow 80/443.
- Tail logs: `journalctl -u caddy -f`.

### Container won't go healthy

- Logs: `cd /opt/brein && docker compose logs --tail=200 open-webui`.
- Most common cause: bad API key. Check `.env`, then restart: `docker compose up -d`.
- Cold start can take 60 s — wait before panicking.

### Anthropic model doesn't appear in the picker

- Confirm the Anthropic URL ends `/v1` (no trailing slash, no `/messages`).
- Restart: `docker compose restart open-webui`.
- If still missing: Admin Panel > Settings > Connections > add it manually. Open WebUI's `ENABLE_PERSISTENT_CONFIG=true` (the default) sometimes ignores env changes after first boot — admin UI is authoritative.

### Streaming feels broken / messages arrive in chunks

- WebSocket upgrade through Caddy is automatic — if it's broken, it's almost always a third-party CDN in front (e.g. Cloudflare orange-cloud). Run direct (DNS-only / no proxy).

### Locked out of admin

Reset on the host:

```bash
docker compose exec open-webui bash
# inside container:
python -c "import sqlite3; c=sqlite3.connect('/app/backend/data/webui.db'); c.execute(\"UPDATE user SET role='admin' WHERE email='you@example.com';\"); c.commit()"
exit
docker compose restart open-webui
```

### Backup ran but container didn't restart

`backup.sh` has a trap that restarts even on failure. If something truly weird happened: `cd /opt/brein && docker compose up -d`.

### Disk filling up

- `du -sh /var/backups/brein /var/lib/docker /opt/brein` to see who.
- Old backups beyond 4 should auto-prune; if not, run `bash /opt/brein/backup.sh` manually to trigger prune.
- Docker images: `docker image prune -a` after upgrades.

---

## File layout reference

On the VPS after deploy:

```
/opt/brein/
├── docker-compose.yml      # the service definition
├── Caddyfile               # source of truth (copied to /etc/caddy/)
├── .env                    # secrets — never commit
├── .env.example
├── setup.sh                # idempotent bootstrap, safe to re-run
├── backup.sh               # cron-driven
├── crontab.txt
├── cloud-init.yaml         # optional first-boot bootstrap (paste in Hetzner Console)
├── static/
│   └── manifest.webmanifest
└── README.md               # this file

/var/lib/brein/static/      # served by Caddy at /static/brein/*
├── manifest.webmanifest
├── icon-192.png
├── icon-512.png
└── apple-touch-icon.png

/var/backups/brein/         # weekly tar.gz, 4 most recent
└── brein-YYYY-MM-DD.tar.gz
```

Docker named volume `open-webui-data` holds `/app/backend/data` — SQLite DB, ChromaDB vectors, uploaded RAG sources, embedding cache.
