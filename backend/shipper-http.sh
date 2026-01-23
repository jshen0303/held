#!/usr/bin/env sh
set -eu

# Loads SUPABASE_URL / optional HELD_FUNCTION_URL from your .env if provided
if [ -n "${HELD_ENV_FILE:-}" ] && [ -f "$HELD_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$HELD_ENV_FILE"
fi

derive_func_url() {
  if [ -n "${HELD_FUNCTION_URL:-}" ]; then
    printf '%s' "$HELD_FUNCTION_URL"; return
  fi
  if [ -z "${SUPABASE_URL:-}" ]; then
    echo "HELD_FUNCTION_URL or SUPABASE_URL is required" >&2; exit 1
  fi
  proj="$(printf '%s' "$SUPABASE_URL" | sed -E 's#https?://([^/]+)\.supabase\.co.*#\1#')"
  printf 'https://%s.functions.supabase.co/ship-commands' "$proj"
}

FUNCTION_URL="$(derive_func_url)"

# Read JWT saved by the Hyper plugin
JWT="$(python3 - <<'PY'
import json, os
p=os.path.expanduser("~/.HELD/session.json")
try:
    with open(p) as f: print(json.load(f).get("access_token",""))
except Exception: print("")
PY
)"
[ -n "$JWT" ] || { echo "No JWT (~/.HELD/session.json). Sign in first." >&2; exit 1; }

rotate="${SHIP_ROTATE:-0}"
logfile="${HELD_LOG_FILE:-$HELD_LOG_DIR/dump.jsonl}"
[ -n "${HELD_LOG_DIR:-}" ] || HELD_LOG_DIR="$(dirname "$logfile")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"; pid="$$"
out="${HELD_LOG_DIR%/}/.shipper-http.out"

# --- ROTATE path: make a snapshot, truncate live, then remove snapshot on success
if [ "$rotate" = "1" ]; then
  snap="${logfile}.ship-${stamp}-${pid}"
  [ -f "$logfile" ] && mv "$logfile" "$snap" || : 
  : > "$logfile"; chmod 600 "$logfile" 2>/dev/null || true

  code="$(curl -sS -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/x-ndjson" \
    ${HELD_TEAM_ID:+-H "x-HELD-team-id: $HELD_TEAM_ID"} \
    --data-binary "@${snap}" \
    -o "$out" -w "%{http_code}" \
    "$FUNCTION_URL")"

  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    [ "${SHIP_DEBUG:-0}" = "1" ] && echo "✓ upsert ok ($(wc -l < "$snap" 2>/dev/null || echo 0) rows)"
    rm -f "$snap"
    exit 0
  else
    echo "❌ edge function error http=$code url=$FUNCTION_URL" >&2
    exit 1
  fi
fi

# --- STREAM path (no temp files): send exact byte snapshot of the current file
# Figure out file size at start (macOS/BSD stat first, then GNU)
get_size() {
  s="$(stat -f%z "$logfile" 2>/dev/null || true)"
  if [ -z "$s" ]; then s="$(stat -c%s "$logfile" 2>/dev/null || true)"; fi
  printf '%s' "${s:-0}"
}

if [ ! -f "$logfile" ]; then
  # nothing to ship
  exit 0
fi

size="$(get_size)"
# If empty, nothing to send
if [ "${size:-0}" -eq 0 ] 2>/dev/null; then
  exit 0
fi

# Stream only the first $size bytes (snapshot at time-of-read) to curl stdin
code="$(
  head -c "$size" "$logfile" | curl -sS -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/x-ndjson" \
    ${HELD_TEAM_ID:+-H "x-HELD-team-id: $HELD_TEAM_ID"} \
    --data-binary @- \
    -o "$out" -w "%{http_code}" \
    "$FUNCTION_URL"
)"

if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  [ "${SHIP_DEBUG:-0}" = "1" ] && echo "✓ upsert ok (stream)"
  exit 0
else
  echo "❌ edge function error http=$code url=$FUNCTION_URL" >&2
  exit 1
fi
