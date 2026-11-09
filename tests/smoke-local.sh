#!/usr/bin/env bash
#
# Lokaler Smoke-Test – benötigt KEIN Proxmox.
# Prüft: Release-Download + SHA256, Config-Erzeugung, Daemon-Start,
#        /health (JSON), Dashboard (HTTP 200/HTML) und Pairing-Code.
#
# Usage: bash tests/smoke-local.sh
#        ZEROCLAW_VERSION=v0.8.7 bash tests/smoke-local.sh
#
set -euo pipefail

VERSION="${ZEROCLAW_VERSION:-v0.8.7}"
BASE_URL="https://github.com/zeroclaw-labs/zeroclaw/releases/download/${VERSION}"
TMP="$(mktemp -d /tmp/zeroclaw-smoke.XXXXXX)"
HOME_DIR="$TMP/home"
CFG="$HOME_DIR/.zeroclaw"
LOG="$TMP/daemon.log"
DPID=""

if command -v python3 >/dev/null 2>&1; then
  PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
else
  PORT="${ZEROCLAW_TEST_PORT:-43999}"
fi

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

cleanup() {
  local ec=$?
  if [[ -n "$DPID" ]] && kill -0 "$DPID" 2>/dev/null; then
    kill -TERM "$DPID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$DPID" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "$DPID" 2>/dev/null || true
  fi
  if [[ $ec -ne 0 ]]; then
    echo "[INFO] Daemon-Log ($LOG):" >&2
    tail -n 80 "$LOG" 2>/dev/null >&2 || true
    echo "[INFO] Temp-Verzeichnis behalten: $TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null || fail "Benoetigt: $cmd"
done

case "$(uname -m)" in
  x86_64|amd64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) TRIPLE="aarch64-unknown-linux-gnu" ;;
  *) fail "Nicht unterstuetzte Architektur: $(uname -m)" ;;
esac

ASSET="zeroclaw-${TRIPLE}.tar.gz"
echo "== ZeroClaw Smoke-Test =="
echo "Version : $VERSION"
echo "Asset   : $ASSET"
echo "Port    : $PORT"
echo "Temp    : $TMP"
echo

echo "-> Download SHA256SUMS + $ASSET ..."
curl -fsSL "$BASE_URL/SHA256SUMS" -o "$TMP/SHA256SUMS" || fail "SHA256SUMS nicht abrufbar."
EXPECTED="$(awk -v a="$ASSET" '$2==a || $2=="*"a {print $1}' "$TMP/SHA256SUMS")"
[[ -n "$EXPECTED" ]] || fail "Asset $ASSET fehlt in SHA256SUMS."
curl -fsSL "$BASE_URL/$ASSET" -o "$TMP/$ASSET" || fail "Download fehlgeschlagen."
ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "Checksum-Mismatch: $EXPECTED != $ACTUAL"
pass "SHA256 verifiziert ($ACTUAL)"

echo "-> Entpacke ..."
tar -xzf "$TMP/$ASSET" -C "$TMP"
BIN="$TMP/zeroclaw"
[[ -x "$BIN" ]] || fail "zeroclaw-Binary fehlt im Archiv."
[[ -f "$TMP/web/dist/index.html" ]] || fail "web/dist/index.html fehlt im Archiv."
pass "Archiv enthaelt Binary + Dashboard"

echo "-> Erzeuge Config ..."
mkdir -p "$HOME_DIR" "$CFG"
run_cfg() { HOME="$HOME_DIR" "$BIN" --config-dir "$CFG" "$@"; }
run_cfg config set gateway.host 0.0.0.0 >/dev/null
run_cfg config set gateway.port "$PORT" >/dev/null
run_cfg config set gateway.allow_public_bind true >/dev/null
run_cfg config set gateway.require_pairing true >/dev/null
[[ -f "$CFG/config.toml" ]] || fail "config.toml wurde nicht erzeugt."
grep -q 'schema_version' "$CFG/config.toml" || fail "schema_version fehlt."
grep -Eq "^port = ${PORT}$" "$CFG/config.toml" || fail "Port nicht in config.toml."
pass "Config erzeugt (Schema + Port)"

echo "-> Starte Daemon ..."
HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" \
  "$BIN" --config-dir "$CFG" daemon >"$LOG" 2>&1 &
DPID=$!
sleep 1
kill -0 "$DPID" 2>/dev/null || fail "Daemon sofort beendet."

echo "-> Warte auf /health (max. 30s) ..."
HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl -fsS -m 2 "http://127.0.0.1:${PORT}/health" -o "$TMP/health.json" 2>/dev/null; then
    HEALTH_OK=1
    break
  fi
  kill -0 "$DPID" 2>/dev/null || fail "Daemon waehrend Start beendet (siehe Log)."
  sleep 1
done
[[ "$HEALTH_OK" == "1" ]] || fail "Kein /health nach 30s."
grep -q '"status":"ok"' "$TMP/health.json" || fail "/health ohne status=ok: $(cat "$TMP/health.json")"
pass "/health liefert status=ok"

echo "-> Pruefe Dashboard / ..."
CODE="$(curl -s -o "$TMP/index.html" -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
[[ "$CODE" == "200" ]] || fail "Dashboard HTTP $CODE (erwartet 200)."
grep -qi '<html' "$TMP/index.html" || fail "Dashboard liefert kein HTML."
pass "Dashboard HTTP 200 (HTML, $(wc -c <"$TMP/index.html") Bytes)"

echo "-> Erzeuge Pairing-Code ..."
PAIRCODE="$(HOME="$HOME_DIR" "$BIN" --config-dir "$CFG" gateway get-paircode --new 2>/dev/null \
  | grep -oE '[A-Za-z0-9]{20,}' | head -n1 || true)"
[[ -n "$PAIRCODE" ]] || fail "Kein Pairing-Code erhalten."
pass "Pairing-Code: ${PAIRCODE:0:6}… (${#PAIRCODE} Zeichen)"

echo "-> Prüfe Pairing=off (Config-Schreibpfad) ..."
run_cfg config set gateway.require_pairing false >/dev/null
grep -q 'require_pairing = false' "$CFG/config.toml" \
  || fail "require_pairing=false wurde nicht geschrieben."
pass "require_pairing=false wird korrekt geschrieben."

echo
echo "== ALLE LOKALEN TESTS BESTANDEN =="
