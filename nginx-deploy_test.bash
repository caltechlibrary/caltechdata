#!/bin/bash
#
# nginx-deploy_test.bash - tests for nginx-deploy.bash (caltechdata DR-0009, plan phase 2).
#
# Usage: ./nginx-deploy_test.bash [NAME-PATTERN]
#
# No real nginx or logagent is needed. Every test builds a fixture under a temporary
# directory: a copy of this repository's nginx/ tree, a fake /etc/nginx, and stub
# `nginx` and `logagent` programs. The stub nginx behaves like the real one in the one
# way that matters here: a log_format name defined twice is an error.
#
# EXIT STATUS: 0 every test passed; 1 a test failed.
#
# Written for bash 3.2 (macOS) and later: no associative arrays, no mapfile.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/nginx-deploy.bash"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nginx-deploy-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASSED=0
FAILED=0
FAILED_NAMES=""
CASE_DIR=""
OUT=""
ERR=""
RC=0

# ---- fixtures ---------------------------------------------------------------

# new_case NAME builds $CASE_DIR with repo/, etc/ and bin/ (the stubs).
new_case() {
  CASE_DIR="$ROOT/$1"
  mkdir -p "$CASE_DIR/repo" "$CASE_DIR/bin" "$CASE_DIR/etc/conf.d" "$CASE_DIR/etc/sites-available" \
    "$CASE_DIR/etc/sites-enabled" "$CASE_DIR/etc/snippets"
  cp -R "$HERE/nginx" "$CASE_DIR/repo/nginx"
  {
    echo "events {}"
    echo "http {"
    echo "  include $CASE_DIR/etc/mime.types;"
    echo "  include $CASE_DIR/etc/conf.d/*.conf;"
    echo "  include $CASE_DIR/etc/sites-enabled/*;"
    echo "}"
  } > "$CASE_DIR/etc/nginx.conf"
  echo "types { text/html html; }" > "$CASE_DIR/etc/mime.types"
  echo "ssl_protocols TLSv1.2;" > "$CASE_DIR/etc/snippets/ssl-params.conf"
  printf 'ssl_certificate /x.crt;\nssl_certificate_key /x.key;\n' > "$CASE_DIR/etc/snippets/self-signed.conf"
  echo "dh" > "$CASE_DIR/etc/dhparam.pem"
  : > "$CASE_DIR/stub.log"
  cat > "$CASE_DIR/bin/nginx" <<'EOS'
#!/bin/bash
echo "nginx $*" >> "$STUB_LOG"
mode=""; conf=""
while [ $# -gt 0 ]; do
  case "$1" in -t) mode=t;; -T) mode=T;; -c) conf=$2; shift;; esac
  shift
done
if [ ! -f "$conf" ]; then echo "nginx: [emerg] open() \"$conf\" failed (2: No such file or directory)" >&2; exit 1; fi
cdir=$(dirname "$conf")
# a log_format name defined twice is an emergency, as in the real nginx (a host's old top-level
# /etc/nginx/caltechdata_log.conf plus conf.d/caltechdata_log.conf is exactly that)
nfmt=$(cat "$cdir"/conf.d/*.conf "$cdir"/caltechdata_log.conf 2>/dev/null | grep -c '^log_format caltechdata_bots')
if [ "$nfmt" -gt 1 ]; then
  echo "nginx: [emerg] duplicate \"log_format\" name \"caltechdata_bots\"" >&2
  echo "nginx: configuration file $conf test failed" >&2; exit 1
fi
case "$mode" in
  t)
    rc=${STUB_NGINX_T_RC:-0}
    if [ "$conf" = "${STUB_ETC:-/nonexistent}/nginx.conf" ] && [ -n "${STUB_NGINX_INSTALLED_RC:-}" ]; then rc=$STUB_NGINX_INSTALLED_RC; fi
    if [ "$rc" != 0 ]; then echo "${STUB_NGINX_T_MSG:-nginx: [emerg] stub says the configuration is wrong}" >&2; exit "$rc"; fi
    [ -z "${STUB_NGINX_T_WARN:-}" ] || echo "$STUB_NGINX_T_WARN" >&2
    echo "nginx: the configuration file $conf syntax is ok" >&2
    echo "nginx: configuration file $conf test is successful" >&2
    ;;
  T)
    echo "# configuration file $conf:"; cat "$conf"
    for f in "$cdir"/conf.d/*.conf "$cdir"/sites-enabled/*; do
      [ -e "$f" ] || continue
      echo "# configuration file $f:"; cat "$f"
    done
    ;;
esac
EOS
  cat > "$CASE_DIR/bin/logagent" <<'EOS'
#!/bin/bash
echo "logagent $*" >> "$STUB_LOG"
echo "${STUB_LOGAGENT_OUT:-No gaps found.}"
exit "${STUB_LOGAGENT_RC:-0}"
EOS
  cat > "$CASE_DIR/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
if [ "${STUB_SYSTEMCTL_RC:-0}" != 0 ]; then echo "Job for nginx.service failed." >&2; fi
exit "${STUB_SYSTEMCTL_RC:-0}"
EOS
  cat > "$CASE_DIR/bin/install" <<'EOS'
#!/bin/bash
# forwards to the real install, except that a destination matching $STUB_INSTALL_FAIL_ON gets a
# half-written file and a failure, as a full disk would leave
if [ -n "${STUB_INSTALL_FAIL_ON:-}" ]; then
  case "$*" in *"$STUB_INSTALL_FAIL_ON"*)
    last=""; for a in "$@"; do last=$a; done
    [ "$1" = "-d" ] || echo "half written" > "$last"
    echo "install: $last: No space left on device" >&2; exit 1 ;;
  esac
fi
exec "$(PATH=/usr/bin:/bin command -v install)" "$@"
EOS
  cat > "$CASE_DIR/bin/date" <<'EOS'
#!/bin/bash
# prints $STUB_DATE when it is set (a fixed clock), otherwise forwards to the real date
if [ -n "${STUB_DATE:-}" ]; then echo "$STUB_DATE"; exit 0; fi
exec "$(PATH=/usr/bin:/bin command -v date)" "$@"
EOS
  chmod +x "$CASE_DIR/bin/nginx" "$CASE_DIR/bin/logagent" "$CASE_DIR/bin/systemctl" "$CASE_DIR/bin/install" "$CASE_DIR/bin/date"
  echo "version: 1" > "$CASE_DIR/logagent.yaml"
}

# run [VAR=value ...] -- ARGS... runs the script with the stubs and the fixture's
# standard arguments; sets OUT, ERR and RC.
STD_ARGS=""
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # the script's temporary directory is inside the case, so a kept stage is removed with it
  mkdir -p "$CASE_DIR/tmp"
  OUT=$(env STUB_LOG="$CASE_DIR/stub.log" NGINX="$CASE_DIR/bin/nginx" LOGAGENT="$CASE_DIR/bin/logagent" SYSTEMCTL="$CASE_DIR/bin/systemctl" STUB_ETC="$CASE_DIR/etc" TMPDIR="$CASE_DIR/tmp" \
    ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" 2> "$CASE_DIR/err" <<<"${RUN_STDIN:-}")
  RC=$?
  ERR=$(cat "$CASE_DIR/err")
}

# std prints the arguments most tests share: check with a full, valid set of options.
std() {
  echo "check --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml"
}

# stdv VERB prints the full option set for diff, apply and rollback in the sandbox: the backup
# directory lives inside the case, so nothing outside it is touched.
stdv() {
  echo "$1 --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml --backup-dir $CASE_DIR/backups"
}
# stdr prints the options rollback takes.
stdr() { echo "rollback --etc-dir $CASE_DIR/etc --backup-dir $CASE_DIR/backups"; }
# hand_copy REL LINE replaces the installed link REL with a regular file: the repository's content plus LINE,
# the way a host's hand-made copy differs (editing through the link would edit the repository instead).
hand_copy() {
  local f="$CASE_DIR/etc/$1"
  { cat "$f"; echo "$2"; } > "$f.tmp" && rm -f "$f" && mv "$f.tmp" "$f"
}
# mode_of FILE prints the permission string, e.g. -rw-r--r--
mode_of() { ls -ld "$1" | awk '{print $1}'; }
# n_backups prints how many backup directories exist.
n_backups() { ls -1 "$CASE_DIR/backups" 2>/dev/null | wc -l | tr -d ' '; }
# latest_backup prints the path of the newest backup directory.
latest_backup() { ls -1 "$CASE_DIR/backups" | sort | tail -1 | sed "s#^#$CASE_DIR/backups/#"; }
# apply_ok applies with --yes and fails the test if it does not succeed.
apply_ok() { run -- $(stdv apply) --yes --no-logagent "$@"; eq "$RC" 0 "apply (stderr: $ERR)"; }


# tree_sig DIR prints a signature of every file and link under DIR.
tree_sig() {
  (cd "$1" && find . \( -type f -o -type l \) | sort | while read -r f; do
    if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(cksum < "$f")"; fi
  done)
}

# ---- assertions -------------------------------------------------------------

fail() { echo "      FAIL: $*"; TEST_OK=0; }
eq()   { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
has()  { case "$1" in *"$2"*) ;; *) fail "$3: '$2' not found in: $(printf '%s' "$1" | head -c 300)";; esac; }
hasnt(){ case "$1" in *"$2"*) fail "$3: '$2' was found";; esac; }
exists()  { [ -e "$1" ] || fail "$2: $1 does not exist"; }
absent()  { [ ! -e "$1" ] || fail "$2: $1 exists"; }

# staged_dir finds the stage a --keep-stage run printed ("stage: PATH" on stderr).
staged_dir() { printf '%s\n' "$ERR" | sed -n 's/^stage: //p' | head -1; }

# ---- the tests --------------------------------------------------------------

t_help_lists_the_exit_status() {
  new_case $FUNCNAME; run -- --help
  eq "$RC" 0 "exit"; has "$OUT" "EXIT STATUS" "help"; has "$OUT" "check" "help names the verb"; has "$OUT" "--server-name" "help names the option"
}
t_version() { new_case $FUNCNAME; run -- --version; eq "$RC" 0 "exit"; has "$OUT" "nginx-deploy.bash 0." "version line"; }
t_a_bad_flag_is_a_usage_error() { new_case $FUNCNAME; run -- check --frobnicate; eq "$RC" 2 "exit"; has "$ERR" "--frobnicate" "names the flag"; }
t_a_surplus_argument_is_a_usage_error() { new_case $FUNCNAME; run -- $(std) surplus; eq "$RC" 2 "exit"; has "$ERR" "surplus" "names the argument"; }
t_no_verb_is_a_usage_error() { new_case $FUNCNAME; run --; eq "$RC" 2 "exit"; }
t_an_unknown_verb_is_a_usage_error() { new_case $FUNCNAME; run -- frobnicate; eq "$RC" 2 "exit"; has "$ERR" "frobnicate" "names the verb"; }
t_the_four_verbs_are_known() {
  new_case $FUNCNAME
  for v in diff apply rollback; do run -- $v --frobnicate; has "$ERR" "--frobnicate" "$v reaches option parsing, so it is a verb"; done
  run -- verify --frobnicate; has "$ERR" "--frobnicate" "verify reaches option parsing, so it is a verb"
  run -- frobnicate; has "$ERR" "check, diff, apply, rollback, verify" "the error lists the verbs"
}
t_a_missing_server_name_is_a_usage_error() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --tls self-signed
  eq "$RC" 2 "exit"; has "$ERR" "--server-name is required" "says it is required"
}
t_tls_is_required() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example
  eq "$RC" 2 "exit"; has "$ERR" "--tls is required" "says it is required"
}
t_tls_takes_a_closed_vocabulary() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls acm
  eq "$RC" 2 "exit"; has "$ERR" "letsencrypt" "lists the values"
}
t_a_server_name_with_odd_characters_is_a_usage_error() {
  new_case $FUNCNAME
  for bad in 'a b' 'x;y' 'a&b' 'a#b' '$(id)'; do
    run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name "$bad" --tls self-signed
    eq "$RC" 2 "server name '$bad'"
  done
}
t_an_underscore_server_name_is_accepted() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name _ --tls self-signed --no-logagent
  eq "$RC" 0 "exit (stderr: $ERR)"
}
t_a_repo_dir_with_odd_characters_is_a_usage_error() {
  new_case $FUNCNAME; run -- check --repo-dir "/tmp/a b" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls self-signed
  eq "$RC" 2 "exit"
}
t_a_missing_repo_nginx_tree_is_no_input() {
  new_case $FUNCNAME; mkdir "$CASE_DIR/empty"; run -- check --repo-dir "$CASE_DIR/empty" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls self-signed
  eq "$RC" 66 "exit"; has "$ERR" "nginx tree is missing: $CASE_DIR/empty/nginx" "names the missing tree itself, not a file inside it"
}
t_a_missing_etc_dir_is_no_input() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/nowhere" --server-name a.example --tls self-signed
  eq "$RC" 66 "exit"; has "$ERR" "configuration directory is missing: $CASE_DIR/nowhere" "names the directory itself, not a file inside it"
}
t_missing_nginx_is_no_input() {
  new_case $FUNCNAME; run NGINX=/nonexistent/nginx -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "nginx" "says what is missing"
}
t_the_default_etc_dir_needs_root() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- check --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed --no-logagent
  eq "$RC" 77 "exit"; has "$ERR" "root" "says why"
}
t_a_missing_repository_ssl_params_snippet_is_no_input() {
  new_case $FUNCNAME; rm "$CASE_DIR/repo/nginx/snippets/ssl-params.conf"; run -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "$CASE_DIR/repo/nginx/snippets/ssl-params.conf" "names the repository's file"
}
t_a_host_without_the_ssl_params_snippet_is_given_one() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/snippets/ssl-params.conf"
  run -- $(std) --no-logagent; eq "$RC" 0 "check no longer requires the host's copy (stderr: $ERR)"
  apply_ok
  cmp -s "$CASE_DIR/etc/snippets/ssl-params.conf" "$CASE_DIR/repo/nginx/snippets/ssl-params.conf" || fail "the installed snippet is not the repository's"
  has "$(cat "$(latest_backup)/MANIFEST")" "created snippets/ssl-params.conf" "the manifest says created"
}
t_a_missing_dhparam_is_no_input() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/dhparam.pem"; run -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "dhparam.pem" "names the file"
}
t_self_signed_needs_its_snippet_but_letsencrypt_does_not() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/snippets/self-signed.conf"
  run -- $(std) --no-logagent; eq "$RC" 66 "self-signed without its snippet"; has "$ERR" "self-signed.conf" "names the file"
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls letsencrypt --no-logagent
  eq "$RC" 0 "letsencrypt does not need it (stderr: $ERR)"
}
t_the_stage_gets_the_host_files_and_the_site_file_includes_them() {
  # DR-0011: the site file is linked, so it carries no host value; the script writes them into generated files
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); exists "$s/sites-available/caltechdata.conf" "site file"
  local site; site=$(cat "$s/sites-available/caltechdata.conf")
  hasnt "$site" "server_name host.example.org" "the site file names no host"
  eq "$(grep -c 'include snippets/caltechdata-host.conf;' "$s/sites-available/caltechdata.conf")" 2 "both server blocks include the host file"
  has "$site" "include snippets/caltechdata-redirect-map.conf;" "the redirect map comes through /etc/nginx"
  has "$site" "alias \$caltechdata_static;" "the static path is a variable the host file sets"
  has "$(grep -v '^#' "$s/snippets/caltechdata-host.conf")" "server_name host.example.org;" "the host file names the server"
  has "$(grep -v '^#' "$s/snippets/caltechdata-host.conf")" "set \$caltechdata_static $CASE_DIR/repo/.venv/var/instance/static;" "and sets the static path"
  case "$site" in *@[A-Z_]*@*) fail "an @TOKEN@ is left";; esac
}
t_the_cert_name_defaults_to_the_server_name() {
  new_case $FUNCNAME
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example.org --tls letsencrypt --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); has "$(cat "$s/snippets/caltechdata-tls.conf")" "/etc/letsencrypt/live/a.example.org/fullchain.pem" "default cert name"
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example.org --cert-name other-lineage --tls letsencrypt --no-logagent --keep-stage
  s=$(staged_dir); has "$(cat "$s/snippets/caltechdata-tls.conf")" "/etc/letsencrypt/live/other-lineage/privkey.pem" "explicit cert name"
}
t_self_signed_uses_the_snippet_cloud_init_writes() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); has "$(cat "$s/snippets/caltechdata-tls.conf")" "include snippets/self-signed.conf;" "self-signed variant"
  hasnt "$(cat "$s/snippets/caltechdata-tls.conf")" "letsencrypt" "no Let's Encrypt path"
}
t_the_site_name_names_the_file_and_the_link() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage --site-name myhost; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); exists "$s/sites-available/myhost.conf" "site file"; [ -L "$s/sites-enabled/myhost.conf" ] || fail "sites-enabled link is missing"
  run -- $(std) --no-logagent --keep-stage; s=$(staged_dir); exists "$s/sites-available/caltechdata.conf" "default site name"
}
t_the_repository_conf_d_files_are_overlaid() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir)
  for f in caltechdata_log cloudflare_real_ip; do exists "$s/conf.d/$f.conf" "conf.d/$f.conf"; done
}
t_a_token_left_in_a_generated_file_is_wrong_data() {
  new_case $FUNCNAME; echo "  # oops @NOPE@" >> "$CASE_DIR/repo/nginx/tls/self-signed.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "@NOPE@" "names the token"; has "$ERR" "self-signed.conf" "names the file"
  hasnt "$(cat "$CASE_DIR/stub.log")" "nginx -t" "nginx was never asked"
}
t_a_token_in_a_linked_repository_file_is_wrong_data() {
  # DR-0011: a linked file cannot be rendered, so a token in it would reach nginx as it is
  new_case $FUNCNAME; echo "  # oops @NOPE@" >> "$CASE_DIR/repo/nginx/sites-available/caltechdata.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "@NOPE@" "names the token"; has "$ERR" "caltechdata.conf" "names the file"
  hasnt "$(cat "$CASE_DIR/stub.log")" "nginx -t" "nginx was never asked"
}
t_check_changes_nothing() {
  new_case $FUNCNAME
  local before_etc before_repo; before_etc=$(tree_sig "$CASE_DIR/etc"); before_repo=$(tree_sig "$CASE_DIR/repo")
  run -- $(std); eq "$RC" 0 "exit (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before_etc" "the target tree"; eq "$(tree_sig "$CASE_DIR/repo")" "$before_repo" "the repository"
}
t_nginx_is_asked_to_test_the_staged_tree_not_the_live_one() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; local s; s=$(staged_dir); local log; log=$(cat "$CASE_DIR/stub.log")
  has "$log" "nginx -t -c $s/nginx.conf" "the test"; has "$log" "nginx -T -c $s/nginx.conf" "the dump"
  hasnt "$log" "-c $CASE_DIR/etc/nginx.conf" "the live tree was not tested"
}
t_a_dangling_symlink_is_copied_as_a_dangling_symlink() {
  new_case $FUNCNAME; ln -s /nowhere/at/all "$CASE_DIR/etc/sites-enabled/default"
  run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "the copy is not stopped by a stale link (stderr: $ERR)"
  local s; s=$(staged_dir)
  [ -L "$s/sites-enabled/default" ] || fail "the stage has no link at sites-enabled/default"
  [ ! -e "$s/sites-enabled/default" ] || fail "the stage's link is not dangling, so a real nginx -t would not fail where the host would"
  eq "$(readlink "$s/sites-enabled/default")" "/nowhere/at/all" "its target is kept as it is"
}
t_the_stage_paths_are_rewritten() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; local s; s=$(staged_dir)
  has "$(cat "$s/nginx.conf")" "include $s/conf.d/*.conf;" "stock nginx.conf include is rewritten to the stage"
  hasnt "$(cat "$s/nginx.conf")" "$CASE_DIR/etc/" "no live path is left"
}
t_a_failing_nginx_test_is_wrong_data() {
  new_case $FUNCNAME; run STUB_NGINX_T_RC=1 "STUB_NGINX_T_MSG=nginx: [emerg] unknown log format \"x\"" -- $(std) --no-logagent
  eq "$RC" 65 "exit"; has "$ERR" "unknown log format" "shows nginx's complaint"
}
t_the_stage_is_removed_on_exit() {
  new_case $FUNCNAME; run -- $(std) --no-logagent
  local s; s=$(sed -n 's/^nginx -t -c \(.*\)\/nginx.conf$/\1/p' "$CASE_DIR/stub.log" | head -1)
  [ -n "$s" ] || { fail "the stage path was not found in the stub log"; return; }
  absent "$s" "the stage"
  run STUB_NGINX_T_RC=1 -- $(std) --no-logagent
  s=$(sed -n 's/^nginx -t -c \(.*\)\/nginx.conf$/\1/p' "$CASE_DIR/stub.log" | tail -1); absent "$s" "the stage after a failure"
}
t_logagent_gets_the_staged_dump_and_no_sample() {
  new_case $FUNCNAME; run -- $(std) --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"; local log; log=$(cat "$CASE_DIR/stub.log")
  has "$log" "logagent check --config $CASE_DIR/logagent.yaml --dump " "logagent check with the config and a dump"; has "$log" "--sample 0" "no log sampling"
  local s; s=$(staged_dir); hasnt "$log" "$CASE_DIR/etc/nginx.conf" "the dump is not of the live tree"
}
t_a_logagent_gap_blocks_the_deployment() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=1 "STUB_LOGAGENT_OUT=[gap] access-log-off: server a has access_log off" -- $(std)
  eq "$RC" 65 "exit"; has "$ERR$OUT" "access-log-off" "shows logagent's finding"
}
t_a_logagent_warning_does_not_block() {
  new_case $FUNCNAME; run "STUB_LOGAGENT_OUT=[warn] location /static has access_log off" -- $(std)
  eq "$RC" 0 "exit (stderr: $ERR)"; has "$ERR$OUT" "location /static" "the warning is shown"
}
t_a_logagent_config_problem_passes_through() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=78 -- $(std); eq "$RC" 78 "a configuration error"
  run STUB_LOGAGENT_RC=66 -- $(std); eq "$RC" 66 "a missing logagent configuration"
}
t_a_logagent_failure_nothing_classified_is_internal() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=9 -- $(std); eq "$RC" 70 "exit"
}
t_a_missing_logagent_is_skipped_with_a_message() {
  new_case $FUNCNAME; run LOGAGENT=/nonexistent/logagent -- $(std); eq "$RC" 0 "exit (stderr: $ERR)"; has "$ERR" "skipped" "says it skipped"
}
t_require_logagent_makes_a_missing_one_an_error() {
  new_case $FUNCNAME; run LOGAGENT=/nonexistent/logagent -- $(std) --require-logagent; eq "$RC" 66 "exit"; has "$ERR" "logagent" "names it"
}
t_no_logagent_never_runs_it() {
  new_case $FUNCNAME; run -- $(std) --no-logagent; eq "$RC" 0 "exit"
  eq "$(grep -c '^logagent ' "$CASE_DIR/stub.log")" 0 "logagent was not called"
  run -- $(std); eq "$(grep -c '^logagent ' "$CASE_DIR/stub.log")" 1 "control: without the flag it is called once"
}

# ---- phase 3: usage ----------------------------------------------------------

t_reload_and_yes_apply_only_where_they_make_sense() {
  new_case $FUNCNAME
  run -- $(std) --reload; eq "$RC" 2 "check --reload"; has "$ERR" "--reload only applies to apply and rollback" "says where it applies"
  run -- $(stdv diff) --yes; eq "$RC" 2 "diff --yes"; has "$ERR" "--yes only applies to apply" "says where it applies"
}
t_rollback_takes_one_optional_stamp_and_the_others_none() {
  new_case $FUNCNAME
  run -- $(stdr) one two; eq "$RC" 2 "two stamps"; has "$ERR" "two" "names the surplus argument"
  run -- $(std) somestamp; eq "$RC" 2 "check with a stamp"
}
t_rollback_needs_no_server_name() {
  new_case $FUNCNAME; run -- $(stdr); eq "$RC" 66 "no backups is no input, not a usage error"
}
t_backup_dir_must_be_an_absolute_path() {
  new_case $FUNCNAME
  run -- $(stdv apply) --yes --backup-dir relative/dir; eq "$RC" 2 "relative --backup-dir"; has "$ERR" "--backup-dir" "names the option"
  run -- $(std) --no-logagent --backup-dir "$CASE_DIR/backups"; eq "$RC" 0 "control: check accepts an absolute --backup-dir (stderr: $ERR)"
}

# ---- phase 3: diff -------------------------------------------------------------

t_diff_on_a_fresh_host_reports_everything_missing() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run -- $(stdv diff); eq "$RC" 1 "drift is exit 1"
  for f in conf.d/caltechdata_log.conf conf.d/cloudflare_real_ip.conf \
           sites-available/caltechdata.conf snippets/caltechdata-tls.conf snippets/caltechdata-host.conf \
           snippets/caltechdata-redirect-map.conf sites-enabled/caltechdata.conf; do
    has "$OUT" "missing  $f" "$f is reported missing"
  done
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "diff changed the tree"
}
t_diff_after_apply_reports_no_drift() {
  new_case $FUNCNAME; apply_ok; run -- $(stdv diff); eq "$RC" 0 "exit (out: $OUT)"; has "$OUT" "no drift" "says so"
}
t_diff_shows_a_hand_made_copy_as_a_diff() {
  # DR-0011: a link cannot be hand-edited without editing the repository; what drifts is a regular file where a link belongs
  new_case $FUNCNAME; apply_ok
  rm "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"; { cat "$CASE_DIR/repo/nginx/conf.d/cloudflare_real_ip.conf"; echo "# a hand edit"; } > "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"
  run -- $(stdv diff); eq "$RC" 1 "exit"; has "$OUT" "differs  conf.d/cloudflare_real_ip.conf" "names the file"
  has "$OUT" "a regular file where the link belongs" "says what is wrong"; has "$OUT" "-# a hand edit" "the diff shows the host's extra line"
}
t_diff_notices_a_missing_or_a_wrong_link() {
  new_case $FUNCNAME; apply_ok
  rm "$CASE_DIR/etc/sites-enabled/caltechdata.conf"; run -- $(stdv diff); eq "$RC" 1 "missing link"; has "$OUT" "missing  sites-enabled/caltechdata.conf" "reports it"
  ln -s /nowhere "$CASE_DIR/etc/sites-enabled/caltechdata.conf"; run -- $(stdv diff); eq "$RC" 1 "wrong link"; has "$OUT" "differs  sites-enabled/caltechdata.conf" "reports it"
}
t_diff_changes_nothing_and_does_not_need_nginx() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run NGINX=/nonexistent/nginx -- $(stdv diff); eq "$RC" 1 "no nginx is needed (a 66 would mean it looked for one)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup directory"
}
t_diff_does_not_need_root() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- diff --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed
  [ "$RC" != 77 ] || fail "diff refused to run as a normal user (exit 77) although it only reads"
}
t_diff_compares_real_paths_not_the_stage() {
  new_case $FUNCNAME; apply_ok; run -- $(stdv diff); eq "$RC" 0 "a diff that compared stage-rewritten text would report the etc paths as drift"
}

# ---- phase 3: apply ------------------------------------------------------------

t_apply_installs_the_rendered_files() {
  new_case $FUNCNAME; apply_ok; local e=$CASE_DIR/etc
  for f in conf.d/caltechdata_log.conf conf.d/cloudflare_real_ip.conf; do exists "$e/$f" "$f"; done
  has "$(cat "$e/snippets/caltechdata-host.conf")" "server_name host.example.org;" "the host file is generated"
  has "$(cat "$e/snippets/caltechdata-tls.conf")" "include snippets/self-signed.conf;" "the tls snippet"
  eq "$(readlink "$e/sites-enabled/caltechdata.conf")" "$e/sites-available/caltechdata.conf" "the sites-enabled link"
}
t_apply_installs_the_repository_files_not_the_stage_copies() {
  new_case $FUNCNAME; apply_ok
  eq "$(grep -rl "$CASE_DIR/tmp" "$CASE_DIR/etc" 2>/dev/null | wc -l | tr -d ' ')" 0 "an installed file mentions the stage path"
  cmp -s "$CASE_DIR/etc/conf.d/caltechdata_log.conf" "$CASE_DIR/repo/nginx/conf.d/caltechdata_log.conf" || fail "the installed file (through its link) is not the repository's, byte for byte"
}
t_apply_installs_generated_files_with_mode_0644() {
  new_case $FUNCNAME; apply_ok
  for f in caltechdata-host caltechdata-tls; do eq "$(mode_of "$CASE_DIR/etc/snippets/$f.conf")" "-rw-r--r--" "snippets/$f.conf"; done
}
t_apply_leaves_the_packaged_nginx_conf_and_every_other_file_alone() {
  new_case $FUNCNAME; echo "# another site's file" > "$CASE_DIR/etc/conf.d/other.conf"; ln -s /nowhere "$CASE_DIR/etc/sites-enabled/default"
  local sum_conf sum_other; sum_conf=$(cksum < "$CASE_DIR/etc/nginx.conf"); sum_other=$(tree_sig "$CASE_DIR/etc" | grep -E 'other.conf|sites-enabled/default|mime.types|dhparam')
  apply_ok
  eq "$(cksum < "$CASE_DIR/etc/nginx.conf")" "$sum_conf" "the packaged nginx.conf"
  eq "$(tree_sig "$CASE_DIR/etc" | grep -E 'other.conf|sites-enabled/default|mime.types|dhparam')" "$sum_other" "the unmanaged files"
}
t_a_second_apply_changes_nothing() {
  new_case $FUNCNAME; apply_ok; local sig; sig=$(tree_sig "$CASE_DIR/etc"); : > "$CASE_DIR/stub.log"
  run -- $(stdv apply) --yes --no-logagent --reload; eq "$RC" 0 "exit"; has "$OUT" "no change" "says so"
  eq "$(tree_sig "$CASE_DIR/etc")" "$sig" "the tree"; eq "$(n_backups)" 1 "no second backup"
  eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "nothing to reload"
}
t_apply_asks_first_and_a_no_changes_nothing() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  RUN_STDIN=n; run -- $(stdv apply) --no-logagent; eq "$RC" 1 "an n declines (exit 1, nothing wrong, the answer is no)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup"
  RUN_STDIN=; run -- $(stdv apply) --no-logagent; eq "$RC" 1 "an empty answer declines"
  RUN_STDIN=y; run -- $(stdv apply) --no-logagent; eq "$RC" 0 "a y proceeds (stderr: $ERR)"; exists "$CASE_DIR/etc/sites-available/caltechdata.conf" "installed"
}
t_apply_stops_at_the_staged_gates_before_any_change() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_T_RC=1 -- $(stdv apply) --yes --no-logagent; eq "$RC" 65 "a failing staged nginx -t"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup"
  run STUB_LOGAGENT_RC=1 -- $(stdv apply) --yes; eq "$RC" 65 "a logagent gap"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree after the gap"; eq "$(n_backups)" 0 "no backup after the gap"
}
t_a_failing_installed_test_restores_everything() {
  new_case $FUNCNAME; echo "# the old limits" > "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_INSTALLED_RC=1 -- $(stdv apply) --yes --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "restored" "says it restored"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree is byte-identical to before"
  eq "$(n_backups)" 1 "the backup is kept"; exists "$(latest_backup)/MANIFEST" "its manifest"
}
t_a_stage_that_cannot_be_built_changes_nothing() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root, chmod would not stop the copy)"; return; fi
  local before; before=$(tree_sig "$CASE_DIR/etc"); chmod 555 "$CASE_DIR/etc/sites-available"
  run -- $(stdv apply) --yes --no-logagent; local rc=$RC; chmod 755 "$CASE_DIR/etc/sites-available"
  eq "$rc" 74 "exit"; eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup was made for a stage that never got built"
}
t_a_copy_that_fails_part_way_is_restored() {
  new_case $FUNCNAME
  echo "# the old limits" > "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run PATH="$CASE_DIR/bin:$PATH" STUB_INSTALL_FAIL_ON=sites-available -- $(stdv apply) --yes --no-logagent
  eq "$RC" 74 "exit (stderr: $ERR)"; has "$ERR" "restored" "says it restored"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the conf.d files installed before the failure are undone"
  eq "$(n_backups)" 1 "the backup is kept"
}
t_a_half_written_file_from_a_failed_install_is_removed() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run PATH="$CASE_DIR/bin:$PATH" STUB_INSTALL_FAIL_ON=snippets/caltechdata-host.conf.nginx-deploy.new -- $(stdv apply) --yes --no-logagent
  eq "$RC" 74 "exit (stderr: $ERR)"
  eq "$(find "$CASE_DIR/etc" -name '*.nginx-deploy.new' | wc -l | tr -d ' ')" 0 "no half-written .new file is left behind"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree is as it was"
}
t_two_backups_in_the_same_second_do_not_overwrite_each_other() {
  new_case $FUNCNAME
  run PATH="$CASE_DIR/bin:$PATH" STUB_DATE=20260101-000000 -- $(stdv apply) --yes --no-logagent; eq "$RC" 0 "first apply (stderr: $ERR)"
  hand_copy conf.d/cloudflare_real_ip.conf "# edited by hand"
  run PATH="$CASE_DIR/bin:$PATH" STUB_DATE=20260101-000000 -- $(stdv apply) --yes --no-logagent; eq "$RC" 0 "second apply (stderr: $ERR)"
  eq "$(n_backups)" 2 "two backup directories"
  exists "$CASE_DIR/backups/20260101-000000/MANIFEST" "the first"; exists "$CASE_DIR/backups/20260101-000000-2/MANIFEST" "the second"
  has "$(cat "$CASE_DIR/backups/20260101-000000/MANIFEST")" "created conf.d/cloudflare_real_ip.conf" "the first backup is intact"
  has "$(cat "$CASE_DIR/backups/20260101-000000-2/files/conf.d/cloudflare_real_ip.conf")" "# edited by hand" "the second holds the hand edit"
}
t_the_backup_has_a_stamp_name_and_a_manifest() {
  new_case $FUNCNAME; apply_ok; local b; b=$(latest_backup)
  printf '%s' "$(basename "$b")" | grep -Eq '^[0-9]{8}-[0-9]{6}' || fail "the backup name '$(basename "$b")' is not a stamp"
  local m; m=$(cat "$b/MANIFEST")
  has "$m" "etc_dir=$CASE_DIR/etc" "the etc directory"; has "$m" "created conf.d/cloudflare_real_ip.conf" "a created file"
  has "$m" "link-created sites-enabled/caltechdata.conf" "the created link"
}
t_the_backup_holds_only_what_was_replaced() {
  new_case $FUNCNAME; apply_ok; hand_copy conf.d/caltechdata_log.conf "# edited by hand"
  apply_ok; local b; b=$(latest_backup)
  eq "$(find "$b/files" -type f | wc -l | tr -d ' ')" 1 "one file backed up"
  has "$(cat "$b/files/conf.d/caltechdata_log.conf")" "# edited by hand" "it holds the host's version"
  has "$(cat "$b/MANIFEST")" "replaced conf.d/caltechdata_log.conf" "the manifest says replaced"
}
t_a_backup_directory_that_cannot_be_made_is_cant_create() {
  new_case $FUNCNAME; echo "a file" > "$CASE_DIR/blocker"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run -- $(stdv apply) --yes --no-logagent --backup-dir "$CASE_DIR/blocker/sub"; eq "$RC" 73 "exit"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "nothing is installed without a backup"
}
t_nothing_reloads_without_the_flag() {
  new_case $FUNCNAME; apply_ok; eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no systemctl call"
}
t_reload_follows_a_good_installed_test() {
  new_case $FUNCNAME; apply_ok --reload; eq "$(grep -c '^systemctl reload nginx$' "$CASE_DIR/stub.log")" 1 "one reload"
  local last_t last_r; last_t=$(grep -n "^nginx -t -c $CASE_DIR/etc/nginx.conf" "$CASE_DIR/stub.log" | tail -1 | cut -d: -f1); last_r=$(grep -n '^systemctl reload' "$CASE_DIR/stub.log" | cut -d: -f1)
  [ -n "$last_t" ] && [ -n "$last_r" ] && [ "$last_t" -lt "$last_r" ] || fail "the reload must come after the installed-tree test (test line '$last_t', reload line '$last_r')"
}
t_a_failing_reload_is_unavailable_and_keeps_the_files() {
  new_case $FUNCNAME; run STUB_SYSTEMCTL_RC=1 -- $(stdv apply) --yes --no-logagent --reload
  eq "$RC" 69 "exit"; has "$ERR" "previous configuration" "says nginx keeps serving the old one"
  exists "$CASE_DIR/etc/sites-available/caltechdata.conf" "the files stay installed, since the tree itself is good"
}
t_a_failing_installed_test_never_reloads() {
  new_case $FUNCNAME; run STUB_NGINX_INSTALLED_RC=1 -- $(stdv apply) --yes --no-logagent --reload
  eq "$RC" 65 "exit"; eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no reload"
}
t_reload_needs_systemctl_before_anything_changes() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run SYSTEMCTL=/nonexistent/systemctl -- $(stdv apply) --yes --no-logagent --reload; eq "$RC" 66 "exit"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"
}
t_a_new_server_name_replaces_the_host_file_and_backs_up_the_old_one() {
  new_case $FUNCNAME; apply_ok
  run -- $(stdv apply) --yes --no-logagent --server-name other.example.org; eq "$RC" 0 "exit (stderr: $ERR)"
  has "$(cat "$CASE_DIR/etc/snippets/caltechdata-host.conf")" "server_name other.example.org;" "the new name"
  has "$(cat "$(latest_backup)/files/snippets/caltechdata-host.conf")" "server_name host.example.org;" "the backup holds the old host file"
}
t_apply_needs_root_for_the_default_etc_dir() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- apply --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed --yes --no-logagent; eq "$RC" 77 "exit"
}

# ---- phase 3: rollback ---------------------------------------------------------

t_rollback_after_a_first_apply_restores_the_original_tree() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  apply_ok; run -- $(stdr) --no-logagent; run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "created files and the link are gone"
}
t_rollback_restores_replaced_content_and_a_replaced_link() {
  new_case $FUNCNAME
  echo "# the old limits" > "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"
  echo "# an old site" > "$CASE_DIR/etc/sites-available/old.conf"; ln -s "$CASE_DIR/etc/sites-available/old.conf" "$CASE_DIR/etc/sites-enabled/caltechdata.conf"
  local before; before=$(tree_sig "$CASE_DIR/etc"); apply_ok
  run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"; eq "$(tree_sig "$CASE_DIR/etc")" "$before" "content and link restored"
}
t_rollback_with_no_backups_is_no_input() {
  new_case $FUNCNAME; run -- $(stdr); eq "$RC" 66 "no backup directory"; has "$ERR" "no backups" "says so"
  mkdir "$CASE_DIR/backups"; run -- $(stdr); eq "$RC" 66 "an empty backup directory"; has "$ERR" "no backups under" "says so, and not that a named backup is missing"
}
t_rollback_takes_the_latest_or_the_named_stamp() {
  new_case $FUNCNAME; apply_ok; local first; first=$(basename "$(latest_backup)")
  hand_copy conf.d/cloudflare_real_ip.conf "# hand edit"; apply_ok
  run -- $(stdr); eq "$RC" 0 "rollback of the latest"; has "$(cat "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf")" "# hand edit" "the latest backup returns the hand-edited file"
  run -- $(stdr) "$first"; eq "$RC" 0 "rollback of the named first backup"; absent "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf" "the first backup returns the host to before anything was installed"
}
t_an_unknown_stamp_is_no_input() {
  new_case $FUNCNAME; apply_ok; run -- $(stdr) 19990101-000000; eq "$RC" 66 "exit"; has "$ERR" "19990101-000000" "names the stamp"
}
t_rollback_tests_the_restored_tree() {
  new_case $FUNCNAME; apply_ok; run STUB_NGINX_INSTALLED_RC=1 -- $(stdr); eq "$RC" 65 "exit"
}
t_rollback_reloads_only_with_the_flag() {
  new_case $FUNCNAME; apply_ok; run -- $(stdr); eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no flag, no reload"
  apply_ok; run -- $(stdr) --reload; eq "$(grep -c '^systemctl reload nginx$' "$CASE_DIR/stub.log")" 1 "with the flag, one reload"
}
t_rollback_refuses_another_etc_dir() {
  new_case $FUNCNAME; apply_ok; mkdir "$CASE_DIR/etc2"
  run -- rollback --etc-dir "$CASE_DIR/etc2" --backup-dir "$CASE_DIR/backups"; eq "$RC" 2 "exit"; has "$ERR" "$CASE_DIR/etc" "names the directory the backup belongs to"
}
t_rollback_survives_files_that_are_already_gone() {
  new_case $FUNCNAME; apply_ok; rm "$CASE_DIR/etc/conf.d/caltechdata_log.conf"; run -- $(stdr); eq "$RC" 0 "exit (stderr: $ERR)"
}

# ---- snippets/ssl-params.conf is managed (2026-10-27) --------------------------
# cloud-init used to be its only writer and the script only checked that it existed, so
# a CaltechAUTHORS host (2026-10-27) kept a pre-2026-09-10 copy ending in "add_header X-Frame-Options DENY;".
# Next to the application's "sameorigin" that made the browser refuse to frame the file preview.

# make_stale_ssl_params gives the fixture the snippet as cloud-init wrote it before 2026-09-10.
make_stale_ssl_params() {
  rm -f "$CASE_DIR/etc/snippets/ssl-params.conf"   # a link after apply: writing through it would edit the repository
  printf 'ssl_protocols TLSv1.2 TLSv1.3;\nadd_header X-Frame-Options DENY;\nadd_header X-Content-Type-Options nosniff;\n' \
    > "$CASE_DIR/etc/snippets/ssl-params.conf"
}
t_diff_reports_a_stale_ssl_params_snippet() {
  new_case $FUNCNAME; apply_ok; run -- $(stdv diff); eq "$RC" 0 "no drift after apply"
  make_stale_ssl_params
  run -- $(stdv diff); eq "$RC" 1 "drift"
  has "$OUT" "differs  snippets/ssl-params.conf" "names the file"; has "$OUT" "-add_header X-Frame-Options DENY;" "the diff shows the stale header"
}
t_apply_replaces_a_stale_ssl_params_snippet_and_rollback_puts_it_back() {
  new_case $FUNCNAME; make_stale_ssl_params; local stale; stale=$(cat "$CASE_DIR/etc/snippets/ssl-params.conf")
  apply_ok
  cmp -s "$CASE_DIR/etc/snippets/ssl-params.conf" "$CASE_DIR/repo/nginx/snippets/ssl-params.conf" || fail "the installed snippet is not the repository's"
  hasnt "$(grep -v '^[[:space:]]*#' "$CASE_DIR/etc/snippets/ssl-params.conf")" "add_header" "the stale headers are gone (the comments still tell their story)"
  has "$(cat "$(latest_backup)/MANIFEST")" "replaced snippets/ssl-params.conf" "the manifest says replaced"
  eq "$(cat "$(latest_backup)/files/snippets/ssl-params.conf")" "$stale" "the backup holds the host's copy"
  run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"
  eq "$(cat "$CASE_DIR/etc/snippets/ssl-params.conf")" "$stale" "rollback puts the host's copy back"
}
t_the_ssl_params_snippet_sends_no_headers() {
  # DR-0005: the application owns the security headers; an add_header here doubles one of them
  new_case $FUNCNAME
  eq "$(grep -v '^[[:space:]]*#' "$HERE/nginx/snippets/ssl-params.conf" | grep -c 'add_header')" 0 "add_header outside a comment"
  has "$(cat "$HERE/nginx/snippets/ssl-params.conf")" "ssl_dhparam /etc/nginx/dhparam.pem;" "it names the DH parameters the script requires"
}

# ---- DR-0011: the repository's files are linked, not copied ----------------------

t_apply_links_the_repository_files_into_etc() {
  new_case $FUNCNAME; apply_ok; local e=$CASE_DIR/etc r=$CASE_DIR/repo/nginx f
  for f in caltechdata_log cloudflare_real_ip; do
    eq "$(readlink "$e/conf.d/$f.conf")" "$r/conf.d/$f.conf" "conf.d/$f.conf links into the checkout"
  done
  eq "$(readlink "$e/sites-available/caltechdata.conf")" "$r/sites-available/caltechdata.conf" "the site file"
  eq "$(readlink "$e/snippets/ssl-params.conf")" "$r/snippets/ssl-params.conf" "ssl-params"
  eq "$(readlink "$e/snippets/caltechdata-redirect-map.conf")" "$r/redirect-map.conf" "the redirect map"
  eq "$(readlink "$e/sites-enabled/caltechdata.conf")" "$e/sites-available/caltechdata.conf" "sites-enabled links to sites-available"
}
t_the_generated_host_files_are_regular_files() {
  new_case $FUNCNAME; apply_ok; local e=$CASE_DIR/etc f
  for f in caltechdata-host caltechdata-tls; do
    { [ -f "$e/snippets/$f.conf" ] && [ ! -L "$e/snippets/$f.conf" ]; } || fail "snippets/$f.conf is not a regular file (a pull must never change it)"
  done
  eq "$(grep -v '^#' "$e/snippets/caltechdata-host.conf" | grep .)" "server_name host.example.org;
set \$caltechdata_static $CASE_DIR/repo/.venv/var/instance/static;" "the host file holds the server name and the static path, nothing else"
}
t_the_repository_files_carry_no_host_tokens() {
  new_case $FUNCNAME; local bad site
  bad=$(cd "$HERE/nginx" && grep -rn '@[A-Z][A-Z_]*@' . | grep -v '^\./tls/' | head -3)
  eq "$bad" "" "a token outside nginx/tls/ (linked files cannot be rendered)"
  site=$(grep -v '^[[:space:]]*#' "$HERE/nginx/sites-available/caltechdata.conf")
  eq "$(printf '%s\n' "$site" | grep -c '/Sites/')" 0 "no checkout path in the site file"
  has "$site" "include snippets/caltechdata-redirect-map.conf;" "the map is included through /etc/nginx"
  has "$site" 'alias $caltechdata_static;' "the static alias is a variable"
}
t_a_change_in_the_checkout_is_live_through_the_links() {
  new_case $FUNCNAME; apply_ok
  echo "# a repository edit" >> "$CASE_DIR/repo/nginx/conf.d/cloudflare_real_ip.conf"
  has "$(cat "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf")" "# a repository edit" "the host sees the edit through the link"
  run -- $(stdv diff); eq "$RC" 0 "a changed file behind a correct link is not drift (out: $OUT)"
}
t_check_fails_on_a_dangling_link() {
  # the 2026-11-05 outage: a pull moved the redirect map and the include pointed at nothing
  new_case $FUNCNAME; apply_ok; local before; before=$(tree_sig "$CASE_DIR/etc")
  ln -sfn "$CASE_DIR/repo/redirect-map.conf" "$CASE_DIR/etc/snippets/caltechdata-redirect-map.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"
  has "$ERR" "dangling: snippets/caltechdata-redirect-map.conf -> $CASE_DIR/repo/redirect-map.conf" "names the dangling link and where it points"
  eq "$(tree_sig "$CASE_DIR/etc" | grep -v 'caltechdata-redirect-map')" "$(printf '%s\n' "$before" | grep -v 'caltechdata-redirect-map')" "check changed nothing else"
}
t_check_names_every_broken_link() {
  new_case $FUNCNAME; apply_ok
  ln -sfn "$CASE_DIR/repo/redirect-map.conf" "$CASE_DIR/etc/snippets/caltechdata-redirect-map.conf"
  ln -sfn "$CASE_DIR/repo/nginx/conf.d/gone.conf" "$CASE_DIR/etc/conf.d/caltechdata_log.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"
  has "$ERR" "dangling: snippets/caltechdata-redirect-map.conf" "the first link"; has "$ERR" "dangling: conf.d/caltechdata_log.conf" "the second link"
}
t_check_fails_when_a_link_points_outside_the_checkout() {
  new_case $FUNCNAME; apply_ok; echo "# not ours" > "$CASE_DIR/other.conf"
  ln -sfn "$CASE_DIR/other.conf" "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "conf.d/cloudflare_real_ip.conf" "names the link"; has "$ERR" "outside the checkout" "says why"
}
t_apply_repairs_a_moved_checkout() {
  new_case $FUNCNAME; apply_ok; mv "$CASE_DIR/repo" "$CASE_DIR/repo2"
  local a="--repo-dir $CASE_DIR/repo2 --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml --backup-dir $CASE_DIR/backups"
  run -- check $a --no-logagent; eq "$RC" 65 "the links still point at the old path (stderr: $ERR)"
  run -- apply $a --yes --no-logagent; eq "$RC" 0 "apply repairs them (stderr: $ERR)"
  eq "$(readlink "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf")" "$CASE_DIR/repo2/nginx/conf.d/cloudflare_real_ip.conf" "the link follows the checkout"
  has "$(grep -v '^#' "$CASE_DIR/etc/snippets/caltechdata-host.conf")" "$CASE_DIR/repo2/.venv" "the generated static path follows it too"
  run -- check $a --no-logagent; eq "$RC" 0 "check is clean afterwards (stderr: $ERR)"
}
t_apply_replaces_a_hand_made_copy_with_a_link_and_rollback_puts_it_back() {
  # production today: regular files in /etc/nginx made by hand
  new_case $FUNCNAME; printf '# the hand-made copy\nlimit_req_zone x;\n' > "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"
  local mine; mine=$(cat "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf")
  apply_ok
  [ -L "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf" ] || fail "the hand-made copy was not replaced by a link"
  has "$(cat "$(latest_backup)/MANIFEST")" "replaced conf.d/cloudflare_real_ip.conf" "the manifest says replaced"
  eq "$(cat "$(latest_backup)/files/conf.d/cloudflare_real_ip.conf")" "$mine" "the backup holds the hand-made copy"
  run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"
  { [ -f "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf" ] && [ ! -L "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf" ]; } || fail "rollback did not put a regular file back"
  eq "$(cat "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf")" "$mine" "the hand-made copy, byte for byte"
}
t_rollback_removes_the_links_a_first_apply_made() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  apply_ok; run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree is as it was"
}
t_the_stage_holds_copies_not_links_into_the_checkout() {
  # DR-0011 open point 1: the staged nginx -t must never be able to touch the checkout
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s f; s=$(staged_dir)
  for f in conf.d/cloudflare_real_ip.conf sites-available/caltechdata.conf snippets/caltechdata-redirect-map.conf snippets/ssl-params.conf; do
    { [ -f "$s/$f" ] && [ ! -L "$s/$f" ]; } || fail "$f in the stage is not a regular file"
  done
}
t_a_missing_redirect_map_in_the_repository_is_no_input() {
  new_case $FUNCNAME; rm "$CASE_DIR/repo/nginx/redirect-map.conf"; run -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "$CASE_DIR/repo/nginx/redirect-map.conf" "names the file"
}
t_a_server_block_without_the_access_log_fails_check() {
  new_case $FUNCNAME
  awk '/access_log .*caltechdata_bots/ && !d {d=1; next} {print}' "$CASE_DIR/repo/nginx/sites-available/caltechdata.conf" > "$CASE_DIR/site.tmp" \
    && mv "$CASE_DIR/site.tmp" "$CASE_DIR/repo/nginx/sites-available/caltechdata.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit (stderr: $ERR)"; has "$ERR" "access_log" "names the directive"; has "$ERR" "caltechdata_bots" "names the format"
}
t_an_awk_failure_in_the_logging_check_is_internal() {
  # a check that cannot read the dump must not pass: an awk error is exit 70, never a quiet 0
  new_case $FUNCNAME
  printf '#!/bin/bash\ncase "$*" in *insrv*) echo "awk: stub failure" >&2; exit 2;; esac\nexec "$(PATH=/usr/bin:/bin command -v awk)" "$@"\n' > "$CASE_DIR/bin/awk"; chmod +x "$CASE_DIR/bin/awk"
  run PATH="$CASE_DIR/bin:$PATH" -- $(std) --no-logagent; eq "$RC" 70 "exit (stderr: $ERR)"; has "$ERR" "awk" "names awk"
}
t_a_missing_log_format_fails_check() {
  new_case $FUNCNAME; rm "$CASE_DIR/repo/nginx/conf.d/caltechdata_log.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit (stderr: $ERR)"; has "$ERR" "log_format" "names the directive"
}
t_help_describes_the_links_and_the_upgrade_procedure() {
  new_case $FUNCNAME; run -- --help; eq "$RC" 0 "exit"
  has "$OUT" "symbolic link" "the links"; has "$OUT" "git pull" "the procedure starts with the pull"
  has "$OUT" "sudo ./nginx-deploy.bash verify" "and continues with verify, which needs no host arguments"
  has "$OUT" "core.hooksPath" "and says where the hook comes from"
}

# ---- DR-0011: verify, the read-only check of an installed host ----------------------

# vfy prints the options verify takes: no server name, no --tls (the hook and verify_rdm_boot.bash know neither).
vfy() { echo "verify --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc"; }

t_verify_passes_on_an_applied_host_without_a_server_name_or_tls() {
  new_case $FUNCNAME; apply_ok; run -- $(vfy); eq "$RC" 0 "exit (stderr: $ERR)"
  has "$OUT" "nginx -t on the installed tree: ok" "the installed tree was tested"; has "$OUT" "verify: " "says what it did"
}
t_verify_tests_the_installed_tree_and_changes_nothing() {
  new_case $FUNCNAME; apply_ok; local before; before=$(tree_sig "$CASE_DIR/etc"); : > "$CASE_DIR/stub.log"
  run -- $(vfy); eq "$RC" 0 "exit (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 1 "no backup directory was made"
  has "$(cat "$CASE_DIR/stub.log")" "nginx -t -c $CASE_DIR/etc/nginx.conf" "nginx tested the live file, not a stage"
}
t_verify_fails_on_a_dangling_link() {
  new_case $FUNCNAME; apply_ok; ln -sfn "$CASE_DIR/repo/redirect-map.conf" "$CASE_DIR/etc/snippets/caltechdata-redirect-map.conf"
  run -- $(vfy); eq "$RC" 65 "exit"; has "$ERR" "dangling: snippets/caltechdata-redirect-map.conf -> $CASE_DIR/repo/redirect-map.conf" "names the link"
}
t_verify_fails_on_a_missing_link() {
  new_case $FUNCNAME; apply_ok; rm "$CASE_DIR/etc/conf.d/cloudflare_real_ip.conf"
  run -- $(vfy); eq "$RC" 65 "exit"; has "$ERR" "missing: conf.d/cloudflare_real_ip.conf" "names the link"
}
t_verify_fails_on_a_regular_file_where_a_link_belongs() {
  new_case $FUNCNAME; apply_ok; hand_copy conf.d/cloudflare_real_ip.conf "# hand edit"
  run -- $(vfy); eq "$RC" 65 "exit"; has "$ERR" "not a link: conf.d/cloudflare_real_ip.conf" "names the file"
}
t_verify_fails_on_a_host_that_was_never_deployed() {
  new_case $FUNCNAME; run -- $(vfy); eq "$RC" 65 "exit"; has "$ERR" "missing: sites-enabled/caltechdata.conf" "says what is missing"
}
t_verify_fails_when_a_host_file_is_missing() {
  new_case $FUNCNAME; apply_ok; rm "$CASE_DIR/etc/snippets/caltechdata-host.conf"
  run -- $(vfy); eq "$RC" 65 "exit"; has "$ERR" "missing: snippets/caltechdata-host.conf" "names the file"
}
t_verify_fails_when_nginx_rejects_the_installed_tree() {
  new_case $FUNCNAME; apply_ok
  run STUB_NGINX_INSTALLED_RC=1 STUB_NGINX_T_MSG="nginx: [emerg] open() failed in the live tree" -- $(vfy); eq "$RC" 65 "exit"
  has "$ERR" "open() failed in the live tree" "nginx's own message is shown"
}
t_verify_checks_the_logging() {
  new_case $FUNCNAME; apply_ok
  awk '/access_log .*caltechdata_bots/ && !d {d=1; next} {print}' "$CASE_DIR/repo/nginx/sites-available/caltechdata.conf" > "$CASE_DIR/site.tmp" \
    && cat "$CASE_DIR/site.tmp" > "$CASE_DIR/repo/nginx/sites-available/caltechdata.conf"
  run -- $(vfy); eq "$RC" 65 "exit (stderr: $ERR)"; has "$ERR" "access_log" "names the directive"
}
t_verify_needs_root_for_the_default_etc_dir() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- verify --repo-dir "$CASE_DIR/repo"; eq "$RC" 77 "exit"
}
t_verify_takes_no_other_arguments_or_flags() {
  new_case $FUNCNAME; apply_ok
  run -- $(vfy) surplus; eq "$RC" 2 "a surplus argument"
  run -- $(vfy) --reload; eq "$RC" 2 "--reload"; run -- $(vfy) --yes; eq "$RC" 2 "--yes"
}
t_verify_is_in_the_help() {
  new_case $FUNCNAME; run -- --help; has "$OUT" "nginx-deploy.bash verify" "the synopsis"; has "$OUT" "hook" "the help says who calls it"
}

# ---- DR-0011: the post-merge hook and core.hooksPath ---------------------------------

# hook_case builds a fixture for the hook: a git checkout, a fake /etc/nginx with or without the host file, and a
# stub nginx-deploy.bash that records its arguments and exits $STUB_VERIFY_RC after printing $STUB_VERIFY_OUT.
hook_case() { # hook_case NAME [deployed]
  new_case "$1"; mkdir -p "$CASE_DIR/clone"; git init -q "$CASE_DIR/clone"
  [ "${2:-}" != deployed ] || echo "server_name x;" > "$CASE_DIR/etc/snippets/caltechdata-host.conf"
  cat > "$CASE_DIR/stub-deploy.bash" <<'EOS'
#!/bin/bash
echo "stub-deploy $*" >> "$STUB_LOG"
[ -z "${STUB_VERIFY_OUT:-}" ] || echo "$STUB_VERIFY_OUT"
exit "${STUB_VERIFY_RC:-0}"
EOS
}
# run_hook HOOK [VAR=value ...] runs a hook from the repository's .githooks inside the fixture clone; sets OUT, ERR, RC.
run_hook() {
  local hook=$1; shift
  OUT=$(cd "$CASE_DIR/clone" && env STUB_LOG="$CASE_DIR/stub.log" NGINX_DEPLOY="$CASE_DIR/stub-deploy.bash" NGINX_DEPLOY_ETC="$CASE_DIR/etc" \
    NGINX_DEPLOY_SUDO=env "$@" "$HERE/.githooks/$hook" 2> "$CASE_DIR/err")
  RC=$?; ERR=$(cat "$CASE_DIR/err")
}

t_the_hooks_exist_and_are_executable() {
  new_case $FUNCNAME
  for h in post-merge post-rewrite; do [ -x "$HERE/.githooks/$h" ] || fail ".githooks/$h is missing or not executable"; done
}
t_the_hook_is_silent_on_a_clone_that_was_never_deployed() {
  hook_case $FUNCNAME; run_hook post-merge
  eq "$RC" 0 "exit"; eq "$OUT$ERR" "" "a developer's pull prints nothing"; eq "$(grep -c '^stub-deploy' "$CASE_DIR/stub.log")" 0 "verify was not run"
}
t_the_hook_runs_verify_on_a_deployed_host_and_says_ok() {
  hook_case $FUNCNAME deployed; run_hook post-merge
  eq "$RC" 0 "exit"; has "$OUT$ERR" "nginx" "it says something"; has "$(cat "$CASE_DIR/stub.log")" "stub-deploy verify --repo-dir $(cd "$CASE_DIR/clone" && pwd -P) --etc-dir $CASE_DIR/etc" "verify ran on the checkout (git reports the real path)"
  hasnt "$OUT$ERR" "FAILED" "no alarm"
}
t_the_hook_warns_loudly_when_verify_fails_and_never_fails_the_pull() {
  hook_case $FUNCNAME deployed; run_hook post-merge STUB_VERIFY_RC=65 STUB_VERIFY_OUT="  dangling: snippets/x.conf -> /nowhere"
  eq "$RC" 0 "the hook never fails the pull (git ignores it anyway)"
  has "$OUT$ERR" "NGINX CHECK FAILED" "the banner"; has "$OUT$ERR" "dangling: snippets/x.conf" "verify's own message is shown"
  has "$OUT$ERR" "do not restart nginx" "what to do"
}
t_the_hook_says_so_when_it_could_not_run_verify() {
  hook_case $FUNCNAME deployed; run_hook post-merge STUB_VERIFY_RC=1 STUB_VERIFY_OUT="sudo: a password is required"
  eq "$RC" 0 "exit"; has "$OUT$ERR" "COULD NOT BE RUN" "says it did not check"; has "$OUT$ERR" "sudo ./nginx-deploy.bash verify" "gives the command to run by hand"
  hasnt "$OUT$ERR" "NGINX CHECK FAILED" "it does not claim the config is bad"
}
t_post_rewrite_runs_the_same_check() {
  hook_case $FUNCNAME deployed; run_hook post-rewrite STUB_VERIFY_RC=65 STUB_VERIFY_OUT="  dangling: a -> b"
  eq "$RC" 0 "exit"; has "$OUT$ERR" "NGINX CHECK FAILED" "the banner"
}
t_apply_points_the_checkout_at_the_repository_hooks() {
  new_case $FUNCNAME; git init -q "$CASE_DIR/repo"; mkdir -p "$CASE_DIR/repo/.githooks"
  apply_ok
  eq "$(git -C "$CASE_DIR/repo" config --get core.hooksPath)" ".githooks" "core.hooksPath"
}
t_apply_leaves_a_different_hooks_path_alone_and_says_so() {
  new_case $FUNCNAME; git init -q "$CASE_DIR/repo"; mkdir -p "$CASE_DIR/repo/.githooks"; git -C "$CASE_DIR/repo" config core.hooksPath other-hooks
  apply_ok
  eq "$(git -C "$CASE_DIR/repo" config --get core.hooksPath)" "other-hooks" "left alone"; has "$OUT" "other-hooks" "says what it found"
}
t_apply_without_a_git_checkout_or_hooks_directory_changes_no_git_config() {
  new_case $FUNCNAME; apply_ok; absent "$CASE_DIR/repo/.git" "no git directory was created"
  git init -q "$CASE_DIR/repo"; apply_ok
  eq "$(git -C "$CASE_DIR/repo" config --get core.hooksPath || true)" "" "a checkout with no .githooks directory is left alone"
}
t_verify_notes_when_the_hook_is_not_enabled() {
  new_case $FUNCNAME; git init -q "$CASE_DIR/repo"; mkdir -p "$CASE_DIR/repo/.githooks"; apply_ok
  git -C "$CASE_DIR/repo" config --unset core.hooksPath
  run -- $(vfy); eq "$RC" 0 "a missing hook is a note, not a failure (stderr: $ERR)"
  has "$ERR" "core.hooksPath" "the note names the setting"; has "$ERR" ".githooks" "and the value"
}

# ---- another site answering for the same name (caltechdata DR-0003 decision 9, kept by DR-0007 decision 11) ----
# nginx -t PASSES when two enabled sites claim one server_name on one port: it only warns "conflicting server
# name ... ignored" and serves whichever it read first. A host with an older hand-made site still linked from
# sites-enabled would then answer from the old file while this script reports success.

CONFLICT='nginx: [warn] conflicting server name "host.example.org" on 0.0.0.0:443, ignored'
t_a_conflicting_server_name_is_refused() {
  new_case $FUNCNAME; ln -s /nowhere "$CASE_DIR/etc/sites-enabled/old-site"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_T_WARN="$CONFLICT" -- $(std) --no-logagent
  eq "$RC" 65 "exit"; has "$ERR" "conflicting server name" "quotes nginx's warning"
  has "$ERR" "sites-enabled" "names the directory to look in"; has "$ERR" "old-site" "lists the enabled sites"
  has "$ERR" "do not delete" "says to move the link, not delete the file"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "nothing changed"
}
t_apply_refuses_a_conflicting_server_name_before_any_change() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_T_WARN="$CONFLICT" -- $(stdv apply) --yes --no-logagent
  eq "$RC" 65 "exit"; has "$ERR" "conflicting server name" "says why"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "nothing changed"; eq "$(n_backups)" 0 "no backup was made"
}
t_an_unrelated_nginx_warning_does_not_block() {
  # only the conflicting-name warning is a refusal; nginx -t prints others (types_hash, for one) on healthy hosts
  new_case $FUNCNAME
  run STUB_NGINX_T_WARN='nginx: [warn] could not build optimal types_hash, you should increase either types_hash_max_size: 1024 or types_hash_bucket_size: 64' -- $(std) --no-logagent
  eq "$RC" 0 "exit (stderr: $ERR)"
}

# ---- DR-0007 decision 10: no --migrate-legacy, no package system -------------------------------
# The replacement host is built by cloud-init and never hand-edited, so the legacy migration is gone. A host
# whose nginx.conf was edited by hand is not recognised, so it is not refused and not repaired: the staged
# nginx -t (and logagent) are what stop a configuration that cannot work.

t_migrate_legacy_and_cache_dir_are_not_options() {
  new_case $FUNCNAME
  run -- $(std) --migrate-legacy; eq "$RC" 2 "--migrate-legacy is a usage error"; has "$ERR" "--migrate-legacy" "names the flag"
  run -- $(std) --cache-dir "$CASE_DIR/cache"; eq "$RC" 2 "--cache-dir is a usage error"; has "$ERR" "--cache-dir" "names the flag"
}
t_a_hand_edited_nginx_conf_is_left_alone_and_the_package_system_is_not_used() {
  new_case $FUNCNAME
  echo "# hand edit: error_log warn" >> "$CASE_DIR/etc/nginx.conf"; local sum; sum=$(cksum < "$CASE_DIR/etc/nginx.conf")
  # stubs on PATH, so a call by bare name is recorded whatever variable the script reads
  local t; for t in apt-get dpkg-query dpkg-deb; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 1\n' "$t" > "$CASE_DIR/bin/$t"; chmod +x "$CASE_DIR/bin/$t"
  done
  run PATH="$CASE_DIR/bin:$PATH" -- $(stdv apply) --yes --no-logagent; eq "$RC" 0 "apply (stderr: $ERR)"
  eq "$(cksum < "$CASE_DIR/etc/nginx.conf")" "$sum" "the hand-edited nginx.conf is not touched"
  hasnt "$(cat "$CASE_DIR/stub.log")" "apt-get" "apt-get was never called"
  hasnt "$(cat "$CASE_DIR/stub.log")" "dpkg-query" "dpkg-query was never called"
  hasnt "$(cat "$CASE_DIR/stub.log")" "dpkg-deb" "dpkg-deb was never called"
}

# ---- the site file (caltechdata DR-0001 and DR-0007 decisions 2 and 3) ------------------------
# These read the repository's own site file through the staged copy, so they test what would be deployed.

# site_block prints the staged site file's block that opens with the given location line, to its closing brace.
site_block() { # site_block STAGE 'location line text'
  awk -v loc="  $2 {" 'index($0, loc) == 1 {on=1} on {print} on && /^  }/ {exit}' "$1/sites-available/caltechdata.conf"
}
t_the_redirect_map_include_is_the_first_directive() {
  # map_hash_* must come before any map block (caltechauthors DR-0003), and redirect-map.conf sets them. DR-0007
  # decision 2: the include is by relative name through the linked snippet, not an absolute path into the checkout.
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local first; first=$(grep -v '^[[:space:]]*\(#\|$\)' "$(staged_dir)/sites-available/caltechdata.conf" | head -1)
  eq "$first" "include snippets/caltechdata-redirect-map.conf;" "the first directive is the include, through /etc/nginx"
}
t_the_api_location_forwards_the_uri_unmodified() {
  # the matched pair with rdm_rest.service's --url-path-prefix /api: a trailing slash on proxy_pass would strip it twice
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local blk; blk=$(site_block "$(staged_dir)" "location /api")
  has "$blk" "proxy_pass http://127.0.0.1:5001;" "the REST port, no trailing slash"
  hasnt "$blk" "proxy_pass http://127.0.0.1:5001/" "no prefix strip in nginx"
  hasnt "$(grep -v '^[[:space:]]*#' "$(staged_dir)/sites-available/caltechdata.conf")" "rewrite " "no rewrite anywhere"
}
t_the_site_file_speaks_http_to_the_application() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local code; code=$(grep -v '^[[:space:]]*#' "$(staged_dir)/sites-available/caltechdata.conf")
  hasnt "$code" "uwsgi" "no uwsgi directive"; has "$code" "proxy_pass http://127.0.0.1:5000;" "the UI port"
}
t_the_file_upload_location_allows_large_bodies_and_streams_them() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local s code; s=$(staged_dir); code=$(grep -v '^[[:space:]]*#' "$s/sites-available/caltechdata.conf")
  has "$code" "client_max_body_size 500G;" "500G on the draft file content location"
  has "$code" "proxy_request_buffering off;" "a request body streams to the application"
  has "$code" "proxy_buffering off;" "a response streams to the client"
  has "$code" "proxy_read_timeout 3600s;" "a long upload is not cut at the default 60 s"
}
t_the_security_headers_are_the_applications_not_nginxs() {
  # caltechauthors DR-0005: an X-Frame-Options here as well as Talisman's doubles it. HSTS and the
  # request id are nginx's own and are restated where a location's add_header would drop them.
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local code; code=$(grep -v '^[[:space:]]*#' "$(staged_dir)/sites-available/caltechdata.conf")
  hasnt "$code" "X-Frame-Options" "no X-Frame-Options"; hasnt "$code" "X-Content-Type-Options" "no X-Content-Type-Options"
  has "$(site_block "$(staged_dir)" "location /static")" 'add_header Strict-Transport-Security "max-age=15768000";' "/static restates HSTS"
}
t_mjs_is_typed_at_http_level_not_inside_a_server() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local site; site=$(grep -v '^[[:space:]]*#' "$(staged_dir)/sites-available/caltechdata.conf")
  has "$site" "text/javascript mjs;" "the .mjs type"
  eq "$(printf '%s\n' "$site" | awk '/^server \{/ {exit} {print}' | grep -c 'text/javascript mjs')" 1 "it comes before the first server block"
}

# ---- the runner -------------------------------------------------------------

PATTERN=${1:-}
TESTS=$(declare -F | awk '{print $3}' | grep '^t_' | sort)
echo "nginx-deploy_test.bash: $(echo "$TESTS" | wc -w | tr -d ' ') tests, script $SCRIPT"
for t in $TESTS; do
  if [ -n "$PATTERN" ]; then case "$t" in *"$PATTERN"*) ;; *) continue;; esac; fi
  TEST_OK=1
  ( "$t" ) > "$ROOT/$t.out" 2>&1
  # a function cannot set the parent's TEST_OK from a subshell, so a failure is a FAIL line in its output
  if grep -q '^      FAIL:' "$ROOT/$t.out" || [ ! -x "$SCRIPT" ]; then
    echo "FAIL  $t"; sed 's/^/      /' "$ROOT/$t.out" | grep -v '^            ' | head -8
    [ -x "$SCRIPT" ] || echo "      (the script $SCRIPT does not exist or is not executable)"
    FAILED=$((FAILED+1)); FAILED_NAMES="$FAILED_NAMES $t"
  else
    echo "PASS  $t"; PASSED=$((PASSED+1))
    grep '(skipped' "$ROOT/$t.out" | head -1
  fi
done
echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
