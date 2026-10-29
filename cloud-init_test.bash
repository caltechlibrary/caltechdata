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

check gitignore_covers_celerybeat_db gitignore_covers_celerybeat_db
check header_documents_8g_launch header_documents_8g_launch
check bodies_identical bodies_identical

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
