#!/usr/bin/env bash
#
# Reboot-/Service-/Health-Verifikation auf dem Proxmox-Host.
# Startet den Container neu und prüft, ob ZeroClaw automatisch wieder hochkommt.
#
# Usage: sudo bash tests/proxmox-verify.sh <CT-ID> [IP]
#        APP_PORT=42617 sudo bash tests/proxmox-verify.sh 150
#
set -euo pipefail

CT_ID="${1:-${CT_ID:-}}"
PORT="${APP_PORT:-42617}"
SERVICE="zeroclaw"

die()  { echo "[ERROR] $*" >&2; exit 1; }
pass() { echo "[PASS]  $*"; }
fail() { echo "[FAIL]  $*" >&2; FAILED=1; }

FAILED=0
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null || die "pct nicht gefunden – kein Proxmox-Host?"
[[ -n "$CT_ID" ]] || die "Usage: $0 <CT-ID> [IP]"
pct status "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID existiert nicht."

CT_IP="${2:-}"
if [[ -z "$CT_IP" ]]; then
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {print $i; exit}}' || true)"
fi

echo "== Proxmox-Verifikation =="
echo "CT     : $CT_ID"
echo "IP     : ${CT_IP:-<wird nach Start ermittelt>}"
echo "Port   : $PORT"
echo "Service: $SERVICE"
echo

if pct status "$CT_ID" | grep -q 'status: stopped'; then
  echo "-> CT ist gestoppt – starte ..."
  pct start "$CT_ID"
else
  echo "-> Reboot CT $CT_ID ..."
  pct reboot "$CT_ID"
fi
sleep 5

echo "-> Warte auf Service (max. 2 Min) ..."
UP=0
for _ in $(seq 1 60); do
  if pct exec "$CT_ID" -- systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    UP=1
    break
  fi
  sleep 2
done
if [[ "$UP" == "1" ]]; then
  pass "Service ist nach Reboot active."
else
  fail "Service ist nach Reboot nicht active."
fi

if pct exec "$CT_ID" -- systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
  pass "Service ist enabled (startet bei Boot)."
else
  fail "Service ist nicht enabled."
fi

# Nach dem Reboot ggf. neue DHCP-IP übernehmen
NEW_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {print $i; exit}}' || true)"
if [[ -n "$NEW_IP" ]]; then
  CT_IP="$NEW_IP"
fi
[[ -n "$CT_IP" ]] || die "Keine CT-IP nach Reboot ermittelbar."

echo "-> Prüfe /health im Container ..."
if pct exec "$CT_ID" -- curl -fsS -m 10 "http://127.0.0.1:${PORT}/health" -o /tmp/zc-health.json 2>/dev/null; then
  if grep -q '"status":"ok"' /tmp/zc-health.json; then
    pass "/health (localhost) liefert status=ok."
  else
    fail "/health (localhost) ohne status=ok: $(cat /tmp/zc-health.json 2>/dev/null)"
  fi
else
  fail "/health (localhost) nicht erreichbar."
fi

echo "-> Prüfe /health über CT-IP ..."
if curl -fsS -m 10 "http://${CT_IP}:${PORT}/health" -o /tmp/zc-health-ip.json 2>/dev/null; then
  if grep -q '"status":"ok"' /tmp/zc-health-ip.json; then
    pass "/health (${CT_IP}) liefert status=ok."
  else
    fail "/health (${CT_IP}) ohne status=ok: $(cat /tmp/zc-health-ip.json 2>/dev/null)"
  fi
else
  fail "/health (${CT_IP}) nicht erreichbar (Host-Firewall/Bridge prüfen)."
fi

echo "-> Prüfe Dashboard ..."
CODE="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://${CT_IP}:${PORT}/" || true)"
if [[ "$CODE" == "200" ]]; then
  pass "Dashboard HTTP 200."
else
  fail "Dashboard HTTP $CODE (erwartet 200)."
fi

echo "-> Letzte Service-Logs ..."
pct exec "$CT_ID" -- journalctl -u "$SERVICE" --no-pager -n 40 || true

echo
if [[ "$FAILED" == "0" ]]; then
  echo "== VERIFIKATION BESTANDEN =="
  exit 0
else
  echo "== VERIFIKATION FEHLGESCHLAGEN ==" >&2
  exit 1
fi
