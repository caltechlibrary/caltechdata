#!/bin/bash
#
# safe_to_reboot.bash - report whether CaltechDATA can be rebooted now.
#
# check-for-reboot.bash (from admin-shell-scripts) runs this when Ubuntu wants a reboot.
# It only REPORTS: exit 0 with no output when a reboot is safe, exit 1 with a description
# when it is not. It never stops, starts or kills anything; stopping is
# caltechdata_down.bash, run by a person.
#
# It looks for four things:
#   - an RDM unit that is still running (nginx, rdm, rdm_rest, rdm_celery)
#   - a SQL backup (invenio-sql-backup.bash, pg_dump)
#   - an OpenSearch snapshot in progress (GET /_snapshot/_status on this host's OpenSearch,
#     which listens on 127.0.0.1:9200 with its security plugin off, so there is no credential)
#   - an upload in progress: an established connection on the RDM ports (5000 UI, 5001 API)
#     that has received at least UPLOAD_MIN_BYTES. nginx sends each proxied request on its
#     own connection (no upstream keepalive) and streams a request body through without
#     buffering it (proxy_request_buffering off), so a large bytes_received on one of
#     those sockets is a file being uploaded right now. A multipart upload is a series of
#     requests, so the time between two parts is not seen.
#
# EXIT STATUS (workspace DR-0014)
#   0   safe
#   1   not safe, with the reasons
#   2   usage: an unknown argument, or UPLOAD_MIN_BYTES is not a whole number
#   70  a probe could not run (systemctl, curl or ss missing, OpenSearch did not answer in
#       time or with a snapshot list, ss failed). This is never reported as safe, and it is
#       reported even when another probe found a reason not to reboot.
#   An OpenSearch that refuses the connection counts as "no snapshot": its container is
#   down, so none can be running.
#
# ENVIRONMENT: CALTECHDATA_DIR (default /Sites/caltechdata), OPENSEARCH_URL (default
# http://127.0.0.1:9200), UPLOAD_MIN_BYTES (default 1048576).

UNITS="nginx rdm rdm_rest rdm_celery"
DOWN=caltechdata_down.bash
INSTANCE_DIR=${CALTECHDATA_DIR:-/Sites/caltechdata}
OPENSEARCH_URL=${OPENSEARCH_URL:-http://127.0.0.1:9200}
UPLOAD_MIN_BYTES=${UPLOAD_MIN_BYTES:-1048576}

usage() {
  cat <<TXT
safe_to_reboot.bash - is it safe to reboot this CaltechDATA host?

Reports only. Exit 0 and no output: safe. Exit 1: not safe, with the reason.
It checks that these units are stopped: $UNITS
that no SQL backup (invenio-sql-backup.bash, pg_dump) is running,
that no OpenSearch snapshot is running ($OPENSEARCH_URL/_snapshot/_status),
and that no upload is in progress (an established connection on port 5000 or
5001 that has received $UPLOAD_MIN_BYTES bytes or more).
If units are running it names $DOWN, which stops them in order
(nginx, rdm, rdm_rest, rdm_celery). Docker is left to systemd at shutdown.
Exit 70 means a check could not be made, which is not the same as safe.
This script changes nothing.
TXT
}

case "${1:-}" in
  "") ;;
  -h|--help|help) usage; exit 0;;
  *) echo "safe_to_reboot.bash: unknown argument: $1" >&2; exit 2;;
esac

case "$UPLOAD_MIN_BYTES" in
  ''|*[!0-9]*) echo "safe_to_reboot.bash: UPLOAD_MIN_BYTES must be a whole number of bytes, not '$UPLOAD_MIN_BYTES'" >&2; exit 2;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  echo "safe_to_reboot.bash: systemctl not found; cannot tell whether a reboot is safe" >&2
  exit 70
fi

RUNNING=""
for u in $UNITS; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then RUNNING="$RUNNING $u"; fi
done

UNSAFE=0
PROBE_FAILED=0

# probe_failed MESSAGE records that a check could not be made.
probe_failed() {
  echo "safe_to_reboot.bash: $1" >&2
  PROBE_FAILED=1
}

# human_size BYTES prints a size a person reads: "50 MiB" from 1 MiB up, otherwise "4096 bytes".
human_size() {
  if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 )) MiB"; else echo "$1 bytes"; fi
}

if [ -n "$RUNNING" ]; then
  UNSAFE=1
  echo "CaltechDATA is still running. These units are active:$RUNNING"
  echo
  echo "Stop them in order with:"
  echo
  echo "    $DOWN"
  echo
  echo "($INSTANCE_DIR's containers are stopped by systemd at shutdown.)"
fi

# Match the process, not any command line that mentions it: `pgrep -f pg_dump` also matches
# `less invenio-sql-backup.bash` or an SSM wrapper whose script text contains the word. The dump
# is the process named pg_dump (visible from the host even when it runs in the db container);
# the script is a shell whose first operand is invenio-sql-backup*.
BACKUP_SCRIPT='^([^ ]*/)?(ba)?sh( -[A-Za-z]+)* [^ ]*invenio-sql-backup'
if pgrep -x pg_dump >/dev/null 2>&1 || pgrep -f "$BACKUP_SCRIPT" >/dev/null 2>&1; then
  UNSAFE=1
  echo "A SQL backup is running. Do not reboot until it finishes: wait, then run this check again."
fi

# An OpenSearch snapshot: the list is empty when none is running. A refused connection means the
# search container is down (curl exit 7), so none can be running; any other failure is not "safe".
if ! command -v curl >/dev/null 2>&1; then
  probe_failed "curl not found; cannot tell whether an OpenSearch snapshot is running"
else
  resp=$(curl -s --max-time 5 -w '\n%{http_code}' "$OPENSEARCH_URL/_snapshot/_status" 2>/dev/null)
  crc=$?
  case "$crc" in
    0)
      code=${resp##*$'\n'}
      body=${resp%$'\n'*}
      compact=$(printf '%s' "$body" | tr -d ' \n\t')
      if [ "$code" != 200 ]; then
        probe_failed "OpenSearch ($OPENSEARCH_URL) answered HTTP $code to the snapshot status request; cannot tell whether a snapshot is running"
      else
        case "$compact" in
          *'"snapshots":[]'*) ;;
          *'"snapshots":[{'*)
            UNSAFE=1
            repos=$(printf '%s' "$compact" | grep -o '"repository":"[^"]*"' | sed 's/"repository":"\(.*\)"/\1/' | tr '\n' ' ')
            snaps=$(printf '%s' "$compact" | grep -o '"snapshot":"[^"]*"' | sed 's/"snapshot":"\(.*\)"/\1/' | tr '\n' ' ')
            echo "An OpenSearch snapshot is running (repository ${repos% }; snapshot ${snaps% }). Do not reboot until it finishes: wait, then run this check again."
            ;;
          *) probe_failed "OpenSearch ($OPENSEARCH_URL) answered, but not with a snapshot list; cannot tell whether a snapshot is running" ;;
        esac
      fi
      ;;
    7) ;;
    *) probe_failed "OpenSearch ($OPENSEARCH_URL) did not answer (curl exit $crc); cannot tell whether a snapshot is running" ;;
  esac
fi

# An upload in progress: the biggest bytes_received among the established connections on the RDM ports.
if ! command -v ss >/dev/null 2>&1; then
  probe_failed "ss not found; cannot tell whether an upload is in progress"
else
  ssout=$(ss -tniH state established '( sport = :5000 or sport = :5001 )' 2>&1)
  src=$?
  if [ "$src" -ne 0 ]; then
    probe_failed "ss failed (exit $src); cannot tell whether an upload is in progress"
  else
    counts=$(printf '%s\n' "$ssout" | grep -o 'bytes_received:[0-9]*' | cut -d: -f2 \
      | awk -v min="$UPLOAD_MIN_BYTES" '{ if ($1 + 0 >= min) { n++; if ($1 + 0 > big) big = $1 + 0 } } END { print n + 0, big + 0 }')
    n=${counts% *}
    big=${counts#* }
    if [ "$n" -gt 0 ]; then
      UNSAFE=1
      echo "An upload looks to be in progress: $n request(s) on the RDM ports have received at least $(human_size "$UPLOAD_MIN_BYTES") (the largest $(human_size "$big")). Do not reboot until it finishes: wait, then run this check again."
    fi
  fi
fi

[ "$PROBE_FAILED" -eq 0 ] || exit 70
exit $UNSAFE
