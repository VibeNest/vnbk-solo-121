#!/bin/bash
set -uo pipefail

: "${VN_POLL_URL:?VN_POLL_URL required}"
: "${VN_SECRET:?VN_SECRET required}"
: "${VN_STARTUP_ID:?VN_STARTUP_ID required}"
: "${VN_TARGETS:?VN_TARGETS required}"
INTERVAL="${VN_POLL_INTERVAL:-15}"
AUTH="Authorization: Bearer ${VN_SECRET}"

log() { echo "[vibenest-backup] $(date -u +%H:%M:%S) $*"; }
log "sidecar up; polling ${VN_POLL_URL} every ${INTERVAL}s for startup ${VN_STARTUP_ID}"

# Report a job result back to the platform.
report() { # $1=jobId $2=success(true|false) $3=sizeBytes $4=error
  curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    --max-time 30 \
    -d "{\"success\":$2,\"sizeBytes\":${3:-0},\"error\":$(jq -Rn --arg e "${4:-}" '$e')}" \
    "${VN_POLL_URL}/$1/complete" >/dev/null \
    && log "reported job $1 success=$2" || log "WARN: failed to report job $1"
}

target_field() { # $1=service $2=field
  echo "$VN_TARGETS" | jq -r --arg s "$1" --arg f "$2" '.[] | select(.service==$s) | .[$f] // empty'
}

backup_postgres() { # $1=host $2=port $3=user $4=pass $5=db -> writes /tmp/art, echoes size or "ERR:msg"
  local out=/tmp/art.dump
  if ! PGPASSWORD="$4" pg_dump -Fc -h "$1" -p "$2" -U "$3" -d "$5" -f "$out" 2> /tmp/err; then
    echo "ERR:pg_dump failed: $(tr -d '\n' < /tmp/err | tail -c 400)"; return 1; fi
  stat -c %s "$out"
}
restore_postgres() { # $1=host $2=port $3=user $4=pass $5=db (reads /tmp/art)
  if ! PGPASSWORD="$4" pg_restore --clean --if-exists --no-owner --no-acl \
       -h "$1" -p "$2" -U "$3" -d "$5" /tmp/art.dump 2> /tmp/err; then
    # pg_restore emits non-fatal warnings on --clean; treat exit>0 with no "error:" lines as ok
    if grep -qi "error:" /tmp/err; then echo "ERR:pg_restore: $(tr -d '\n' < /tmp/err | tail -c 400)"; return 1; fi
  fi
  echo ok
}

qdrant_base() { local h="$1" p="$2" k="$3"; echo "http://${h}:${p}"; }
qdrant_hdr() { [ -n "${1:-}" ] && echo "-H" && echo "api-key: $1"; }

backup_qdrant() { # $1=host $2=port $3=apiKey -> writes /tmp/art, echoes size or "ERR:msg"
  local base; base=$(qdrant_base "$1" "$2" "$3"); local KH=(); [ -n "$3" ] && KH=(-H "api-key: $3")
  rm -rf /tmp/qd && mkdir -p /tmp/qd
  local cols; cols=$(curl -sf "${KH[@]}" --max-time 30 "${base}/collections" | jq -r '.result.collections[].name')
  if [ -z "$cols" ]; then tar -czf /tmp/art -C /tmp/qd . ; stat -c %s /tmp/art; return 0; fi
  local c snap
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    snap=$(curl -sf "${KH[@]}" -X POST --max-time 120 "${base}/collections/${c}/snapshots" | jq -r '.result.name')
    if [ -z "$snap" ] || [ "$snap" = "null" ]; then echo "ERR:qdrant snapshot create failed for ${c}"; return 1; fi
    if ! curl -sf "${KH[@]}" --max-time 300 -o "/tmp/qd/${c}.snapshot" "${base}/collections/${c}/snapshots/${snap}"; then
      echo "ERR:qdrant snapshot download failed for ${c}"; return 1; fi
  done <<< "$cols"
  tar -czf /tmp/art -C /tmp/qd . && stat -c %s /tmp/art
}
restore_qdrant() { # $1=host $2=port $3=apiKey (reads /tmp/art)
  local base; base=$(qdrant_base "$1" "$2" "$3"); local KH=(); [ -n "$3" ] && KH=(-H "api-key: $3")
  rm -rf /tmp/qd && mkdir -p /tmp/qd && tar -xzf /tmp/art -C /tmp/qd
  local f c
  for f in /tmp/qd/*.snapshot; do
    [ -e "$f" ] || continue
    c=$(basename "$f" .snapshot)
    if ! curl -sf "${KH[@]}" -X POST --max-time 300 \
         -F "snapshot=@${f}" "${base}/collections/${c}/snapshots/upload?priority=snapshot" >/dev/null; then
      echo "ERR:qdrant recover failed for ${c}"; return 1; fi
  done
  echo ok
}

run_job() { # reads job json on stdin
  local job; job=$(cat)
  local id type engine service
  id=$(echo "$job" | jq -r '.id'); type=$(echo "$job" | jq -r '.type')
  engine=$(echo "$job" | jq -r '.engine'); service=$(echo "$job" | jq -r '.service')
  local url; url=$(echo "$job" | jq -r '.url')
  log "job $id: $type $engine/$service"

  local host port user pass db apiKey
  host=$(target_field "$service" host); port=$(target_field "$service" port)
  user=$(target_field "$service" user); pass=$(target_field "$service" password)
  db=$(target_field "$service" db); apiKey=$(target_field "$service" apiKey)
  [ -z "$host" ] && host="$service"

  local res size
  if [ "$type" = "backup" ]; then
    case "$engine" in
      postgres) res=$(backup_postgres "$host" "$port" "$user" "$pass" "$db") ;;
      qdrant)   res=$(backup_qdrant "$host" "$port" "$apiKey") ;;
      *) report "$id" false 0 "engine $engine not supported"; return ;;
    esac
    if [[ "$res" == ERR:* ]]; then report "$id" false 0 "${res#ERR:}"; return; fi
    size="$res"
    if ! curl -sf -X PUT --max-time 600 -T /tmp/art "$url" >/dev/null 2>/tmp/err; then
      report "$id" false 0 "upload failed: $(tr -d '\n' < /tmp/err | tail -c 300)"; return; fi
    report "$id" true "$size" ""
  elif [ "$type" = "restore" ]; then
    if ! curl -sf --max-time 600 -o /tmp/art "$url" 2>/tmp/err; then
      report "$id" false 0 "download failed: $(tr -d '\n' < /tmp/err | tail -c 300)"; return; fi
    case "$engine" in
      postgres) res=$(restore_postgres "$host" "$port" "$user" "$pass" "$db") ;;
      qdrant)   res=$(restore_qdrant "$host" "$port" "$apiKey") ;;
      *) report "$id" false 0 "engine $engine not supported"; return ;;
    esac
    if [[ "$res" == ERR:* ]]; then report "$id" false 0 "${res#ERR:}"; return; fi
    report "$id" true 0 ""
  else
    report "$id" false 0 "unknown job type $type"
  fi
}

while true; do
  job=$(curl -sf -H "$AUTH" --max-time 30 "${VN_POLL_URL}/next?startupId=${VN_STARTUP_ID}" 2>/dev/null)
  if [ -n "$job" ] && [ "$(echo "$job" | jq -r '.id // empty')" != "" ]; then
    echo "$job" | run_job
  fi
  sleep "$INTERVAL"
done