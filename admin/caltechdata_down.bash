#!/bin/bash
#
# caltechdata_down.bash - bring CaltechDATA down in order, before a reboot.
#
# Stops nginx first (no new traffic), then rdm (UI), rdm_rest (API) and rdm_celery (tasks).
# It does not touch Docker: the rdm units Require docker.service, so systemd stops the
# containers cleanly at shutdown. Every stop is attempted even if an earlier one fails.
#
# EXIT STATUS: 0 all stopped; 1 one or more stops failed; 2 usage.

UNITS="nginx rdm rdm_rest rdm_celery"

usage() {
  cat <<TXT
caltechdata_down.bash - stop CaltechDATA in order: $UNITS
Uses sudo systemctl stop. Docker is left to systemd at shutdown.
Run safe_to_reboot.bash afterwards to confirm.
TXT
}

case "${1:-}" in
  "") ;;
  -h|--help|help) usage; exit 0;;
  *) echo "caltechdata_down.bash: unknown argument: $1" >&2; exit 2;;
esac

FAILED=""
for u in $UNITS; do
  if ! sudo systemctl stop "$u"; then
    echo "caltechdata_down.bash: could not stop $u" >&2
    FAILED="$FAILED $u"
  fi
done
if [ -n "$FAILED" ]; then
  echo "caltechdata_down.bash: not stopped:$FAILED" >&2
  exit 1
fi
