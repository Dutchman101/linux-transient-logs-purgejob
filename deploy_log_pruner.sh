deploy_log_pruner() {
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be root"; return 1; fi

##############################################################################
# CONFIG - edit per box
#
# Each line in PRUNE_CONF uses `|` separators:
# path | type | post-clean command (optional)
#
# type = "files" -> delete regular files only (leave subdirs untouched)
# type = "all" -> delete all non-directory entries (files, symlinks, etc.)
#
# post-clean command runs after that path is cleaned (e.g. reopen logs)
# leave blank for none; must be a simple command (no pipes or redirects)
# full-line comments beginning with # are allowed; inline comments are not
#
# Examples:
# /srv/www/other/logs | files | nginx -s reopen
# /var/log/myapp | all | systemctl reload rsyslog
# /tmp/scratch | files |
#
# Tested on: Debian 9-13, Ubuntu 18+, RHEL/CentOS 7+, Alpine 3.14+
# Requires: bash, find, rm, du, tail, grep, date
# Scheduler: systemd timer if available, otherwise periodic cron/root crontab
# with an internal interval gate derived from TIMER_INTERVAL
##############################################################################
PRUNE_CONF=(
  "/srv/www/other/logs | files | nginx -s reopen"
)
TIMER_INTERVAL="3d"
TIMER_BOOT_DELAY="20min"
##############################################################################

MYHOST="$(hostname -s 2>/dev/null || hostname)"
CONF_PATH="/etc/log-pruner.conf"
SCRIPT_PATH="/usr/local/sbin/log-pruner.sh"
SERVICE_NAME="log-pruner"
LOG_PATH="/var/log/log-pruner.log"
BASH_BIN="$(command -v bash)"
[ -n "$BASH_BIN" ] || { echo "ERROR: bash not found"; return 1; }

interval_to_seconds() {
  local interval="${1-}" num unit mult
  case "$interval" in
    ''|*[!0-9smhdw]*) return 1 ;;
  esac
  num="${interval%[smhdw]}"
  unit="${interval#$num}"
  [ -n "$num" ] || return 1
  [ "$num" -gt 0 ] 2>/dev/null || return 1
  case "$unit" in
    s) mult=1 ;;
    m) mult=60 ;;
    h) mult=3600 ;;
    d) mult=86400 ;;
    w) mult=604800 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$((num * mult))"
}

MIN_INTERVAL_SECONDS="$(interval_to_seconds "$TIMER_INTERVAL")" || {
  echo "ERROR: TIMER_INTERVAL must use a simple value like 30m, 12h, 3d, or 1w"
  return 1
}

derive_cron_schedule() {
  local seconds="${1-}"
  [ -n "$seconds" ] || return 1
  case "$seconds" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$seconds" -le 3600 ]; then
    printf '%s\n' '* * * * *'
  elif [ "$seconds" -le 86400 ]; then
    printf '%s\n' '*/15 * * * *'
  else
    printf '%s\n' '0 * * * *'
  fi
}

CRON_SCHEDULE="$(derive_cron_schedule "$MIN_INTERVAL_SECONDS")" || {
  echo "ERROR: could not derive cron schedule from TIMER_INTERVAL"
  return 1
}

for cmd in find rm du tail grep date mv mkdir chmod; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing required command: $cmd"; return 1; }
done

mkdir -p "${SCRIPT_PATH%/*}"
: > "$CONF_PATH"
for entry in "${PRUNE_CONF[@]}"; do
  echo "$entry" >> "$CONF_PATH"
done
chmod 644 "$CONF_PATH"

printf '#!%s\n' "$BASH_BIN" > "$SCRIPT_PATH"
cat >> "$SCRIPT_PATH" <<'PRUNER'
if [ -z "${BASH_VERSION:-}" ]; then echo "ERROR: requires bash, not $0"; exit 1; fi
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -uo pipefail

CONF="/etc/log-pruner.conf"
[ -f "$CONF" ] || { echo "ERROR: missing $CONF"; exit 1; }
STATE_DIR="/var/lib/log-pruner"
STAMP_FILE="${STATE_DIR}/last-successful-run"

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

run_post_command() {
  local post="${1-}"
  local nginx_pid
  local -a post_argv

  case "$post" in
    "nginx -s reopen")
      command -v nginx >/dev/null 2>&1 || { echo "ERROR: nginx not found"; return 1; }
      if ! nginx -s reopen; then
        nginx_pid="$(cat /run/nginx.pid 2>/dev/null || cat /var/run/nginx.pid 2>/dev/null || true)"
        [ -n "$nginx_pid" ] || { echo "ERROR: nginx reopen failed and no pid file found"; return 1; }
        kill -USR1 "$nginx_pid"
      fi
      return 0
      ;;
  esac

  IFS=$' \t' read -r -a post_argv <<< "$post"
  [ "${#post_argv[@]}" -gt 0 ] || return 0
  "${post_argv[@]}"
}

MAX_LOG_KB=512
LOGFILE="/var/log/log-pruner.log"
if [ -f "$LOGFILE" ]; then
  log_kb="$(du -k "$LOGFILE" 2>/dev/null | { read -r kb _ || true; printf '%s' "${kb:-0}"; })"
  if [ "${log_kb:-0}" -gt "$MAX_LOG_KB" ]; then
    tail -c 65536 "$LOGFILE" > "${LOGFILE}.tmp" 2>/dev/null && mv "${LOGFILE}.tmp" "$LOGFILE" || rm -f "${LOGFILE}.tmp"
  fi
fi

if [ "${LOG_PRUNER_USE_STAMP:-0}" = "1" ]; then
  mkdir -p "$STATE_DIR"
  if [ -f "$STAMP_FILE" ]; then
    now_ts="$(date +%s 2>/dev/null || echo 0)"
    last_ts="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
    if [ "$now_ts" -gt 0 ] && [ "$last_ts" -gt 0 ]; then
      age=$((now_ts - last_ts))
      if [ "$age" -lt __MIN_INTERVAL_SECONDS__ ]; then
        echo "Skipping run: only ${age}s since last successful run"
        exit 0
      fi
    fi
  fi
fi

errors=0

while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "$line")"
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
  esac

  IFS='|' read -r raw_dir raw_type raw_post <<< "$line"
  dir="$(trim "${raw_dir-}")"
  type="$(trim "${raw_type-}")"
  post="$(trim "${raw_post-}")"

  if [ ! -d "$dir" ]; then
    echo "ERROR: missing $dir"
    errors=$((errors + 1))
    continue
  fi

  case "$type" in
    files|all) ;;
    *) echo "ERROR: unknown type '$type' for $dir"; errors=$((errors + 1)); continue ;;
  esac

  if find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
    echo "WARNING: subdirectories in $dir (left untouched)"
    find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
  fi

  echo "=== $dir ==="
  echo "Before:"
  du -sh "$dir" 2>/dev/null || echo "(du failed)"

  case "$type" in
    files) find "$dir" -mindepth 1 -maxdepth 1 -type f -exec rm -f -- {} + ;;
    all)   find "$dir" -mindepth 1 -maxdepth 1 ! -type d -exec rm -f -- {} + ;;
  esac
  if [ $? -ne 0 ]; then
    echo "ERROR: deletion failed in $dir"
    errors=$((errors + 1))
    continue
  fi

  echo "After:"
  du -sh "$dir" 2>/dev/null || echo "(du failed)"

  if [ -n "$post" ]; then
    echo "Post-clean: $post"
    if ! run_post_command "$post"; then
      echo "ERROR: post-clean failed for $dir: $post"
      errors=$((errors + 1))
    fi
  fi

  echo ""
done < "$CONF"

if [ "$errors" -gt 0 ]; then
  echo "Finished with $errors error(s)"
  exit 1
fi
if [ "${LOG_PRUNER_USE_STAMP:-0}" = "1" ]; then
  date +%s > "$STAMP_FILE"
fi
echo "All targets cleaned successfully"
PRUNER
TMP_SCRIPT="${SCRIPT_PATH}.tmp"
: > "$TMP_SCRIPT"
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "${line//__MIN_INTERVAL_SECONDS__/$MIN_INTERVAL_SECONDS}" >> "$TMP_SCRIPT"
done < "$SCRIPT_PATH"
mv "$TMP_SCRIPT" "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  rm -f "/etc/cron.d/${SERVICE_NAME}" 2>/dev/null || true
  if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -F -v -- "${SCRIPT_PATH}" || true ) | crontab - || true
  fi
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCUNIT
[Unit]
Description=Log pruner for ${MYHOST}

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
SVCUNIT

  cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<TMRUNIT
[Unit]
Description=Run log pruner every ${TIMER_INTERVAL} on ${MYHOST}

[Timer]
OnBootSec=${TIMER_BOOT_DELAY}
OnUnitActiveSec=${TIMER_INTERVAL}
Persistent=true
AccuracySec=1h
RandomizedDelaySec=45min

[Install]
WantedBy=timers.target
TMRUNIT

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.timer"
  echo "--- Deployed (systemd) on ${MYHOST}. Timer status: ---"
  systemctl list-timers "${SERVICE_NAME}.timer"
else
  if [ -d /etc/cron.d ]; then
    CRON_FILE="/etc/cron.d/${SERVICE_NAME}"
    printf '%s root LOG_PRUNER_USE_STAMP=1 %s >> %s 2>&1\n' "${CRON_SCHEDULE}" "${SCRIPT_PATH}" "${LOG_PATH}" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    echo "--- Deployed (cron.d) on ${MYHOST}: ---"
    cat "$CRON_FILE"
  elif command -v crontab >/dev/null 2>&1; then
    CRON_LINE="${CRON_SCHEDULE} LOG_PRUNER_USE_STAMP=1 ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"
    ( crontab -l 2>/dev/null | grep -F -v -- "${SCRIPT_PATH}" || true; echo "$CRON_LINE" ) | crontab -
    echo "--- Deployed (root crontab) on ${MYHOST}: ---"
    echo "$CRON_LINE"
  else
    echo "WARNING: no systemd, no cron.d, no crontab - scheduler not installed"
    echo "Run manually: ${SCRIPT_PATH}"
  fi
fi

echo "--- Config (edit later: ${CONF_PATH}): ---"
cat "$CONF_PATH"
}
( deploy_log_pruner )
