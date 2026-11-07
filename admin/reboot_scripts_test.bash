#!/bin/bash
#
# reboot_scripts_test.bash - tests for admin/safe_to_reboot.bash and admin/caltechdata_down.bash
# (caltechdata DR-0007, plan nginx_deploy_port, R6; ported from the CaltechAUTHORS tests and extended for the
# OpenSearch snapshot and long-upload checks).
#
# Usage: ./admin/reboot_scripts_test.bash [NAME-PATTERN]
#
# The contract these tests pin (the same one admin-shell-scripts documents):
#   safe_to_reboot.bash  only REPORTS. Exit 0 and no output when a reboot is safe; exit 1 and
#                        a description when it is not. It never stops, starts or kills anything.
#                        When units are running it names the script that stops them.
#                        It also reports a running OpenSearch snapshot (GET /_snapshot/_status) and an upload
#                        in progress (an established connection on the RDM ports 5000/5001 that has received
#                        at least UPLOAD_MIN_BYTES), and exits 70, never 0, when it cannot tell.
#   caltechdata_down.bash  stops the RDM units in order: nginx, rdm, rdm_rest, rdm_celery.
#                        It never touches Docker (the units Require docker.service, so systemd
#                        stops the containers at shutdown).
#
# No real systemd is needed: stub `systemctl`, `pgrep`, `sudo`, `curl` and `ss` are put first on PATH and
# log every call to $STUB_LOG.
#
# EXIT STATUS: 0 every test passed; 1 a test failed.
# Written for bash 3.2 (macOS) and later.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SAFE="$HERE/safe_to_reboot.bash"
DOWN="$HERE/caltechdata_down.bash"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/reboot-scripts-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASSED=0
FAILED=0
CASE_DIR=""
OUT=""
RC=0

# new_case NAME builds $CASE_DIR/bin with stubs. STUB_ACTIVE is a space-separated list of units
# that report active; STUB_DUMP=1 makes pgrep find a running backup; STUB_STOP_FAIL names a unit
# whose stop fails. STUB_OS is what the OpenSearch snapshot call sees: empty (default), running, down
# (connection refused, curl exit 7), timeout (curl exit 28), http500, garbage. STUB_SS_BYTES is a
# space-separated list of bytes_received values, one established connection each; STUB_SS_FAIL=1 makes
# ss fail.
new_case() {
  CASE_DIR="$ROOT/$1"
  mkdir -p "$CASE_DIR/bin"
  : > "$CASE_DIR/stub.log"
  cat > "$CASE_DIR/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in
  is-active)
    shift; q=0; [ "$1" = "--quiet" ] && { q=1; shift; }
    for u in ${STUB_ACTIVE:-}; do [ "$u" = "$1" ] || [ "$u.service" = "$1" ] && { [ $q = 1 ] || echo active; exit 0; }; done
    [ $q = 1 ] || echo inactive; exit 3;;
  stop)
    [ "${STUB_STOP_FAIL:-}" = "$2" ] && exit 5
    exit 0;;
  *) exit 0;;
esac
EOS
  cat > "$CASE_DIR/bin/pgrep" <<'EOS'
#!/bin/bash
echo "pgrep $*" >> "$STUB_LOG"
[ "${STUB_DUMP:-0}" = 1 ] && { echo 4242; exit 0; }
exit 1
EOS
  cat > "$CASE_DIR/bin/sudo" <<'EOS'
#!/bin/bash
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
EOS
  cat > "$CASE_DIR/bin/curl" <<'EOS'
#!/bin/bash
echo "curl $*" >> "$STUB_LOG"
case "${STUB_OS:-empty}" in
  empty) printf '{"snapshots":[]}\n200'; exit 0;;
  running) printf '{"snapshots":[{"snapshot":"nightly-1","repository":"prod_repo","state":"IN_PROGRESS"}]}\n200'; exit 0;;
  down) exit 7;;
  timeout) exit 28;;
  http500) printf '{"error":"boom"}\n500'; exit 0;;
  garbage) printf 'not json at all\n200'; exit 0;;
esac
EOS
  cat > "$CASE_DIR/bin/ss" <<'EOS'
#!/bin/bash
echo "ss $*" >> "$STUB_LOG"
[ "${STUB_SS_FAIL:-0}" = 1 ] && exit 1
for n in ${STUB_SS_BYTES:-}; do
  echo "0      0      127.0.0.1:5001 127.0.0.1:5$n"
  echo "	 cubic wscale:10,10 rto:204 mss:32768 bytes_received:$n segs_out:1 segs_in:3 lastrcv:1983"
done
exit 0
EOS
  # docker, kill and pkill must never be called; a call is logged and fails loudly
  for c in docker kill pkill; do
    printf '#!/bin/bash\necho "FORBIDDEN %s $*" >> "$STUB_LOG"\nexit 99\n' "$c" > "$CASE_DIR/bin/$c"
  done
  chmod +x "$CASE_DIR"/bin/*
}

# path_without TOOL builds $CASE_DIR/bin2: the stubs, and the real tools a script needs, except TOOL, so a
# test can run a script on a host that lacks TOOL whatever the machine running the tests has.
path_without() {
  local t p
  mkdir -p "$CASE_DIR/bin2"
  for t in "$CASE_DIR"/bin/*; do [ "$(basename "$t")" = "$1" ] || ln -sf "$t" "$CASE_DIR/bin2/$(basename "$t")"; done
  for t in awk sed tr grep head cat wc sort ls tail cut printf sleep id dirname basename; do
    [ "$t" = "$1" ] && continue
    p=$(command -v "$t" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$CASE_DIR/bin2/$t";; esac
  done
  rm -f "$CASE_DIR/bin2/$1"
}

# run_without TOOL SCRIPT runs a script with TOOL missing from PATH.
run_without() {
  path_without "$1"
  OUT=$(STUB_LOG="$CASE_DIR/stub.log" PATH="$CASE_DIR/bin2" "$BASH" "$2" 2>&1)
  RC=$?
}

# run_script PATH [ARGS...] runs a script with the stubs first on PATH.
run_script() {
  local script=$1; shift
  OUT=$(STUB_LOG="$CASE_DIR/stub.log" PATH="$CASE_DIR/bin:$PATH" bash "$script" "$@" 2>&1)
  RC=$?
}

fail() { echo "      FAIL: $*"; }
expect_rc() { [ "$RC" -eq "$1" ] || fail "exit $RC, wanted $1 ($2); output: $OUT"; }
expect_out() { case "$OUT" in *"$1"*) ;; *) fail "output lacks '$1': $OUT";; esac; }
expect_no_out() { case "$OUT" in *"$1"*) fail "output has '$1': $OUT";; esac; }
log_has() { grep -q -- "$1" "$CASE_DIR/stub.log" || fail "stub log lacks '$1'"; }
log_lacks() { ! grep -q -- "$1" "$CASE_DIR/stub.log" || fail "stub log has '$1'"; }

# ---- safe_to_reboot.bash ----------------------------------------------------

t_safe_nothing_running_is_silent_and_exit_0() {
  new_case $FUNCNAME; STUB_ACTIVE="" run_script "$SAFE"
  expect_rc 0 "nothing is running"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_each_unit_alone_makes_it_unsafe() {
  local u
  for u in nginx rdm rdm_rest rdm_celery; do
    new_case $FUNCNAME-$u; STUB_ACTIVE="$u" run_script "$SAFE"
    expect_rc 1 "$u is running"; expect_out "$u"
  done
}

t_safe_names_every_running_unit_and_not_the_stopped_ones() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm_celery" run_script "$SAFE"
  expect_rc 1 "two units running"; expect_out "nginx"; expect_out "rdm_celery"
  expect_no_out "rdm_rest"
}

t_safe_names_the_down_script() {
  new_case $FUNCNAME; STUB_ACTIVE="rdm" run_script "$SAFE"
  expect_out "caltechdata_down.bash"
}

t_safe_a_running_backup_is_unsafe_and_says_wait() {
  new_case $FUNCNAME; STUB_ACTIVE="" STUB_DUMP=1 run_script "$SAFE"
  expect_rc 1 "a SQL backup is running"; expect_out "backup"; expect_out "wait"
}

t_safe_a_running_backup_does_not_ask_for_a_stop() {
  new_case $FUNCNAME; STUB_ACTIVE="" STUB_DUMP=1 run_script "$SAFE"
  expect_no_out "caltechdata_down.bash"
}

t_safe_looks_for_both_backup_programs() {
  # the stub ignores arguments, so pin what the script asks pgrep for
  new_case $FUNCNAME; run_script "$SAFE"
  log_has "pgrep -x pg_dump"; log_has "pgrep -f .*invenio-sql-backup"
}

# The next three use the REAL pgrep (the stub is removed), because the failure they pin is about
# what pgrep matches. Found on a Multipass instance 2026-11-05: `pgrep -f pg_dump` matched the
# probe's own `bash -c '...pg_dump...'` and reported a backup that was not running.
t_safe_a_command_line_that_only_mentions_the_backup_is_not_a_backup() {
  new_case $FUNCNAME; rm "$CASE_DIR/bin/pgrep"
  bash -c 'sleep 4; :' invenio-sql-backup.bash pg_dump & local decoy=$!
  sleep 0.5; STUB_ACTIVE="" run_script "$SAFE"; kill $decoy 2>/dev/null; wait $decoy 2>/dev/null
  expect_rc 0 "only a decoy mentions the backup"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_an_editor_open_on_the_backup_script_is_not_a_backup() {
  # a decoy whose command line has only the script's name, as `less invenio-sql-backup.bash` would
  new_case $FUNCNAME; rm "$CASE_DIR/bin/pgrep"
  bash -c 'sleep 4; :' x invenio-sql-backup.bash & local decoy=$!
  sleep 0.5; STUB_ACTIVE="" run_script "$SAFE"; kill $decoy 2>/dev/null; wait $decoy 2>/dev/null
  expect_rc 0 "only an editor-like decoy names the script"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_a_running_backup_script_is_found() {
  new_case $FUNCNAME; rm "$CASE_DIR/bin/pgrep"
  printf '#!/bin/bash\nsleep 4\n' > "$CASE_DIR/invenio-sql-backup.bash"
  bash "$CASE_DIR/invenio-sql-backup.bash" & local job=$!
  sleep 0.5; STUB_ACTIVE="" run_script "$SAFE"; kill $job 2>/dev/null; wait $job 2>/dev/null
  expect_rc 1 "invenio-sql-backup.bash is running"; expect_out "backup"
}

t_safe_a_running_pg_dump_process_is_found() {
  new_case $FUNCNAME; rm "$CASE_DIR/bin/pgrep"
  ln -s "$(command -v sleep)" "$CASE_DIR/pg_dump"  # a link: copying a signed macOS binary gets it killed
  "$CASE_DIR/pg_dump" 4 & local job=$!
  sleep 0.5; STUB_ACTIVE="" run_script "$SAFE"; kill $job 2>/dev/null; wait $job 2>/dev/null
  expect_rc 1 "a pg_dump process is running"; expect_out "backup"
}

t_safe_has_no_side_effects() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm rdm_rest rdm_celery" STUB_DUMP=1 run_script "$SAFE"
  log_lacks "systemctl stop"; log_lacks "systemctl start"; log_lacks "systemctl restart"
  log_lacks "systemctl disable"; log_lacks "FORBIDDEN"; log_lacks "^sudo "
  log_lacks " -X "; log_lacks "--data"; log_lacks " -T "
}

t_safe_help_exits_0_and_describes_the_contract() {
  new_case $FUNCNAME; run_script "$SAFE" --help
  expect_rc 0 "--help"; expect_out "safe_to_reboot.bash"; expect_out "caltechdata_down.bash"
  log_lacks "systemctl"
}

t_safe_unknown_argument_is_a_usage_error() {
  new_case $FUNCNAME; run_script "$SAFE" --nope
  expect_rc 2 "unknown argument"; log_lacks "systemctl"
}

t_safe_missing_systemctl_is_not_reported_as_safe() {
  # a host where the probe cannot run must not claim a reboot is safe
  new_case $FUNCNAME; run_without systemctl "$SAFE"
  expect_rc 70 "systemctl missing"; expect_out "systemctl"
}

# ---- safe_to_reboot.bash: an OpenSearch snapshot ----------------------------------------------

t_safe_a_running_opensearch_snapshot_is_unsafe_and_says_wait() {
  new_case $FUNCNAME; STUB_OS=running run_script "$SAFE"
  expect_rc 1 "a snapshot is running"; expect_out "snapshot"; expect_out "wait"
}

t_safe_a_running_snapshot_is_named() {
  new_case $FUNCNAME; STUB_OS=running run_script "$SAFE"
  expect_out "prod_repo"; expect_out "nightly-1"
}

t_safe_a_running_snapshot_does_not_ask_for_a_stop() {
  new_case $FUNCNAME; STUB_OS=running run_script "$SAFE"
  expect_no_out "caltechdata_down.bash"
}

t_safe_no_snapshot_is_silent() {
  new_case $FUNCNAME; STUB_OS=empty run_script "$SAFE"
  expect_rc 0 "an empty snapshot list"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_asks_opensearch_on_the_local_port_without_credentials() {
  new_case $FUNCNAME; run_script "$SAFE"
  log_has "curl .*http://127.0.0.1:9200/_snapshot/_status"
  log_lacks " -u "; log_lacks "--user"; log_lacks "Authorization"; log_lacks " -X "; log_lacks "--data"; log_lacks " -T "
}

t_safe_opensearch_url_can_be_overridden() {
  new_case $FUNCNAME; OPENSEARCH_URL=http://127.0.0.1:19200 run_script "$SAFE"
  log_has "http://127.0.0.1:19200/_snapshot/_status"
}

t_safe_opensearch_not_running_means_no_snapshot() {
  # connection refused: the search container is down, so no snapshot can be running
  new_case $FUNCNAME; STUB_OS=down run_script "$SAFE"
  expect_rc 0 "OpenSearch refuses connections"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_an_opensearch_timeout_is_not_reported_as_safe() {
  new_case $FUNCNAME; STUB_OS=timeout run_script "$SAFE"
  expect_rc 70 "curl timed out"; expect_out "OpenSearch"
}

t_safe_an_opensearch_error_is_not_reported_as_safe() {
  new_case $FUNCNAME; STUB_OS=http500 run_script "$SAFE"
  expect_rc 70 "HTTP 500"; expect_out "500"
}

t_safe_an_unreadable_opensearch_answer_is_not_reported_as_safe() {
  new_case $FUNCNAME; STUB_OS=garbage run_script "$SAFE"
  expect_rc 70 "an answer that is not a snapshot list"
}

t_safe_missing_curl_is_not_reported_as_safe() {
  new_case $FUNCNAME; run_without curl "$SAFE"
  expect_rc 70 "curl missing"; expect_out "curl"
}

# ---- safe_to_reboot.bash: an upload in progress -----------------------------------------------

t_safe_a_large_upload_in_progress_is_unsafe_and_says_wait() {
  new_case $FUNCNAME; STUB_SS_BYTES="52428800" run_script "$SAFE"
  expect_rc 1 "a 50 MiB request is in flight"; expect_out "upload"; expect_out "wait"
}

t_safe_a_large_upload_is_sized_in_the_message() {
  new_case $FUNCNAME; STUB_SS_BYTES="52428800" run_script "$SAFE"
  expect_out "50 MiB"
}

t_safe_a_small_request_is_not_an_upload() {
  new_case $FUNCNAME; STUB_SS_BYTES="351 4096 1048575" run_script "$SAFE"
  expect_rc 0 "only small requests"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_the_upload_threshold_is_inclusive() {
  new_case $FUNCNAME; STUB_SS_BYTES="1048576" run_script "$SAFE"
  expect_rc 1 "exactly 1 MiB"
}

t_safe_the_upload_threshold_can_be_overridden() {
  new_case $FUNCNAME; STUB_SS_BYTES="4096" UPLOAD_MIN_BYTES=1024 run_script "$SAFE"
  expect_rc 1 "4096 bytes against a 1024 byte threshold"
}

t_safe_one_large_upload_among_small_requests_is_found() {
  new_case $FUNCNAME; STUB_SS_BYTES="351 99999999 4096" run_script "$SAFE"
  expect_rc 1 "one large upload"; expect_out "upload"
}

t_safe_a_bad_upload_threshold_is_a_usage_error() {
  new_case $FUNCNAME; UPLOAD_MIN_BYTES=lots run_script "$SAFE"
  expect_rc 2 "UPLOAD_MIN_BYTES is not a number"; expect_out "UPLOAD_MIN_BYTES"; log_lacks "systemctl"
}

t_safe_looks_at_established_connections_on_both_rdm_ports() {
  new_case $FUNCNAME; run_script "$SAFE"
  log_has "ss .*established"; log_has "ss .*5000"; log_has "ss .*5001"
}

t_safe_a_failing_ss_is_not_reported_as_safe() {
  new_case $FUNCNAME; STUB_SS_FAIL=1 run_script "$SAFE"
  expect_rc 70 "ss failed"; expect_out "ss"
}

t_safe_missing_ss_is_not_reported_as_safe() {
  new_case $FUNCNAME; run_without ss "$SAFE"
  expect_rc 70 "ss missing"; expect_out "ss"
}

t_safe_a_failed_probe_wins_over_a_not_safe_finding() {
  # 70 says "I could not tell"; it must not be hidden behind 1, or a person sees only the part that worked
  new_case $FUNCNAME; STUB_ACTIVE="rdm" STUB_OS=http500 run_script "$SAFE"
  expect_rc 70 "unit running and a probe failed"; expect_out "rdm"; expect_out "500"
}

t_safe_reports_every_reason_in_one_run() {
  new_case $FUNCNAME; STUB_ACTIVE="rdm_rest" STUB_DUMP=1 STUB_OS=running STUB_SS_BYTES="9999999" run_script "$SAFE"
  expect_rc 1 "everything is going on"; expect_out "rdm_rest"; expect_out "backup"; expect_out "snapshot"; expect_out "upload"
}

# ---- caltechdata_down.bash -----------------------------------------------

t_down_stops_the_four_units_in_order() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm rdm_rest rdm_celery" run_script "$DOWN"
  expect_rc 0 "all stops succeed"
  local got
  got=$(grep '^systemctl stop' "$CASE_DIR/stub.log" | awk '{print $3}' | tr '\n' ' ')
  [ "$got" = "nginx rdm rdm_rest rdm_celery " ] || fail "stop order was: $got"
}

t_down_uses_sudo() {
  new_case $FUNCNAME; run_script "$DOWN"
  log_has "sudo systemctl stop nginx"
}

t_down_never_touches_docker_or_kills() {
  new_case $FUNCNAME; run_script "$DOWN"
  log_lacks "FORBIDDEN"
}

t_down_a_failed_stop_still_tries_the_rest_and_exits_nonzero() {
  new_case $FUNCNAME; STUB_STOP_FAIL=rdm run_script "$DOWN"
  [ "$RC" -ne 0 ] || fail "exit 0 although a stop failed"
  log_has "systemctl stop rdm_rest"; log_has "systemctl stop rdm_celery"
  expect_out "rdm"
}

t_down_help_exits_0_and_stops_nothing() {
  new_case $FUNCNAME; run_script "$DOWN" --help
  expect_rc 0 "--help"; expect_out "caltechdata_down.bash"; log_lacks "systemctl stop"
}

t_down_unknown_argument_is_a_usage_error_and_stops_nothing() {
  new_case $FUNCNAME; run_script "$DOWN" --nope
  expect_rc 2 "unknown argument"; log_lacks "systemctl stop"
}

t_down_then_safe_agree() {
  # after the down script reports success the units are inactive, so safe_to_reboot is silent
  new_case $FUNCNAME; STUB_ACTIVE="" run_script "$DOWN"; expect_rc 0 "down"
  run_script "$SAFE"; expect_rc 0 "safe after down"
}

# ---- the runner -------------------------------------------------------------

PATTERN=${1:-}
TESTS=$(declare -F | awk '{print $3}' | grep '^t_' | sort)
echo "reboot_scripts_test.bash: $(echo "$TESTS" | wc -w | tr -d ' ') tests"
for t in $TESTS; do
  if [ -n "$PATTERN" ]; then case "$t" in *"$PATTERN"*) ;; *) continue;; esac; fi
  ( "$t" ) > "$ROOT/$t.out" 2>&1
  if grep -q '^      FAIL:' "$ROOT/$t.out" || [ ! -f "$SAFE" ] || [ ! -f "$DOWN" ]; then
    echo "FAIL  $t"; head -4 "$ROOT/$t.out" | sed 's/^/      /'
    FAILED=$((FAILED+1))
  else
    echo "PASS  $t"; PASSED=$((PASSED+1))
  fi
done
echo; echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
