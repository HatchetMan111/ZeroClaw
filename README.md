# ZeroClaw Proxmox LXC Installer

Ein Einzeiler-Installer im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/)
für **[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw)** – ein persönlicher
AI-Assistant / eine Agent-Runtime in Rust mit Web-Dashboard, Gateway, Channels,
Memory, Tools und Scheduler.

Das Skript läuft **auf dem Proxmox-Host**, erstellt einen **unprivilegierten
Debian-12-LXC** und installiert ZeroClaw **nativ** (vorkompiliertes Release +
`web/dist`, kein Docker, kein Kompilieren, kein GPU nötig).

```
┌──────────────────────────────────────────────────────────────┐
│ Proxmox Host                                                  │
│  └─ LXC CT 150 "zeroclaw" (unprivileged, nesting, onboot)     │
│       ├─ systemd: zeroclaw.service  →  zeroclaw daemon        │
│       ├─ /usr/local/bin/zeroclaw                              │
│       ├─ /usr/share/zeroclawlabs/web/dist  (Dashboard)        │
│       ├─ /var/lib/zeroclaw/.zeroclaw/config.toml              │
│       └─ Gateway/Web-UI auf 0.0.0.0:42617                     │
└──────────────────────────────────────────────────────────────┘
```

## Voraussetzungen

- Proxmox VE 8.x (oder neuer)
- Root-Shell auf dem **Host** (nicht im Container)
- Internetzugang des Hosts für Template + Release-Download
- RootFS-Storage (bevorzugt `local-lvm`) und Template-Storage (`local`)
- Das LLM kommt per API-Provider oder über eine eigene OpenAI-kompatible
  Base-URL (z. B. Ollama); ZeroClaw selbst läuft komplett lokal.

## Schnellstart

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ZeroClaw/main/install/zeroclaw.sh)"
```

oder mit `curl`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ZeroClaw/main/install/zeroclaw.sh)"
```

Am Ende gibt das Skript aus:

- Container-ID, IP und Ressourcen
- Web-UI-URL: `http://<CT-IP>:42617`
- **Pairing-Code** (einmalig, sofort notieren)
- Service-/Update-/Deinstall-Hinweise

## Optionen

| Option | Default | Bedeutung |
|---|---|---|
| `--ctid ID` | nächste freie ID (`pvesh get /cluster/nextid`) | Container-ID |
| `--hostname NAME` | `zeroclaw` | Container-Hostname |
| `--cores N` | `2` | vCPU |
| `--memory MB` | `2048` | RAM |
| `--disk GB` | `8` | RootFS-Größe |
| `--storage NAME` | auto (`local-lvm`, sonst erstes RootFS-Storage) | RootFS-Storage |
| `--template-store N` | `local` | Template-Storage |
| `--bridge NAME` | `vmbr0` | Netzwerk-Bridge |
| `--port PORT` | `42617` | Gateway/Web-UI-Port |
| `--version TAG` | `v0.8.7` | Release-Tag oder `latest` |
| `--no-pairing` | aus | Pairing deaktivieren (nur vertrauenswürdiges LAN!) |
| `--ssh-key PATH` | – | SSH-Public-Key in den Container |
| `--debug` | – | `bash -x` + volle Fehlerkette |
| `-h, --help` | – | Hilfe |

Zusätzlich per Umgebungsvariable steuerbar:
`CT_ID`, `CORES`, `RAM`, `DISK`, `APP_PORT`, `ZEROCLAW_VERSION`, `PAIRING=0|1`, `TZ_NAME`.

Beispiele:

```bash
# Eigene ID und mehr Leistung
CT_ID=150 CORES=4 RAM=4096 bash -c "$(wget -qLO - .../install/zeroclaw.sh)"

# Immer das neueste Release
bash -c "$(wget -qLO - .../install/zeroclaw.sh)" -- --version latest

# Pairing aus (nur vertrauenswürdiges LAN)
bash -c "$(wget -qLO - .../install/zeroclaw.sh)" -- --no-pairing
```

> Hinweis: Argumente nach `--` werden an das Skript weitergereicht.

## Was das Skript macht

1. **Host-Checks** – `pct`, `pvesh`, `pveam`, Root-Rechte, nächste CT-ID.
2. **Template** – lädt das neueste `debian-12-standard`-Template (inkl.
   `.tar.zst`-Fallback), falls nicht vorhanden.
3. **Container** – erstellt unprivilegierten LXC mit `nesting=1`, DHCP,
   `onboot=1`. Existiert die ID bereits, wird **aktualisiert** statt neu erstellt.
4. **Payload** – installiert im Container: CA-Zertifikate, curl, tar, tzdata,
   Systemuser `zeroclaw`, Verzeichnisse, Binary + `zerocode`/`zerorelay`,
   Dashboard nach `/usr/share/zeroclawlabs/web/dist`.
5. **Release-Sicherheit** – lädt `SHA256SUMS` und verifiziert das Archiv,
   bevor etwas installiert wird.
6. **Config** – setzt nur Gateway-Felder (`host`, `port`, `allow_public_bind`,
   `require_pairing`) via `zeroclaw config set`. Nutzerwerte werden nie überschrieben.
7. **systemd** – installiert `zeroclaw.service`, `enable` + `restart`,
   Health-Check auf `/health`.
8. **Verifikation** – prüft Service, Binary, Dashboard und HTTP 200 auf
   `localhost` **und** über die CT-IP; erzeugt den Pairing-Code.

Der Installer ist **idempotent**: Erneutes Ausführen aktualisiert Binary/Config
und startet den Service neu; Daten unter `/var/lib/zeroclaw` bleiben erhalten.

## Nach der Installation

Web-UI im Browser öffnen: `http://<CT-IP>:42617`

1. Pairing-Code eingeben (falls aktiviert).
2. Im Dashboard unter **Quickstart** Provider, Modell und API-Key setzen.
   Alternativ eine eigene OpenAI-kompatible Base-URL, z. B. lokales Ollama:
   `http://<proxmox-host>:11434/v1`.
3. Optional Channels (Telegram, Discord, …), Tools und Scheduler konfigurieren.

Nützliche Befehle auf dem Host:

```bash
# Pairing-Code neu erzeugen
pct exec 150 -- su -s /bin/bash zeroclaw -c \
  "HOME=/var/lib/zeroclaw /usr/local/bin/zeroclaw \
   --config-dir /var/lib/zeroclaw/.zeroclaw gateway get-paircode --new"

# Service-Status / Logs
pct exec 150 -- systemctl status zeroclaw
pct exec 150 -- journalctl -u zeroclaw -f

# In den Container
pct enter 150
```

## Update

Einfach das Installationsskript erneut ausführen. Standardmäßig ist das Release
gepinnt (`v0.8.7`); für ein neues Release `--version latest` oder einen
konkreten Tag setzen. Die Config und alle Daten bleiben erhalten.

```bash
bash -c "$(wget -qLO - .../install/zeroclaw.sh)" -- --ctid 150 --version latest
```

## Deinstallieren

```bash
pct stop 150
pct destroy 150
```

## Verifikation / Tests

**Ohne Proxmox** (auf jedem Linux mit Netzwerk, als normaler User):

```bash
bash tests/smoke-local.sh
```

Der Test lädt das Release, prüft die Checksumme, erzeugt eine temporäre Config,
startet den Daemon auf einem freien Port und prüft:
`/health` (JSON, `status=ok`), Dashboard `/` (HTTP 200, HTML) und Pairing-Code.

**Auf dem Proxmox-Host** (inkl. Reboot-Test):

```bash
sudo bash tests/proxmox-verify.sh 150
```

Prüft nach einem echten `pct reboot`, ob der Service automatisch wieder startet,
`/health` im Container und über die CT-IP antwortet und der Dienst `enabled` ist.

## Troubleshooting

| Problem | Ursache / Lösung |
|---|---|
| `pct`/`pvesh` nicht gefunden | Skript läuft nicht auf dem Proxmox-Host. |
| Kein Debian-Template | `pveam update` auf dem Host prüfen (Netz/DNS). |
| Keine CT-IP | Bridge/DHCP prüfen: `pct exec 150 -- ip a`. |
| Web-UI von außen nicht erreichbar | Host-Firewall / Bridge; im Container ist `gateway.host=0.0.0.0` gesetzt. |
| `config schema_version is newer ...` | Config wurde manuell mit falscher Version geschrieben. `zeroclaw config set` (macht das Skript) erzeugt die passende Version für das installierte Binary. |
| Service startet nicht | `pct exec 150 -- journalctl -u zeroclaw -n 120 --no-pager`; Installer mit `--debug` erneut laufen lassen. |
| Pairing-Code verloren | Befehl oben „Pairing-Code neu erzeugen“. |

Vollständiges Installer-Log: `/tmp/zeroclaw-install-<Datum>.log` auf dem Host.

## Sicherheit

- **Unprivilegierter LXC** mit `nesting=1`; `NoNewPrivileges`/`PrivateTmp` in der Unit.
- **Pairing standardmäßig an** (`gateway.require_pairing=true`).
  `--no-pairing` nur in einem vertrauenswürdigen LAN verwenden.
- ZeroClaw ist ein **Agent mit Shell-Zugriff** auf seinen Workspace. Behandle den
  Container als eigenständige Vertrauensgrenze und gib ihm keine Host-Mounts.
- API-Keys liegen in `/var/lib/zeroclaw/.zeroclaw/config.toml` (Modus `600`,
  Eigentümer `zeroclaw`). Nicht in Git committen, nicht weitergeben.
- Für Zugriff aus dem Internet: Reverse Proxy mit TLS und Auth davor, nicht den
  Port direkt exponieren.

## Projektstruktur

```
ZeroClaw/
├── install/zeroclaw.sh          # Host-Installer (LXC + Payload + Verifikation)
├── systemd/zeroclaw.service     # systemd-Unit (wird in den CT geladen)
├── tests/smoke-local.sh         # Release/Config/Daemon/UI/Paircode-Test ohne Proxmox
├── tests/proxmox-verify.sh      # Reboot-/Health-/Service-Test auf dem Host
└── README.md
```

## Credits

- [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) – Upstream-Projekt
  (Apache-2.0, siehe Upstream-Repo).
- Installer-Struktur inspiriert von den Proxmox VE Community Scripts.

Dieses Repository ist ein Community-Installer und steht in keiner offiziellen
Verbindung zu den ZeroClaw-Labs.
