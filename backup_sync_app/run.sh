#!/usr/bin/with-contenv bashio
# shellcheck shell=bash disable=SC2034,SC2053
# ==============================================================================
# Backup Sync
#   1. waits until the newest Home Assistant backup is completely written
#   2. uploads it with rsync over SSH (resumable; written to <name>.part first)
#   3. renames it on the server once complete and applies the retention policy
#   4. reports status/progress to the "backup_sync" integration in HA
# ==============================================================================
set -o pipefail

readonly BACKUP_DIR="/backup"
readonly CFG_DIR="/config"
readonly KEY_FILE="${CFG_DIR}/id_ed25519"
readonly KNOWN_HOSTS="${CFG_DIR}/known_hosts"
readonly LAST_FILE="/data/last_run.json"
readonly STATE_FILE="/tmp/sync_state.json"
readonly EVENT_URL="http://supervisor/core/api/events/backup_sync_update"
readonly HEARTBEAT_SECONDS=30
readonly INFO_PROGRESS_SECONDS=600

# ------------------------------------------------------------------ options ---
bashio::log.level "$(bashio::config 'log_level')"

HOST=$(bashio::config 'host')
PORT=$(bashio::config 'port')
USER_NAME=$(bashio::config 'user')
RPATH=$(bashio::config 'remote_path')
KEEP=$(bashio::config 'keep_count')
PATTERN=$(bashio::config 'file_pattern')
ONLY_NEWEST=$(bashio::config 'only_newest')
STABLE=$(bashio::config 'stable_seconds')
MAX_ATTEMPTS=$(bashio::config 'max_attempts')
RETRY_DELAY=$(bashio::config 'retry_delay')
BWLIMIT=$(bashio::config 'bandwidth_limit_kbps')
REPORT=$(bashio::config 'report_to_homeassistant')
REPORT_INTERVAL=$(bashio::config 'report_interval')
RPATH=${RPATH%/}

# -------------------------------------------------------------------- state ---
STATUS="starting"
CURRENT_FILE=""
BYTES_DONE=0
BYTES_TOTAL=0
SPEED=0
ETA=0
LAST_SUCCESS_TS=0
LAST_ERROR=""
REMOTE_COUNT=-1
REMOTE_SIZE=""
HB_PID=""
RSYNC_PID=""
declare -a UPLOADED=()

SSH_OPTS=(-i "$KEY_FILE" -p "$PORT"
  -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o ConnectTimeout=20)
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

# ------------------------------------------------------------------ helpers ---
now() { date +%s; }

# Human readable bytes / durations
hb() {
  awk -v b="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'
}
hd() {
  local s=${1:-0}
  printf '%dh %02dm %02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

# Quote a string for safe use inside a remote shell command
shq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

in_array() {
  local needle=$1 item
  shift
  for item in "$@"; do [[ $item == "$needle" ]] && return 0; done
  return 1
}

# ------------------------------------------------------- state & reporting ---
load_last() {
  [[ -f $LAST_FILE ]] || return 0
  LAST_SUCCESS_TS=$(jq -r '.last_success_ts // 0' "$LAST_FILE" 2>/dev/null || echo 0)
  LAST_ERROR=$(jq -r '.last_error // ""' "$LAST_FILE" 2>/dev/null || echo "")
  REMOTE_COUNT=$(jq -r '.remote_count // -1' "$LAST_FILE" 2>/dev/null || echo -1)
  [[ $LAST_SUCCESS_TS =~ ^[0-9]+$ ]] || LAST_SUCCESS_TS=0
  [[ $REMOTE_COUNT =~ ^-?[0-9]+$ ]] || REMOTE_COUNT=-1
}

save_last() {
  jq -nc --argjson ts "$LAST_SUCCESS_TS" --arg err "$LAST_ERROR" --argjson rc "$REMOTE_COUNT" \
    '{last_success_ts: $ts, last_error: $err, remote_count: $rc}' >"$LAST_FILE" 2>/dev/null || true
}

# Writes the current state to a file; the heartbeat re-sends this file.
write_state() {
  jq -nc \
    --arg status "$STATUS" --arg file "$CURRENT_FILE" \
    --argjson bytes_done "$BYTES_DONE" --argjson bytes_total "$BYTES_TOTAL" \
    --argjson speed "$SPEED" --argjson eta "$ETA" \
    --argjson last_success "$LAST_SUCCESS_TS" --arg last_error "$LAST_ERROR" \
    --argjson remote_count "$REMOTE_COUNT" \
    '{status: $status, file: $file, bytes_done: $bytes_done, bytes_total: $bytes_total,
      speed: $speed, eta_seconds: $eta, last_success_ts: $last_success,
      last_error: $last_error, remote_count: $remote_count}' \
    >"${STATE_FILE}.$$" && mv -f "${STATE_FILE}.$$" "$STATE_FILE"
}

# Fires the event that the custom integration listens to. Never fatal.
send_state() {
  [[ $REPORT == "true" && -f $STATE_FILE ]] || return 0
  local out
  if ! out=$(curl -fsS -m 10 -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data @"$STATE_FILE" "$EVENT_URL" 2>&1); then
    bashio::log.debug "Could not report state to Home Assistant: ${out}"
    return 1
  fi
  bashio::log.trace "State sent: $(cat "$STATE_FILE")"
  return 0
}

set_status() {
  STATUS=$1
  write_state
  send_state || true
}

heartbeat() {
  while sleep "$HEARTBEAT_SECONDS"; do send_state || true; done
}

# Make sure the last state reaches HA even if it is restarting right now.
final_push() {
  [[ $REPORT == "true" ]] || return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    send_state && return 0
    bashio::log.debug "Home Assistant not reachable yet (${i}/10), retrying in ${HEARTBEAT_SECONDS}s"
    sleep "$HEARTBEAT_SECONDS"
  done
  bashio::log.warning "Could not deliver the final state to Home Assistant"
}

die() {
  LAST_ERROR=$1
  bashio::log.error "$1"
  STATUS="error"
  SPEED=0
  ETA=0
  write_state
  save_last
  send_state || true
  final_push
  exit 1
}

# ------------------------------------------------------------- ssh helpers ---
rssh() { ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" "$@"; }

# Run a command through "sh -c" on the server (independent of the login shell)
rsh() { rssh "sh -c $(shq "$1")"; }

# retry <description> <command...> - runs the command until it succeeds
retry() {
  local what=$1
  shift
  local n=0 prev=$STATUS
  until "$@"; do
    n=$((n + 1))
    if ((n >= MAX_ATTEMPTS)); then
      bashio::log.error "${what}: giving up after ${n} attempts"
      return 1
    fi
    bashio::log.warning "${what} failed (attempt ${n}/${MAX_ATTEMPTS}) - retrying in ${RETRY_DELAY}s"
    set_status retrying
    sleep "$RETRY_DELAY"
  done
  if ((n > 0)); then set_status "$prev"; fi
  return 0
}

# Sets REMOTE_SIZE to the size in bytes or MISSING. Returns the ssh exit code.
remote_size() {
  local p out rc
  p=$(shq "$1")
  out=$(rsh "if [ -f ${p} ]; then wc -c < ${p}; else echo MISSING; fi")
  rc=$?
  REMOTE_SIZE=$(printf '%s' "$out" | tr -d '[:space:]')
  return $rc
}

check_remote_space() {
  local need=$1 line avail_kb avail
  line=$(rsh "df -Pk $(shq "$RPATH") | tail -n 1") || return 0
  read -r _ _ _ avail_kb _ <<<"$line"
  [[ $avail_kb =~ ^[0-9]+$ ]] || return 0
  avail=$((avail_kb * 1024))
  bashio::log.debug "Free space on server: $(hb "$avail"), still needed: $(hb "$need")"
  if ((avail < need)); then
    bashio::log.warning "Server has only $(hb "$avail") free but about $(hb "$need") are needed"
  fi
  return 0
}

ensure_key() {
  mkdir -p "$CFG_DIR"
  if [[ ! -f $KEY_FILE ]]; then
    bashio::log.warning "No SSH key found - generating one"
    ssh-keygen -q -t ed25519 -N "" -C "backup-sync@homeassistant" -f "$KEY_FILE" ||
      die "Could not generate an SSH key"
    bashio::log.notice "Add this public key to ~/.ssh/authorized_keys of ${USER_NAME}@${HOST}:"
    bashio::log.notice "$(cat "${KEY_FILE}.pub")"
    die "SSH key generated - install the public key on the server, then start the add-on again"
  fi
  chmod 600 "$KEY_FILE"
}

# ---------------------------------------------------------------- local side ---
# Lists backups matching the pattern, newest first
list_local() {
  local n
  while IFS= read -r n; do
    [[ -f "${BACKUP_DIR}/${n}" ]] || continue
    [[ $n == $PATTERN ]] || continue
    printf '%s\n' "$n"
  done < <(ls -1t "$BACKUP_DIR")
}

# Waits until the file size has not changed for STABLE seconds
wait_stable() {
  local f=$1 last cur
  ((STABLE == 0)) && return 0
  last=$(stat -c %s "$f") || return 1
  while :; do
    bashio::log.debug "Waiting ${STABLE}s to make sure ${f##*/} is completely written"
    sleep "$STABLE"
    cur=$(stat -c %s "$f") || return 1
    [[ $cur == "$last" ]] && return 0
    bashio::log.info "Backup file is still growing ($(hb "$cur")), waiting ..."
    last=$cur
  done
}

# ------------------------------------------------------------------- rsync ---
# Reads rsync output from stdin (progress lines are separated by \r)
progress_loop() {
  local chunk line b t pct inst
  local last_t=0 last_b=-1 last_report=0 last_info=0 ema=0 first=1
  while IFS= read -r -d $'\r' chunk || [[ -n ${chunk:-} ]]; do
    while IFS= read -r line; do
      [[ -z ${line//[[:space:]]/} ]] && continue
      if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)% ]]; then
        b=${BASH_REMATCH[1]}
        t=$(now)
        BYTES_DONE=$b
        if ((first)); then
          first=0
          last_t=$t
          last_b=$b
          last_report=$t
          last_info=$t
          bashio::log.info "Transfer running (at $(hb "$b") of $(hb "$BYTES_TOTAL"))"
          set_status uploading
          continue
        fi
        if ((t - last_t >= 5)); then
          inst=$(((b - last_b) / (t - last_t)))
          ((inst < 0)) && inst=0
          if ((ema == 0)); then ema=$inst; else ema=$(((ema * 7 + inst * 3) / 10)); fi
          last_t=$t
          last_b=$b
        fi
        if ((t - last_report >= REPORT_INTERVAL)); then
          last_report=$t
          SPEED=$ema
          ETA=0
          ((ema > 0 && BYTES_TOTAL > b)) && ETA=$(((BYTES_TOTAL - b) / ema))
          write_state
          send_state || true
          pct=0
          ((BYTES_TOTAL > 0)) && pct=$((b * 100 / BYTES_TOTAL))
          bashio::log.debug "Progress: $(hb "$b") / $(hb "$BYTES_TOTAL") (${pct}%), $(hb "$SPEED")/s, ETA $(hd "$ETA")"
          if ((t - last_info >= INFO_PROGRESS_SECONDS)); then
            last_info=$t
            bashio::log.info "Progress: ${pct}% ($(hb "$b") of $(hb "$BYTES_TOTAL")), $(hb "$SPEED")/s, ETA $(hd "$ETA")"
          fi
        fi
      else
        case $line in
          *error* | rsync:* | ssh:* | Warning* | *"Permission denied"*)
            bashio::log.warning "rsync: ${line}"
            ;;
          *)
            bashio::log.debug "rsync: ${line}"
            ;;
        esac
      fi
    done <<<"$chunk"
    chunk=""
  done
}

# run_rsync <src> <remote dest path> [extra rsync options...]
run_rsync() {
  local src=$1 dest=$2
  shift 2
  local -a cmd=(rsync -s -t --inplace --partial --timeout=900
    --no-human-readable --info=progress2 --stats -e "$RSYNC_SSH")
  ((BWLIMIT > 0)) && cmd+=("--bwlimit=${BWLIMIT}")
  cmd+=("$@" "$src" "${USER_NAME}@${HOST}:${dest}")
  bashio::log.debug "Running: ${cmd[*]}"
  ("${cmd[@]}" 2>&1 | progress_loop; exit "${PIPESTATUS[0]}") &
  RSYNC_PID=$!
  wait "$RSYNC_PID"
  return $?
}

# upload_one <file name> <size>
upload_one() {
  local name=$1 total=$2
  local src="${BACKUP_DIR}/${name}" part="${RPATH}/${name}.part" final="${RPATH}/${name}"
  local attempt=0 rc part_size t_start elapsed
  local -a mode
  t_start=$(now)

  while ((attempt < MAX_ATTEMPTS)); do
    attempt=$((attempt + 1))
    if ! remote_size "$part"; then
      bashio::log.warning "Server not reachable (attempt ${attempt}/${MAX_ATTEMPTS}) - retrying in ${RETRY_DELAY}s"
      set_status retrying
      sleep "$RETRY_DELAY"
      continue
    fi
    part_size=$REMOTE_SIZE
    mode=()
    if [[ $part_size == "MISSING" ]]; then
      part_size=0
      bashio::log.info "Starting upload of ${name} ($(hb "$total"))"
    elif [[ ! $part_size =~ ^[0-9]+$ ]]; then
      bashio::log.warning "Unexpected answer from server while checking ${name}.part: '${part_size}'"
      sleep "$RETRY_DELAY"
      continue
    elif ((part_size > total)); then
      bashio::log.warning "Partial file on server is larger than the original - discarding it"
      rsh "rm -f -- $(shq "$part")"
      part_size=0
    elif ((part_size == total)); then
      bashio::log.info "Partial file on server already has the full size - verifying it by checksum"
      mode=(--checksum)
    elif ((part_size > 0)); then
      bashio::log.info "Resuming upload of ${name} at $(hb "$part_size") of $(hb "$total")"
      mode=(--append-verify)
    fi

    check_remote_space $((total - part_size))
    BYTES_DONE=$part_size
    SPEED=0
    ETA=0
    if ((${#mode[@]} > 0)); then
      # existing data is checksummed on both ends first - this can take a while
      set_status verifying
    else
      set_status uploading
    fi

    run_rsync "$src" "$part" "${mode[@]}"
    rc=$?

    if ((rc == 0)); then
      if ! rsh "mv -f -- $(shq "$part") $(shq "$final")"; then
        bashio::log.warning "Could not rename ${name}.part on the server - retrying"
        sleep "$RETRY_DELAY"
        continue
      fi
      if remote_size "$final" && [[ $REMOTE_SIZE == "$total" ]]; then
        BYTES_DONE=$total
        SPEED=0
        ETA=0
        elapsed=$(($(now) - t_start))
        ((elapsed < 1)) && elapsed=1
        bashio::log.info "Upload of ${name} complete: $(hb "$total") in $(hd "$elapsed") (average $(hb $((total / elapsed)))/s)"
        return 0
      fi
      bashio::log.warning "Size mismatch after upload (server: ${REMOTE_SIZE}, expected: ${total}) - removing the file and retrying"
      rsh "rm -f -- $(shq "$final")"
      continue
    fi

    bashio::log.warning "rsync exited with code ${rc} (attempt ${attempt}/${MAX_ATTEMPTS}) - retrying in ${RETRY_DELAY}s, partial data is kept"
    set_status retrying
    sleep "$RETRY_DELAY"
  done
  return 1
}

# --------------------------------------------------------------- retention ---
prune_remote() {
  set_status pruning
  local listing rc n base i
  listing=$(rsh "ls -1tp -- $(shq "$RPATH")")
  rc=$?
  if ((rc != 0)); then
    bashio::log.warning "Could not list ${RPATH} (exit code ${rc}) - skipping retention"
    return 1
  fi

  local -a finished=() stale=()
  while IFS= read -r n; do
    [[ -z $n || $n == */ ]] && continue
    if [[ $n == *.part ]]; then
      base=${n%.part}
      [[ $base == $PATTERN ]] && stale+=("$n")
      continue
    fi
    [[ $n == $PATTERN ]] && finished+=("$n")
  done <<<"$listing"

  # Safety net: everything uploaded in this run has to be visible in the listing
  for n in "${UPLOADED[@]}"; do
    if ! in_array "$n" "${finished[@]}"; then
      bashio::log.warning "Uploaded file ${n} is missing from the server listing - skipping retention"
      return 1
    fi
  done

  local total=${#finished[@]}
  REMOTE_COUNT=$total
  bashio::log.info "Retention: ${total} backup(s) on the server, keeping the newest ${KEEP}"
  for ((i = KEEP; i < total; i++)); do
    n=${finished[i]}
    in_array "$n" "${UPLOADED[@]}" && continue
    bashio::log.notice "Retention: deleting ${n}"
    if rsh "rm -f -- $(shq "${RPATH}/${n}")"; then
      REMOTE_COUNT=$((REMOTE_COUNT - 1))
    else
      bashio::log.warning "Could not delete ${n}"
    fi
  done

  # Leftover partial uploads whose original no longer exists locally can never be resumed
  for n in "${stale[@]}"; do
    base=${n%.part}
    if [[ ! -f "${BACKUP_DIR}/${base}" ]]; then
      bashio::log.notice "Retention: removing orphaned partial upload ${n}"
      rsh "rm -f -- $(shq "${RPATH}/${n}")" || bashio::log.warning "Could not delete ${n}"
    fi
  done
  return 0
}

# -------------------------------------------------------------------- main ---
on_exit() {
  [[ -n $HB_PID ]] && kill "$HB_PID" 2>/dev/null
  return 0
}

on_signal() {
  bashio::log.warning "Stop signal received - the upload will be resumed on the next start"
  pkill -TERM rsync 2>/dev/null
  STATUS="interrupted"
  LAST_ERROR="Interrupted by add-on stop (resumes on next start)"
  SPEED=0
  ETA=0
  write_state
  save_last
  send_state || true
  exit 143
}

main() {
  trap on_exit EXIT
  trap on_signal TERM INT

  bashio::log.info "Backup Sync started - target ${USER_NAME}@${HOST}:${RPATH}, keep ${KEEP}, only newest: ${ONLY_NEWEST}, pattern: ${PATTERN}"
  load_last
  write_state
  heartbeat &
  HB_PID=$!
  send_state || true

  [[ -n $HOST && -n $USER_NAME ]] || die "Please configure 'host' and 'user' in the add-on options"
  [[ -n $RPATH ]] || die "'remote_path' must not be empty or '/'"
  ensure_key

  set_status starting
  retry "Connecting to ${HOST}" rsh "mkdir -p -- $(shq "$RPATH")" ||
    die "Cannot reach ${HOST} - giving up"

  local -a local_files=() candidates=()
  local i name size
  mapfile -t local_files < <(list_local)
  ((${#local_files[@]} > 0)) || die "No local backups matching '${PATTERN}' found in ${BACKUP_DIR}"
  if [[ $ONLY_NEWEST == "true" ]]; then
    candidates=("${local_files[0]}")
  else
    # oldest first, so the newest backup is uploaded last
    for ((i = ${#local_files[@]} - 1; i >= 0; i--)); do candidates+=("${local_files[i]}"); done
  fi
  bashio::log.info "Candidates for upload: ${#candidates[@]} of ${#local_files[@]} local backup(s)"

  for name in "${candidates[@]}"; do
    CURRENT_FILE=$name
    BYTES_DONE=0
    set_status starting
    wait_stable "${BACKUP_DIR}/${name}" || die "Cannot read ${BACKUP_DIR}/${name}"
    size=$(stat -c %s "${BACKUP_DIR}/${name}")
    BYTES_TOTAL=$size
    retry "Checking the remote copy of ${name}" remote_size "${RPATH}/${name}" ||
      die "Cannot check the remote copy of ${name}"
    if [[ $REMOTE_SIZE == "$size" ]]; then
      bashio::log.info "${name} is already on the server ($(hb "$size")) - nothing to upload"
      BYTES_DONE=$size
      continue
    fi
    [[ $REMOTE_SIZE != "MISSING" ]] &&
      bashio::log.notice "${name} exists on the server with a different size (${REMOTE_SIZE}) - it will be replaced"
    upload_one "$name" "$size" || die "Upload of ${name} failed after ${MAX_ATTEMPTS} attempts"
    UPLOADED+=("$name")
  done

  prune_remote || bashio::log.warning "Retention step was skipped"

  LAST_ERROR=""
  LAST_SUCCESS_TS=$(now)
  SPEED=0
  ETA=0
  STATUS="idle"
  save_last
  write_state
  send_state || true
  final_push
  bashio::log.info "Done"
}

# Only run when executed directly (allows sourcing the functions for tests)
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
  exit 0
fi
