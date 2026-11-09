#!/usr/bin/env bash
#
# ZeroClaw Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      ZeroClaw – persönlicher AI-Assistant / Agent-Runtime (Rust)
#           Web-Dashboard, Gateway, Channels, Memory, Tools, Scheduler
# Upstream: https://github.com/zeroclaw-labs/zeroclaw
# Stack:    Prebuilt-Release (Rust-Binary + web/dist) + systemd, nativ im LXC
# Läuft:    vollständig lokal im LXC; das LLM kommt per API-Provider
#           oder über eine eigene OpenAI-kompatible Base-URL (z. B. Ollama).
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ZeroClaw/main/install/zeroclaw.sh)"
#   CT_ID=150 CORES=4 RAM=4096 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ZeroClaw/main/install/zeroclaw.sh)"
#   bash zeroclaw.sh --ctid 150 --cores 4 --memory 4096 --version latest --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="zeroclaw"                                  # Container-Hostname + Service-Name
APP_DISPLAY="ZeroClaw"                          # Anzeigename
APP_PORT="${APP_PORT:-42617}"                   # Gateway / Web-UI
UPSTREAM_REPO="https://github.com/zeroclaw-labs/zeroclaw"
ZEROCLAW_VERSION="${ZEROCLAW_VERSION:-v0.8.7}"  # gepinnter Release-Tag; "latest" erlaubt
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ZeroClaw/main}"
SERVICE_URL="${RAW_BASE}/systemd/zeroclaw.service"

DEFAULT_CORES="${CORES:-2}"                     # vCPU
DEFAULT_RAM="${RAM:-2048}"                      # RAM in MB
DEFAULT_SWAP="${SWAP:-512}"                     # Swap (MB)
DEFAULT_DISK="${DISK:-8}"                       # Disk in GB
DEFAULT_BRIDGE="${BRIDGE:-vmbr0}"
DEFAULT_TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
DEFAULT_OS="debian-12-standard"                 # Template-Familie
UNPRIVILEGED="1"                                # 1 = unprivilegiert
FEATURES="nesting=1"                            # nesting für Agent-Tools/Shell
DEFAULT_TZ="${TZ_NAME:-Europe/Berlin}"
PAIRING_ENABLED="${PAIRING:-1}"                 # 1 = Pairing-Code erforderlich

APP_USER="zeroclaw"
APP_HOME="/var/lib/zeroclaw"
CONFIG_DIR="${APP_HOME}/.zeroclaw"
DATA_DIR="${CONFIG_DIR}/data"
WORKSPACE_DIR="${APP_HOME}/workspace"
BIN_PATH="/usr/local/bin/zeroclaw"
WEB_DIR="/usr/share/zeroclawlabs/web/dist"
SERVICE_NAME="zeroclaw"

# Umgebungs-Overrides: CT_ID=150 CORES=4 RAM=4096 ./zeroclaw.sh
CT_ID="${CT_ID:-${CTID:-}}"
CORES="$DEFAULT_CORES"
RAM="$DEFAULT_RAM"
DISK="$DEFAULT_DISK"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
HOSTNAME_ARG="$APP"
SSH_KEY_ARG=""
DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
if [[ "$DEBUG" == "1" ]]; then
  echo "--- DEBUG: set -x aktiv ---"
  set -x
fi

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
on_error() {
  local ec="${1:-1}" line="${2:-?}" cmd="${3:-?}"
  msg_error "FEHLER: Befehl »${cmd}« scheiterte in Zeile ${line} (Exit ${ec})."
  msg_error "Vollständiges Log: ${LOG_FILE}"
  msg_error "Für bash -x erneut mit --debug starten."
  echo "--- letzte 60 Logzeilen ---" >&2
  tail -n 60 "$LOG_FILE" >&2 || true
  exit "$ec"
}
cleanup_tmp() { rm -f "${PAYLOAD_FILE:-}" "${ENV_FILE:-}"; }
trap 'ec=$?; cmd=$BASH_COMMAND; line=$LINENO; cleanup_tmp 2>/dev/null || true; on_error "$ec" "$line" "$cmd"' ERR

usage() {
  cat <<EOF
${APP_DISPLAY} Proxmox LXC Installer

Usage:
  bash zeroclaw.sh [OPTIONEN]
  CT_ID=150 bash zeroclaw.sh
  bash -c "\$(wget -qLO - ${RAW_BASE}/install/zeroclaw.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --port PORT          Gateway/Web-UI-Port (Default: ${APP_PORT})
  --version TAG        ZeroClaw-Release-Tag oder "latest" (Default: ${ZEROCLAW_VERSION})
  --no-pairing         Pairing-Code deaktivieren (nur in vertrauenswürdigem LAN!)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe

Umgebungsvariablen:
  CT_ID, CORES, RAM, DISK, APP_PORT, ZEROCLAW_VERSION, PAIRING=0/1, TZ_NAME
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --port) APP_PORT="$2"; shift 2;;
    --version) ZEROCLAW_VERSION="$2"; shift 2;;
    --no-pairing) PAIRING_ENABLED="0"; shift;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ "$CORES" =~ ^[0-9]+$ ]] || { msg_error "--cores muss numerisch sein."; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] || { msg_error "--memory muss numerisch sein."; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] || { msg_error "--disk muss numerisch sein."; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { msg_error "--port muss numerisch sein."; exit 1; }
[[ "$PAIRING_ENABLED" == "0" || "$PAIRING_ENABLED" == "1" ]] || { msg_error "PAIRING muss 0 oder 1 sein."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
command -v pveam >/dev/null || { msg_error "pveam nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi
[[ "$CT_ID" =~ ^[0-9]+$ ]] || { msg_error "Ungültige CT-ID: $CT_ID"; exit 1; }

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status 2>/dev/null | awk '$1=="local-lvm"{found=1} END{exit !found}'; then
    STORAGE_ARG="local-lvm"
  else
    STORAGE_ARG="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')"
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
  pct set "$CT_ID" --onboot 1 >/dev/null 2>&1 || msg_warn "onboot konnte nicht gesetzt werden."
else
  ROOT_PW="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 20 || true)"
  [[ -n "$ROOT_PW" ]] || ROOT_PW="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$ROOT_PW"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for _ in $(seq 1 30); do
  sleep 3
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {print $i; exit}}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct exec "$CT_ID" -- mkdir -p /root/.ssh || true
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys
  pct exec "$CT_ID" -- chmod 700 /root/.ssh || true
  pct exec "$CT_ID" -- chmod 600 /root/.ssh/authorized_keys || true
fi

# ---------------------------------------------------------------------------
# 4. Payload + Env-Datei vorbereiten (pct push statt Quoting-Hölle)
# ---------------------------------------------------------------------------
PAYLOAD_FILE="$(mktemp /tmp/${APP}-payload.XXXXXX.sh)"
ENV_FILE="$(mktemp /tmp/${APP}-env.XXXXXX)"

cat > "$ENV_FILE" <<ENVEOF
APP_PORT=$(printf '%q' "$APP_PORT")
APP_USER=$(printf '%q' "$APP_USER")
APP_HOME=$(printf '%q' "$APP_HOME")
CONFIG_DIR=$(printf '%q' "$CONFIG_DIR")
DATA_DIR=$(printf '%q' "$DATA_DIR")
WORKSPACE_DIR=$(printf '%q' "$WORKSPACE_DIR")
BIN_PATH=$(printf '%q' "$BIN_PATH")
WEB_DIR=$(printf '%q' "$WEB_DIR")
SERVICE_NAME=$(printf '%q' "$SERVICE_NAME")
SERVICE_URL=$(printf '%q' "$SERVICE_URL")
ZEROCLAW_VERSION=$(printf '%q' "$ZEROCLAW_VERSION")
PAIRING_ENABLED=$(printf '%q' "$PAIRING_ENABLED")
TZ_NAME=$(printf '%q' "$DEFAULT_TZ")
ENVEOF

cat > "$PAYLOAD_FILE" <<'PAYLOAD_EOF'
#!/usr/bin/env bash
# Läuft IM Container. Alle Werte kommen aus /root/.zeroclaw-install.env.
set -euo pipefail
ENV_PATH="/root/.zeroclaw-install.env"
# shellcheck disable=SC1090
. "$ENV_PATH"
rm -f "$ENV_PATH"

die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }

export DEBIAN_FRONTEND=noninteractive
for attempt in 1 2 3; do
  if apt-get update -qq; then break; fi
  [ "$attempt" = "3" ] && die "apt-get update fehlgeschlagen (Netz/DNS im CT prüfen)."
  sleep 3
done
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl tar gzip coreutils tzdata openssl

ln -snf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
echo "$TZ_NAME" > /etc/timezone

# --- Systemuser + Verzeichnisse -------------------------------------------
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
fi
install -d -m 0755 -o "$APP_USER" -g "$APP_USER" \
  "$APP_HOME" "$CONFIG_DIR" "$DATA_DIR" "$WORKSPACE_DIR"

# --- Architektur / Release-Asset ------------------------------------------
case "$(uname -m)" in
  x86_64|amd64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) TRIPLE="aarch64-unknown-linux-gnu" ;;
  *) die "Nicht unterstützte Architektur: $(uname -m)" ;;
esac

if [ "$ZEROCLAW_VERSION" = "latest" ]; then
  ZEROCLAW_VERSION="$(curl -fsSL \
    "https://api.github.com/repos/zeroclaw-labs/zeroclaw/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
fi
[ -n "${ZEROCLAW_VERSION:-}" ] || die "Release-Version konnte nicht ermittelt werden."

ASSET="zeroclaw-${TRIPLE}.tar.gz"
BASE_URL="https://github.com/zeroclaw-labs/zeroclaw/releases/download/${ZEROCLAW_VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Lade ${ASSET} (${ZEROCLAW_VERSION}) ..."
curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
  "$BASE_URL/SHA256SUMS" -o "$TMP/SHA256SUMS" \
  || die "SHA256SUMS nicht abrufbar für ${ZEROCLAW_VERSION}."
EXPECTED="$(awk -v a="$ASSET" '$2==a || $2=="*"a {print $1}' "$TMP/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "Asset ${ASSET} fehlt in SHA256SUMS."
curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
  "$BASE_URL/$ASSET" -o "$TMP/$ASSET" || die "Download fehlgeschlagen."
ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  die "Checksum-Mismatch: erwartet ${EXPECTED}, erhalten ${ACTUAL}"
fi
ok "Checksum verifiziert."

tar -xzf "$TMP/$ASSET" -C "$TMP"
[ -x "$TMP/zeroclaw" ] || die "zeroclaw-Binary fehlt im Archiv."
install -m 0755 "$TMP/zeroclaw" "$BIN_PATH"
for extra in zerocode zerorelay; do
  [ -f "$TMP/$extra" ] && install -m 0755 "$TMP/$extra" "/usr/local/bin/$extra"
done

# Dashboard: /usr/share/zeroclawlabs/web/dist ist Auto-Detect-Kandidat 4.
[ -f "$TMP/web/dist/index.html" ] || die "web/dist/index.html fehlt im Archiv."
install -d -m 0755 "$WEB_DIR"
cp -a "$TMP/web/dist/." "$WEB_DIR/"
ok "ZeroClaw ${ZEROCLAW_VERSION} + Dashboard installiert."

# --- Config: nur Gateway-Felder setzen, Nutzerwerte nie überschreiben -----
as_app() {
  su -s /bin/bash "$APP_USER" -c \
    "HOME='$APP_HOME' XDG_DATA_HOME='$APP_HOME/.local/share' $*"
}
as_app "'$BIN_PATH' --config-dir '$CONFIG_DIR' config set gateway.host 0.0.0.0" >/dev/null
as_app "'$BIN_PATH' --config-dir '$CONFIG_DIR' config set gateway.port '$APP_PORT'" >/dev/null
as_app "'$BIN_PATH' --config-dir '$CONFIG_DIR' config set gateway.allow_public_bind true" >/dev/null
if [ "$PAIRING_ENABLED" = "1" ]; then
  as_app "'$BIN_PATH' --config-dir '$CONFIG_DIR' config set gateway.require_pairing true" >/dev/null
else
  as_app "'$BIN_PATH' --config-dir '$CONFIG_DIR' config set gateway.require_pairing false" >/dev/null
fi
chown -R "$APP_USER:$APP_USER" "$APP_HOME"
chmod 600 "$CONFIG_DIR/config.toml" 2>/dev/null || true
ok "Config aktualisiert: gateway=${APP_PORT}, host=0.0.0.0, pairing=${PAIRING_ENABLED}."

# --- systemd-Unit (aus Repo, Fallback inline) ------------------------------
if ! curl -fsSL --retry 3 --retry-delay 2 -o /etc/systemd/system/zeroclaw.service "$SERVICE_URL" 2>/dev/null; then
  cat > /etc/systemd/system/zeroclaw.service <<'UNIT'
[Unit]
Description=ZeroClaw - personal AI assistant (Gateway/Web-UI)
Documentation=https://github.com/zeroclaw-labs/zeroclaw
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zeroclaw
Group=zeroclaw
WorkingDirectory=/var/lib/zeroclaw
Environment=HOME=/var/lib/zeroclaw
Environment=XDG_DATA_HOME=/var/lib/zeroclaw/.local/share
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/zeroclaw --config-dir /var/lib/zeroclaw/.zeroclaw daemon
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
LimitNOFILE=16384
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$SERVICE_NAME"

# Port freigeben, falls im Container eine Firewall aktiv ist
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$APP_PORT"/tcp >/dev/null
fi

# --- Health-Check im Container --------------------------------------------
info "Warte auf Gateway (max. 120s) ..."
WEB_OK=0
for _ in $(seq 1 60); do
  if curl -fs -m 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
    WEB_OK=1
    break
  fi
  sleep 2
done
if [ "$WEB_OK" != "1" ]; then
  systemctl status "$SERVICE_NAME" --no-pager || true
  journalctl -u "$SERVICE_NAME" --no-pager -n 120 || true
  die "Gateway antwortet nicht auf 127.0.0.1:${APP_PORT}/health"
fi
ok "Gateway antwortet auf 127.0.0.1:${APP_PORT}/health."
PAYLOAD_EOF

chmod 700 "$PAYLOAD_FILE"

msg_info "Übertrage Installer-Payload in CT $CT_ID ..."
pct push "$CT_ID" "$PAYLOAD_FILE" /root/zeroclaw-install.sh --perms 700
pct push "$CT_ID" "$ENV_FILE" /root/.zeroclaw-install.env --perms 600
msg_ok "Payload übertragen."

# ---------------------------------------------------------------------------
# 5. Installation im Container
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP_DISPLAY} im Container (nativ, ohne Docker) ..."
# Bewusst kein '| tail': mit pipefail würde der trap sonst die Pipe melden.
pct exec "$CT_ID" -- bash /root/zeroclaw-install.sh

# Host-seitiger Guard: bricht laut ab, falls Binary/Dashboard fehlen.
pct exec "$CT_ID" -- test -x "$BIN_PATH" \
  || { msg_error "Binary fehlt: $BIN_PATH"; exit 1; }
pct exec "$CT_ID" -- test -f "$WEB_DIR/index.html" \
  || { msg_error "Dashboard fehlt: $WEB_DIR/index.html"; exit 1; }
msg_ok "Binary + Dashboard ok."

# ---------------------------------------------------------------------------
# 6. Verifikation: Service + Web UI (localhost + CT-IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
if ! pct exec "$CT_ID" -- systemctl is-active --quiet "$SERVICE_NAME"; then
  msg_error "systemd-Service ${SERVICE_NAME} ist nicht active."
  pct exec "$CT_ID" -- systemctl status "$SERVICE_NAME" --no-pager || true
  pct exec "$CT_ID" -- journalctl -u "$SERVICE_NAME" --no-pager -n 120 || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active ${SERVICE_NAME} = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
    WEB_OK=1
    break
  fi
  sleep 10
done
if [[ "$WEB_OK" != "1" ]]; then
  msg_error "Web UI antwortet nicht auf 127.0.0.1:${APP_PORT}/health."
  pct exec "$CT_ID" -- systemctl status "$SERVICE_NAME" --no-pager || true
  pct exec "$CT_ID" -- journalctl -u "$SERVICE_NAME" --no-pager -n 120 || true
  exit 1
fi
msg_ok "Web UI antwortet (HTTP 200 auf 127.0.0.1:${APP_PORT}/health)."

# Netzwerkpfad vom Host aus (nicht nur Loopback im Container)
if curl -fs -m 10 "http://${CT_IP}:${APP_PORT}/health" >/dev/null 2>&1; then
  msg_ok "Web UI erreichbar über http://${CT_IP}:${APP_PORT}"
else
  msg_warn "Web UI über ${CT_IP}:${APP_PORT} nicht erreichbar (Host-Firewall/Bridge prüfen)."
fi

# Pairing-Code frisch erzeugen und anzeigen (nur wenn Pairing aktiv)
PAIRCODE=""
if [[ "$PAIRING_ENABLED" == "1" ]]; then
  PAIRCODE="$(pct exec "$CT_ID" -- su -s /bin/bash "$APP_USER" -c \
    "HOME='$APP_HOME' '$BIN_PATH' --config-dir '$CONFIG_DIR' gateway get-paircode --new" 2>/dev/null \
    | grep -oE '[A-Za-z0-9]{20,}' | head -n1 || true)"
fi

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : ${APP_DISPLAY} – persönlicher AI-Assistant / Agent-Runtime"
echo "  Upstream     : ${UPSTREAM_REPO} (Release: ${ZEROCLAW_VERSION})"
echo "  Container    : CT ${CT_ID} (Hostname: ${HOSTNAME_ARG}, unprivilegiert, onboot=1)"
echo "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Health       : http://${CT_IP}:${APP_PORT}/health"
if [[ "$PAIRING_ENABLED" == "1" ]]; then
  echo "  Pairing-Code : ${PAIRCODE:-<nicht ermittelbar – siehe Log>} (einmalig, jetzt notieren!)"
  echo "                 Im Browser unter http://${CT_IP}:${APP_PORT} eingeben."
else
  echo "  Pairing      : deaktiviert (--no-pairing) – nur in vertrauenswürdigem LAN verwenden!"
fi
echo "  LLM          : im Dashboard (Quickstart/Onboarding) Provider + Modell + API-Key setzen"
echo "                 Optional lokales Ollama: http://<host>:11434/v1"
echo "  Service      : systemctl status ${SERVICE_NAME}  (im Container via: pct enter ${CT_ID})"
echo "  Update       : Skript erneut starten (idempotent); mit --version latest neues Release"
echo "  Deinstall    : pct stop ${CT_ID} && pct destroy ${CT_ID}"
echo "  Reboot-Test  : bash tests/proxmox-verify.sh ${CT_ID}"
echo "  Log          : ${LOG_FILE}"
echo "══════════════════════════════════════════════════════════"
