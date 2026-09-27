#!/usr/bin/env bash
# healthwatch.sh - Memantau endpoint /health, mendeteksi transisi status, dan menghitung MTTR
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.0.0"

INTERVAL=5
URL="http://127.0.0.1:5000/health"

TOTAL_CHECKS=0
TOTAL_INCIDENTS=0
TOTAL_DOWNTIME=0
LAST_STATUS="UNKNOWN"
DOWN_SINCE=0
SESSION_START=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "GALAT: $*"; exit 1; }

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION - pemantau kesehatan endpoint
Penggunaan: $SCRIPT_NAME [--interval N] [--url URL]
  --interval N   Interval pemeriksaan dalam detik (default: 5)
  --url URL      URL endpoint health check (default: http://127.0.0.1:5000/health)
  -h, --help     Tampilkan bantuan ini
Exit code: 0 = tidak ada insiden, 2 = terjadi insiden, 1 = galat penggunaan
USAGE
}

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

check_health() {
  local start_ns end_ns elapsed_ms http_code
  start_ns=$(date +%s%N)
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null || echo "000")
  end_ns=$(date +%s%N)
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [[ "$http_code" == "200" ]]; then
    printf 'UP %s\n' "$elapsed_ms"
  else
    printf 'DOWN %s\n' "$elapsed_ms"
  fi
}

print_summary() {
  local now duration avail
  now=$(date +%s)
  duration=$(( now - SESSION_START ))

  if [[ "$LAST_STATUS" == "DOWN" && "$DOWN_SINCE" -gt 0 ]]; then
    TOTAL_DOWNTIME=$(( TOTAL_DOWNTIME + (now - DOWN_SINCE) ))
  fi

  if (( duration > 0 )); then
    avail=$(awk -v d="$duration" -v dt="$TOTAL_DOWNTIME" 'BEGIN { printf "%.2f", (d-dt)/d*100 }')
  else
    avail="100.00"
  fi

  printf '\n'
  log "=== Ringkasan Sesi ==="
  log "Jumlah pemeriksaan   : $TOTAL_CHECKS"
  log "Jumlah insiden       : $TOTAL_INCIDENTS"
  log "Total waktu padam    : ${TOTAL_DOWNTIME}s"
  log "Ketersediaan         : ${avail}%"

  if (( TOTAL_INCIDENTS > 0 )); then
    exit 2
  else
    exit 0
  fi
}

trap print_summary SIGINT

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)
        INTERVAL="$2"; shift 2 ;;
      --url)
        URL="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        usage >&2; die "argumen tidak dikenal: $1" ;;
    esac
  done

  if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL <= 0 )); then
    die "--interval harus berupa angka positif"
  fi
  [[ "$URL" =~ ^https?:// ]] || die "--url harus diawali http:// atau https://"

  SESSION_START=$(date +%s)
  log "Memulai pemantauan $URL setiap ${INTERVAL}s. Tekan Ctrl+C untuk berhenti."

  while true; do
    local result status elapsed
    result="$(check_health)"
    status="${result%% *}"
    elapsed="${result##* }"
    TOTAL_CHECKS=$(( TOTAL_CHECKS + 1 ))

    printf '%s STATUS=%s RESPONSE_MS=%s\n' "$(ts)" "$status" "$elapsed"

    if [[ "$status" == "DOWN" && "$LAST_STATUS" != "DOWN" ]]; then
      DOWN_SINCE=$(date +%s)
      TOTAL_INCIDENTS=$(( TOTAL_INCIDENTS + 1 ))
      log "Insiden dimulai: layanan DOWN"
    elif [[ "$status" == "UP" && "$LAST_STATUS" == "DOWN" ]]; then
      local now mttr
      now=$(date +%s)
      mttr=$(( now - DOWN_SINCE ))
      TOTAL_DOWNTIME=$(( TOTAL_DOWNTIME + mttr ))
      log "Layanan pulih. MTTR insiden ini: ${mttr}s"
    fi

    LAST_STATUS="$status"
    sleep "$INTERVAL"
  done
}

main "$@"
