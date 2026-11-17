#!/bin/bash
#
# cloud-init_test.bash - tests for the bring-up files: cloud-init.yaml, its Multipass
# variant, and the .gitignore that keeps their build artifacts out of git.
#
# Usage: ./cloud-init_test.bash
#
# Reads files only; nothing is launched. CLOUD_INIT_DIR (default: this file's directory)
# is where the two cloud-init files and .gitignore are read from, so a test can be pointed
# at a mutated copy.
#
# EXIT STATUS: 0 every test passed; 1 a test failed.
#
# Written for bash 3.2 (macOS) and later: no associative arrays, no mapfile.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${CLOUD_INIT_DIR:-$HERE}
PASSED=0
FAILED=0

# check NAME COMMAND... runs COMMAND and counts the case as passed when it exits 0.
check() {
  local name=$1
  shift
  if "$@" > /dev/null 2>&1; then
    echo "PASS  $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL  $name"
    FAILED=$((FAILED + 1))
  fi
}

# multipass_header prints the lines of the Multipass variant above the shared body.
multipass_header() {
  sed -n '1,/^# Bring-up machine/p' "$DIR/cloud-init-multipass.yaml"
}

# body FILE prints FILE from its "# Bring-up machine" line on, the part both files share.
body() {
  sed -n '/^# Bring-up machine/,$p' "$1"
}

# celery's beat scheduler writes celerybeat-schedule.db into the working directory
gitignore_covers_celerybeat_db() {
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/cloud-init-test.XXXXXX") || return 1
  git init -q "$scratch" || return 1
  cp "$DIR/.gitignore" "$scratch/.gitignore"
  git -C "$scratch" check-ignore -q celerybeat-schedule.db
  local rc=$?
  rm -rf "$scratch"
  return $rc
}

# the header's launch line must be one a 16 GB host can run: --memory 8G, with the heap
# lowered to 1g in the VM's own checkout (the 2026-10-29 fresh build used exactly this)
header_documents_8g_launch() {
  local h
  h=$(multipass_header)
  echo "$h" | grep -q -- '--memory 8G' && echo "$h" | grep -q -- 's/-Xms4g -Xmx4g/-Xms1g -Xmx1g/'
}

# "byte-identical except for this header" is a claim in the file; keep it true
bodies_identical() {
  diff <(body "$DIR/cloud-init.yaml") <(body "$DIR/cloud-init-multipass.yaml")
}

# contains FILE TEXT succeeds when the fixed string TEXT appears in FILE.
contains() {
  grep -qF -- "$2" "$DIR/$1"
}

# lacks FILE TEXT succeeds when the fixed string TEXT does not appear in FILE.
lacks() {
  ! grep -qF -- "$2" "$DIR/$1"
}


# the boot check asks as a client of the site, not of "localhost": production's invenio.cfg trusts only data.caltech.edu, so a
# request with Host: localhost is refused with 400 once a host is configured as production (2026-11-16, caltechdata-v14).
count_is() { [ "$(grep -cF -- "$2" "$DIR/$1")" -eq "$3" ]; }

# api_responds, extracted from the YAML and run with a stub curl, must send the site's Host header
api_responds_sends_the_site_host() {
  local scratch fn rc=1
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/cloud-init-test.XXXXXX") || return 1
  printf '#!/bin/sh\necho "$@" >> "%s/args"\necho 200\n' "$scratch" > "$scratch/curl" && chmod +x "$scratch/curl"
  fn=$(sed -n '/^      api_responds() {/,/^      }/p' "$DIR/$1" | sed 's/^      //')
  [ -n "$fn" ] || { rm -rf "$scratch"; return 1; }
  ( PATH="$scratch:$PATH"; SITE_HOST=data.caltech.edu; eval "$fn"; api_responds ) && grep -q 'Host: data.caltech.edu' "$scratch/args" && rc=0
  rm -rf "$scratch"
  return $rc
}

# the reboot scripts, the nginx check at boot, and the nginx install (caltechdata DR-0007, plan R5). The
# two files share one body, so every case runs against both.
for f in cloud-init.yaml cloud-init-multipass.yaml; do
  check "$f: pandoc is installed (admin-shell-scripts' make install builds man pages with it)" contains "$f" "  - pandoc"
  check "$f: setup installs safe_to_reboot.bash from the checkout's admin/" contains "$f" 'admin/safe_to_reboot.bash" /usr/local/bin/safe_to_reboot.bash'
  check "$f: setup installs caltechdata_down.bash from the checkout's admin/" contains "$f" 'admin/caltechdata_down.bash" /usr/local/bin/caltechdata_down.bash'
  check "$f: the scripts are installed with install(1), mode 0755" contains "$f" 'sudo install -m 0755 "/Sites/${INSTANCE_NAME}/admin/safe_to_reboot.bash"'
  check "$f: setup stops early if the branch has no admin scripts" contains "$f" 'if [ ! -f admin/safe_to_reboot.bash ] || [ ! -f admin/caltechdata_down.bash ]'
  check "$f: verify_rdm_boot.bash checks nginx's installed configuration" contains "$f" 'check "nginx'"'"'s installed configuration is a sound deployment of the checkout" nginx_config_is_sound'
  check "$f: that check runs nginx-deploy.bash verify on the checkout" contains "$f" 'nginx-deploy.bash" verify \'
  check "$f: verify_rdm_boot.bash checks the two RDM reboot scripts" contains "$f" 'check "safe_to_reboot.bash and caltechdata_down.bash are installed" reboot_scripts_installed'
  check "$f: verify_rdm_boot.bash checks check-for-reboot.bash" contains "$f" 'check "check-for-reboot.bash (admin-shell-scripts) is installed" check_for_reboot_installed'
  check "$f: the person-run step is named in the install notes" contains "$f" "sudo make install prefix=/usr/local"
  check "$f: nginx-deploy.bash apply still installs the nginx configuration" contains "$f" 'nginx-deploy.bash" apply --yes --reload'
  check "$f: the stale 'caltechdata does not have nginx-deploy.bash yet' note is gone" lacks "$f" "which caltechdata does not have yet"
  check "$f: the stale 'stops with a message until it is ported' note is gone" lacks "$f" "stops with a message until it is ported"
  check "$f: the guard's message no longer says the script is yet to be ported" lacks "$f" "It is ported from caltechdata on the"
  check "$f: .env sets INVENIO_PROXYFIX_CONFIG (without it SAML presents http:// URLs under Granian)" contains "$f" 'INVENIO_PROXYFIX_CONFIG={"x_for": 1, "x_proto": 1}'
  check "$f: .env suppresses mail, so a host holding real users cannot email them before cutover" contains "$f" 'INVENIO_MAIL_SUPPRESS_SEND=True'
  check "$f: the server name is not hard-coded (SERVER_NAME, default _)" contains "$f" 'SERVER_NAME="${SERVER_NAME:-_}"'
  check "$f: the TLS mode is not hard-coded (TLS_MODE, default self-signed)" contains "$f" 'TLS_MODE="${TLS_MODE:-self-signed}"'
  check "$f: nginx-deploy.bash apply takes the server name and TLS mode from those variables" contains "$f" '--server-name "$SERVER_NAME" --tls "$TLS_MODE"'
  check "$f: the hard-coded '--server-name _ --tls self-signed' is gone" lacks "$f" '--server-name _ --tls self-signed'
  check "$f: an existing checkout is updated, not cloned over (a rerun does not die)" contains "$f" 'git -C "/Sites/${INSTANCE_NAME}" fetch'
  check "$f: the boot check's site host defaults to data.caltech.edu (SITE_HOST)" contains "$f" 'SITE_HOST="${SITE_HOST:-data.caltech.edu}"'
  check "$f: all five boot-check requests send that Host header" count_is "$f" '-H "Host: ${SITE_HOST}"' 5
  check "$f: api_responds sends the site's Host header (stub curl)" api_responds_sends_the_site_host "$f"
  check "$f: a test instance's trusted hosts also admit data.caltech.edu, so the boot check passes there" contains "$f" 'INVENIO_TRUSTED_HOSTS=["data.caltech.edu","localhost","127.0.0.1","0.0.0.0"]'
  check "$f: the old localhost-only trusted hosts line is gone" lacks "$f" 'INVENIO_TRUSTED_HOSTS=["localhost","127.0.0.1","0.0.0.0"]'
done

check gitignore_covers_celerybeat_db gitignore_covers_celerybeat_db
check header_documents_8g_launch header_documents_8g_launch
check bodies_identical bodies_identical

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
