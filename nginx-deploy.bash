#!/bin/bash
#
# nginx-deploy.bash - deploy this repository's nginx configuration to a host by copy.
#
# Ported from caltechauthors DR-0009 (agents/projects/caltechdata/plans/nginx_deploy_port.md; no IIIF cache,
# no log_format files). Verbs: check, diff, apply, rollback. The repository's nginx/ tree
# mirrors /etc/nginx; this script renders it for one host, tests the result on a STAGED copy
# of the host's /etc/nginx before it copies anything, backs up what it replaces, and can put
# the backup back. The packaged /etc/nginx/nginx.conf is never edited, except that
# --migrate-legacy puts the package's own file back over a hand-edited one.
#
# Written for bash 3.2 (macOS) and later.

set -u

VERSION=0.0.4
PROG=nginx-deploy.bash

# Exit codes, workspace DR-0014.
EX_OK=0
EX_NEGATIVE=1
EX_USAGE=2
EX_DATA=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_INTERNAL=70
EX_CANTCREAT=73
EX_IOERR=74
EX_NOPERM=77
EX_CONFIG=78

usage_text() {
  cat <<'EOF'
NAME
  nginx-deploy.bash - deploy the repository's nginx configuration to a host by copy

SYNOPSIS
  nginx-deploy.bash check    [OPTIONS] [--migrate-legacy]
  nginx-deploy.bash diff     [OPTIONS]
  nginx-deploy.bash apply    [OPTIONS] [--migrate-legacy] [--reload] [--yes]
  nginx-deploy.bash rollback [--etc-dir DIR] [--backup-dir DIR] [--reload] [STAMP]
  nginx-deploy.bash --help | --version

DESCRIPTION
  The repository's nginx/ tree mirrors /etc/nginx. This script renders it for one host
  (replacing the tokens written between @ signs in the site file) and installs it by COPY,
  never by symlink, so a change to the checkout is never a live change to the host. The
  packaged /etc/nginx/nginx.conf is never edited.

VERBS
  check     render, build a STAGED copy of the host's /etc/nginx with the rendered files laid
            over it, and test that copy with `nginx -t -c` and, if installed, `logagent check`;
            changes nothing on the host
  diff      show the installed files against the rendered ones; exit 1 when they differ; a host
            that still has the legacy configuration (see --migrate-legacy) is reported as drift
  apply     check, then back up what will be replaced, copy the rendered files, run `nginx -t`
            on the installed tree, and restore the backup if that fails. Reloads nginx only
            with --reload. Asks first unless --yes is given.
  rollback  put a backup back (the latest, or the named STAMP), run `nginx -t`, and reload
            only with --reload

OPTIONS
  --server-name NAME     the host's name, for server_name ("_" is a catch-all). Required for
                         check, diff and apply.
  --tls letsencrypt|self-signed
                         which certificate pair the site uses. Required for check, diff, apply.
  --cert-name NAME       the Let's Encrypt lineage under /etc/letsencrypt/live/
                         (default: the server name; used with --tls letsencrypt)
  --site-name NAME       the site file's name under sites-available/ (default: caltechdata)
  --repo-dir DIR         the checkout holding nginx/ (default: this script's directory); the
                         redirect map and the static files are found under it
  --etc-dir DIR          the nginx configuration directory (default: /etc/nginx)
  --backup-dir DIR       where apply keeps its backups (default: /var/backups/caltechdata-nginx)
  --logagent-config FILE logagent's host configuration (default: /etc/logagent/logagent.yaml)
  --require-logagent     a missing logagent is an error, not a skipped step
  --no-logagent          do not run logagent check
  --migrate-legacy       check and apply: move a host that was configured by hand onto this layout.
                         Such a host has an /etc/nginx/nginx.conf edited away from the nginx-common
                         package's. Without this option check and apply refuse (exit 65) and say so.
                         With it, the staged tree is built from the migrated state, apply backs
                         nginx.conf up, replaces it with the package's own (taken from the nginx-common
                         .deb that apt-get downloads, and accepted only if its md5 is the one dpkg
                         recorded) and installs; rollback undoes all of it. A host with nothing legacy
                         is not touched, and the package system is not used. Where dpkg cannot say
                         what the package's nginx.conf is, a hand edit cannot be recognised, so
                         check and apply treat the host as stock and --migrate-legacy stops (exit 66).
  --reload               apply and rollback: reload nginx after a good test
  --yes                  apply: do not ask first (for installers)
  --keep-stage           keep the staged tree and print its path (for debugging)
  --help, --version

ENVIRONMENT
  NGINX      the nginx program (default: nginx)
  LOGAGENT   the logagent program (default: logagent)
  SYSTEMCTL  the systemctl program, used by --reload (default: systemctl)
  DPKG_QUERY the dpkg-query program, used to find out whether nginx.conf was modified (default: dpkg-query)
  APT_GET    the apt-get program, used by --migrate-legacy to download nginx-common (default: apt-get)
  DPKG_DEB   the dpkg-deb program, used by --migrate-legacy to read that package (default: dpkg-deb)

EXIT STATUS
   0  success, or nothing to do
   1  the answer is no: diff found drift, or apply was declined
   2  usage: unknown verb or option, a missing or surplus argument, a bad value
  65  the configuration was rejected: nginx -t failed or logagent found a gap (before any
      change, or after one that was then restored), a token was left unreplaced, the host has
      legacy configuration and --migrate-legacy was not given, or the package's nginx.conf does
      not match the checksum dpkg recorded
  66  a needed input is missing: nginx, systemctl with --reload, the repository's nginx/ tree,
      the etc directory, a snippet or dhparam.pem it requires, a backup, logagent with
      --require-logagent, or (--migrate-legacy) dpkg-query unable to name the installed
      nginx-common and its nginx.conf checksum
  69  --reload: systemctl could not reload nginx (the files are installed and nginx -t
      passes; nginx keeps serving the previous configuration); or --migrate-legacy: apt-get
      could not download nginx-common (nothing was changed)
  70  an error nothing classified (a bug)
  73  the backup directory could not be made (nothing was changed)
  74  a copy failed part way (the backup was restored)
  77  not root, and --etc-dir is /etc/nginx
  78  logagent's configuration file is present and wrong
EOF
}

die() { # die CODE MESSAGE...
  local code=$1; shift
  echo "$PROG: $*" >&2
  exit "$code"
}

usage_error() { # usage_error MESSAGE...
  echo "$PROG: $*" >&2
  echo "try: $PROG --help" >&2
  exit $EX_USAGE
}

WORK=""
KEEP=0
cleanup() {
  if [ -n "$WORK" ] && [ "$KEEP" -ne 1 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ---- arguments ---------------------------------------------------------------

POS=()
SERVER_NAME=""
TLS=""
CERT_NAME=""
SITE_NAME=caltechdata
REPO_DIR=""
ETC_DIR=/etc/nginx
BACKUP_ROOT=/var/backups/caltechdata-nginx
LOGAGENT_CONFIG=/etc/logagent/logagent.yaml
REQUIRE_LOGAGENT=0
NO_LOGAGENT=0
RELOAD=0
YES=0
MIGRATE=0

need_value() { # need_value OPTION COUNT
  [ "$2" -ge 2 ] || usage_error "option $1 needs a value"
}

while [ $# -gt 0 ]; do
  arg=$1
  case "$arg" in
    --*=*) opt=${arg%%=*}; val=${arg#*=}; shift; set -- "$opt" "$val" "$@"; arg=$1 ;;
  esac
  case "$arg" in
    --help|-h) usage_text; exit $EX_OK ;;
    --version) echo "$PROG $VERSION"; exit $EX_OK ;;
    --server-name) need_value "$arg" $#; SERVER_NAME=$2; shift 2 ;;
    --tls) need_value "$arg" $#; TLS=$2; shift 2 ;;
    --cert-name) need_value "$arg" $#; CERT_NAME=$2; shift 2 ;;
    --site-name) need_value "$arg" $#; SITE_NAME=$2; shift 2 ;;
    --repo-dir) need_value "$arg" $#; REPO_DIR=$2; shift 2 ;;
    --etc-dir) need_value "$arg" $#; ETC_DIR=$2; shift 2 ;;
    --backup-dir) need_value "$arg" $#; BACKUP_ROOT=$2; shift 2 ;;
    --logagent-config) need_value "$arg" $#; LOGAGENT_CONFIG=$2; shift 2 ;;
    --require-logagent) REQUIRE_LOGAGENT=1; shift ;;
    --no-logagent) NO_LOGAGENT=1; shift ;;
    --reload) RELOAD=1; shift ;;
    --yes) YES=1; shift ;;
    --migrate-legacy) MIGRATE=1; shift ;;
    --keep-stage) KEEP=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
    -*) usage_error "unknown option: $arg" ;;
    *) POS+=("$arg"); shift ;;
  esac
done

[ ${#POS[@]} -gt 0 ] || usage_error "no verb given (the verbs are: check, diff, apply, rollback)"
VERB=${POS[0]}
case "$VERB" in
  check|diff|apply|rollback) ;;
  *) usage_error "unknown verb: $VERB (the verbs are: check, diff, apply, rollback)" ;;
esac
STAMP_ARG=""
if [ "$VERB" = rollback ]; then
  [ ${#POS[@]} -le 2 ] || usage_error "surplus argument: ${POS[2]}"
  [ ${#POS[@]} -lt 2 ] || STAMP_ARG=${POS[1]}
else
  [ ${#POS[@]} -le 1 ] || usage_error "surplus argument: ${POS[1]}"
fi
case "$VERB" in
  check|diff) [ "$RELOAD" -eq 0 ] || usage_error "--reload only applies to apply and rollback" ;;
esac
[ "$VERB" = apply ] || [ "$YES" -eq 0 ] || usage_error "--yes only applies to apply"
case "$VERB" in
  check|apply) ;;
  *) [ "$MIGRATE" -eq 0 ] || usage_error "--migrate-legacy only applies to check and apply" ;;
esac

# ---- validating the values ---------------------------------------------------

name_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }
abs_path_ok() { printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/-]+$'; }

ETC_DIR=${ETC_DIR%/}
[ -n "$ETC_DIR" ] || usage_error "--etc-dir must not be /"
BACKUP_ROOT=${BACKUP_ROOT%/}
abs_path_ok "$BACKUP_ROOT" || usage_error "--backup-dir '$BACKUP_ROOT' must be an absolute path of letters, digits, . _ - and /"

if [ "$VERB" != rollback ]; then
  [ -n "$SERVER_NAME" ] || usage_error "--server-name is required"
  name_ok "$SERVER_NAME" || usage_error "--server-name '$SERVER_NAME' may only contain letters, digits, . _ and -"
  [ -n "$TLS" ] || usage_error "--tls is required (letsencrypt or self-signed)"
  case "$TLS" in
    letsencrypt|self-signed) ;;
    *) usage_error "--tls '$TLS' is not one of: letsencrypt, self-signed" ;;
  esac
  [ -n "$CERT_NAME" ] || CERT_NAME=$SERVER_NAME
  name_ok "$CERT_NAME" || usage_error "--cert-name '$CERT_NAME' may only contain letters, digits, . _ and -"
  name_ok "$SITE_NAME" || usage_error "--site-name '$SITE_NAME' may only contain letters, digits, . _ and -"
  if [ -z "$REPO_DIR" ]; then REPO_DIR=$(cd "$(dirname "$0")" && pwd); fi
  abs_path_ok "$REPO_DIR" || usage_error "--repo-dir '$REPO_DIR' must be an absolute path of letters, digits, . _ - and /"
  REPO_DIR=${REPO_DIR%/}
  if [ "$REQUIRE_LOGAGENT" -eq 1 ] && [ "$NO_LOGAGENT" -eq 1 ]; then
    usage_error "--require-logagent and --no-logagent contradict each other"
  fi
fi

# ---- what must exist before anything is built ------------------------------------

# Everything but diff writes to, or reads certificates and logs through, the nginx directory.
if [ "$VERB" != diff ] && [ "$ETC_DIR" = /etc/nginx ] && [ "$(id -u)" != 0 ]; then
  die $EX_NOPERM "run as root: this reads /etc/nginx (certificates, logs) and runs nginx -t"
fi

NGINX_BIN=${NGINX:-nginx}
if [ "$VERB" != diff ]; then
  case "$NGINX_BIN" in
    */*) [ -x "$NGINX_BIN" ] || die $EX_NOINPUT "nginx not found: $NGINX_BIN" ;;
    *) command -v "$NGINX_BIN" >/dev/null 2>&1 || die $EX_NOINPUT "nginx not found on PATH" ;;
  esac
fi

DPKG_QUERY_BIN=${DPKG_QUERY:-dpkg-query}
APT_GET_BIN=${APT_GET:-apt-get}
DPKG_DEB_BIN=${DPKG_DEB:-dpkg-deb}

SYSTEMCTL_BIN=${SYSTEMCTL:-systemctl}
if [ "$RELOAD" -eq 1 ]; then
  case "$SYSTEMCTL_BIN" in
    */*) [ -x "$SYSTEMCTL_BIN" ] || die $EX_NOINPUT "systemctl not found: $SYSTEMCTL_BIN (--reload needs it)" ;;
    *) command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || die $EX_NOINPUT "systemctl not found on PATH (--reload needs it)" ;;
  esac
fi

[ -d "$ETC_DIR" ] || die $EX_NOINPUT "the nginx configuration directory is missing: $ETC_DIR"

if [ "$VERB" != rollback ]; then
  SRC=$REPO_DIR/nginx
  [ -d "$SRC" ] || die $EX_NOINPUT "the repository's nginx tree is missing: $SRC"
  [ -f "$SRC/sites-available/caltechdata.conf" ] || die $EX_NOINPUT "missing: $SRC/sites-available/caltechdata.conf"
  [ -f "$SRC/tls/$TLS.conf" ] || die $EX_NOINPUT "missing: $SRC/tls/$TLS.conf"
  [ -f "$SRC/snippets/ssl-params.conf" ] || die $EX_NOINPUT "missing: $SRC/snippets/ssl-params.conf"
fi

if [ "$VERB" = check ] || [ "$VERB" = apply ]; then
  [ -f "$ETC_DIR/nginx.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/nginx.conf"
  # Written by cloud-init, not by this script; it is required, not created. (snippets/ssl-params.conf
  # was too, until a host kept a stale copy of it: it is managed now, see render_all.)
  [ -f "$ETC_DIR/dhparam.pem" ] || die $EX_NOINPUT "missing: $ETC_DIR/dhparam.pem (cloud-init writes it)"
  if [ "$TLS" = self-signed ]; then
    [ -f "$ETC_DIR/snippets/self-signed.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/snippets/self-signed.conf (cloud-init writes it; --tls self-signed needs it)"
  fi
fi

OWNER=""
if [ "$(id -u)" = 0 ]; then OWNER="-o root -g root"; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nginx-deploy.XXXXXX") || die $EX_IOERR "could not make a working directory"

# ---- rendering ---------------------------------------------------------------

# render_file SOURCE DEST replaces the closed set of tokens and fails if one is left.
render_file() {
  sed -e "s#@SERVER_NAME@#$SERVER_NAME#g" -e "s#@REPO_DIR@#$REPO_DIR#g" -e "s#@CERT_NAME@#$CERT_NAME#g" "$1" > "$2" \
    || die $EX_IOERR "could not render $1"
  local left
  left=$(grep -n -o '@[A-Z][A-Z_]*@' "$2" | head -3 | tr '\n' ' ')
  [ -z "$left" ] || die $EX_DATA "a token is left unreplaced in $1: $left"
}

# sed_escape STRING escapes a literal for use in a sed pattern that uses # as its delimiter.
sed_escape() { printf '%s' "$1" | sed 's/[][\.*^$#]/\\&/g'; }

# rewrite_in_tree DIR FROM TO replaces the literal FROM with TO in every text file under DIR.
rewrite_in_tree() {
  local dir=$1 from=$2 to=$3 f pat
  pat=$(sed_escape "$from")
  grep -rlIF -- "$from" "$dir" 2>/dev/null | while read -r f; do
    sed "s#$pat#$to#g" "$f" > "$f.rewrite.tmp" && mv "$f.rewrite.tmp" "$f"
  done
}

RENDER=$WORK/render
MANAGED=()      # the files this script owns, relative to the etc directory
LINK_REL=""
LINK_TARGET=""

# render_all renders every managed file into $RENDER, in the layout of the etc directory.
render_all() {
  mkdir -p "$RENDER/conf.d" "$RENDER/sites-available" "$RENDER/snippets" || die $EX_IOERR "could not make $RENDER"
  # the repository has no conf.d today; one that is added later is overlaid like the rest
  local f
  for f in "$SRC"/conf.d/*.conf; do
    [ -f "$f" ] || continue
    render_file "$f" "$RENDER/conf.d/$(basename "$f")"
    MANAGED+=("conf.d/$(basename "$f")")
  done
  render_file "$SRC/sites-available/caltechdata.conf" "$RENDER/sites-available/$SITE_NAME.conf"
  MANAGED+=("sites-available/$SITE_NAME.conf")
  render_file "$SRC/tls/$TLS.conf" "$RENDER/snippets/caltechdata-tls.conf"
  MANAGED+=("snippets/caltechdata-tls.conf")
  render_file "$SRC/snippets/ssl-params.conf" "$RENDER/snippets/ssl-params.conf"
  MANAGED+=("snippets/ssl-params.conf")
  LINK_REL="sites-enabled/$SITE_NAME.conf"
  LINK_TARGET="$ETC_DIR/sites-available/$SITE_NAME.conf"
}

# ---- the legacy configuration (a host configured by hand before this script) ---

LEG_CONF=0      # nginx.conf differs from the nginx-common package's
STOCK_MD5=""    # the md5 dpkg recorded for the package's nginx.conf

# md5_of FILE prints the file's md5 (md5sum on Linux, md5 on macOS).
md5_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum < "$1" | awk '{print $1}'; else md5 -q "$1"; fi
}

# detect_legacy sets LEG_CONF and STOCK_MD5. A modified nginx.conf is one whose md5 is not the
# package's (the check dpkg --verify makes). Where dpkg cannot say, nothing can be recognised, and the
# host is treated as stock.
detect_legacy() {
  LEG_CONF=0
  [ -f "$ETC_DIR/nginx.conf" ] || return 0
  STOCK_MD5=$("$DPKG_QUERY_BIN" -W -f='${Conffiles}\n' nginx-common 2>/dev/null | awk '$1=="/etc/nginx/nginx.conf"{print $2; exit}')
  if [ -n "$STOCK_MD5" ]; then
    [ "$(md5_of "$ETC_DIR/nginx.conf")" = "$STOCK_MD5" ] || LEG_CONF=1
  fi
}

# refuse_legacy is exit 65: installing next to a hand-edited nginx.conf is not what was tested.
refuse_legacy() {
  {
    echo "$PROG: this host has configuration from before this script:"
    [ "$LEG_CONF" -ne 1 ] || echo "  $ETC_DIR/nginx.conf differs from the nginx-common package's (it was edited by hand)"
    echo "Nothing was changed. To migrate, repeat the command with --migrate-legacy: it backs up nginx.conf,"
    echo "restores the package's own and installs; rollback undoes all of it."
  } >&2
  exit $EX_DATA
}

# fetch_stock puts the package's own nginx.conf at $RENDER/nginx.conf. It downloads the installed
# version of nginx-common (apt-get download needs no root and changes nothing on the host), reads only
# that file out of the .deb, and accepts it only if its md5 is the one dpkg recorded. (apt-get install
# --reinstall --force-confnew does NOT do this: dpkg keeps a modified conffile when the package's
# version has not changed. Rehearsed on the Multipass VM, 2026-10-13.)
fetch_stock() {
  local ver deb got
  [ -n "$STOCK_MD5" ] || die $EX_NOINPUT "cannot restore the package's nginx.conf: dpkg-query ($DPKG_QUERY_BIN) cannot say which nginx.conf checksum the nginx-common package has"
  ver=$("$DPKG_QUERY_BIN" -W -f='${Version}' nginx-common 2>/dev/null)
  [ -n "$ver" ] || die $EX_NOINPUT "cannot restore the package's nginx.conf: dpkg-query ($DPKG_QUERY_BIN) cannot say which version of nginx-common is installed"
  mkdir -p "$WORK/pkg" || die $EX_IOERR "could not make $WORK/pkg"
  if ! ( cd "$WORK/pkg" && "$APT_GET_BIN" download "nginx-common=$ver" ) > "$WORK/apt.out" 2>&1; then
    cat "$WORK/apt.out" >&2
    die $EX_UNAVAILABLE "apt-get could not download nginx-common=$ver; nothing was changed"
  fi
  deb=$(ls "$WORK"/pkg/nginx-common_*.deb 2>/dev/null | head -1)
  [ -n "$deb" ] || die $EX_UNAVAILABLE "apt-get download left no .deb for nginx-common=$ver; nothing was changed"
  "$DPKG_DEB_BIN" --fsys-tarfile "$deb" 2>/dev/null | tar -xO ./etc/nginx/nginx.conf > "$RENDER/nginx.conf" 2>/dev/null
  got=$(md5_of "$RENDER/nginx.conf")
  [ "$got" = "$STOCK_MD5" ] || die $EX_DATA "the nginx.conf in the downloaded nginx-common=$ver has md5 $got, but dpkg recorded md5 $STOCK_MD5; nothing was changed"
}

# prepare_legacy is run by check and apply after render_all. It refuses a legacy host unless
# --migrate-legacy was given, and then makes the package's nginx.conf one of the managed files.
prepare_legacy() {
  detect_legacy
  # --migrate-legacy that cannot tell whether nginx.conf was edited must not look like success
  if [ "$MIGRATE" -eq 1 ] && [ -z "$STOCK_MD5" ]; then
    die $EX_NOINPUT "--migrate-legacy: cannot tell whether $ETC_DIR/nginx.conf was edited: dpkg-query ($DPKG_QUERY_BIN) cannot say which nginx.conf checksum the nginx-common package has"
  fi
  [ "$LEG_CONF" -eq 1 ] || return 0
  [ "$MIGRATE" -eq 1 ] || refuse_legacy
  fetch_stock
  MANAGED+=("nginx.conf")
  echo "legacy: $ETC_DIR/nginx.conf differs from the package's; it will be replaced by the package's own"
}

# ---- the staged tree and its gates (check, and the start of apply) -------------

STAGE=$WORK/stage
DUMP=$WORK/dump.txt

build_stage() {
  mkdir -p "$STAGE" || die $EX_IOERR "could not make $STAGE"
  # cp -RL cannot dereference a dangling symlink; those are re-created below as dangling links, so
  # the staged nginx -t fails exactly where the host's would. Any other copy error is real.
  if ! cp -RL "$ETC_DIR/." "$STAGE/" 2> "$WORK/cp.err"; then
    if grep -v 'No such file or directory' "$WORK/cp.err" | grep -q .; then
      cat "$WORK/cp.err" >&2
      die $EX_IOERR "could not copy $ETC_DIR into the stage"
    fi
  fi
  local l rel
  find "$ETC_DIR" -type l | while read -r l; do
    [ -e "$l" ] && continue
    rel=${l#"$ETC_DIR"/}
    mkdir -p "$(dirname "$STAGE/$rel")" && ln -sfn "$(readlink "$l")" "$STAGE/$rel"
  done
  mkdir -p "$STAGE/conf.d" "$STAGE/sites-available" "$STAGE/sites-enabled" "$STAGE/snippets"
  for rel in "${MANAGED[@]}"; do
    cp "$RENDER/$rel" "$STAGE/$rel" || die $EX_IOERR "could not stage $rel"
  done
  ln -sfn "$STAGE/sites-available/$SITE_NAME.conf" "$STAGE/$LINK_REL" || die $EX_IOERR "could not link the site into the stage"
  # Point the staged copy at itself, so even a test cannot change the host.
  rewrite_in_tree "$STAGE" "$ETC_DIR/" "$STAGE/"
  if [ "$KEEP" -eq 1 ]; then echo "stage: $STAGE" >&2; fi
}

run_gates() {
  if ! "$NGINX_BIN" -t -c "$STAGE/nginx.conf" > "$WORK/nginx-t.out" 2>&1; then
    cat "$WORK/nginx-t.out" >&2
    die $EX_DATA "nginx -t rejected the staged configuration; nothing was changed on this host"
  fi
  echo "nginx -t on the staged tree: ok"

  if ! "$NGINX_BIN" -T -c "$STAGE/nginx.conf" > "$DUMP" 2> "$WORK/nginx-T.err"; then
    cat "$WORK/nginx-T.err" >&2
    die $EX_DATA "nginx -T could not dump the staged configuration"
  fi

  if [ "$NO_LOGAGENT" -eq 1 ]; then
    echo "logagent check: not run (--no-logagent)"
    return
  fi
  local la=${LOGAGENT:-logagent} found=0 rc
  case "$la" in
    */*) [ -x "$la" ] && found=1 ;;
    *) command -v "$la" >/dev/null 2>&1 && found=1 ;;
  esac
  if [ "$found" -eq 0 ]; then
    if [ "$REQUIRE_LOGAGENT" -eq 1 ]; then die $EX_NOINPUT "logagent not found ($la) and --require-logagent was given"; fi
    echo "$PROG: logagent not found; skipped logagent check (--require-logagent makes this an error)" >&2
    return
  fi
  "$la" check --config "$LOGAGENT_CONFIG" --dump "$DUMP" --sample 0 > "$WORK/logagent.out" 2>&1
  rc=$?
  case "$rc" in
    0) cat "$WORK/logagent.out"; echo "logagent check on the staged tree: ok" ;;
    1) cat "$WORK/logagent.out" >&2; die $EX_DATA "logagent check found a gap in the staged configuration; nothing was changed on this host" ;;
    66) cat "$WORK/logagent.out" >&2; die $EX_NOINPUT "logagent could not find its configuration ($LOGAGENT_CONFIG)" ;;
    78) cat "$WORK/logagent.out" >&2; die $EX_CONFIG "logagent's configuration file is wrong ($LOGAGENT_CONFIG)" ;;
    *) cat "$WORK/logagent.out" >&2; die $EX_INTERNAL "logagent check exited $rc, which this script does not know" ;;
  esac
}

# ---- comparing the installed files with the rendered ones ----------------------

CHG_REL=()     # what apply would change, relative to the etc directory
CHG_KIND=()    # created | replaced | link-created | link-replaced
CHG_OLD=()     # link-replaced: the old link target
REPORT=""      # the lines diff prints

# plan_changes fills CHG_* and REPORT.
plan_changes() {
  local rel dest
  for rel in "${MANAGED[@]}"; do
    dest=$ETC_DIR/$rel
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      CHG_REL+=("$rel"); CHG_KIND+=(created); CHG_OLD+=("")
      REPORT="$REPORT"$'missing  '"$rel"$'\n'
    elif cmp -s "$RENDER/$rel" "$dest"; then
      REPORT="$REPORT"$'identical  '"$rel"$'\n'
    else
      CHG_REL+=("$rel"); CHG_KIND+=(replaced); CHG_OLD+=("")
      REPORT="$REPORT"$'differs  '"$rel"$'\n'
      REPORT="$REPORT$(diff -u -L "installed/$rel" -L "rendered/$rel" "$dest" "$RENDER/$rel" 2>&1)"$'\n'
    fi
  done
  dest=$ETC_DIR/$LINK_REL
  if [ -L "$dest" ]; then
    local cur; cur=$(readlink "$dest")
    if [ "$cur" = "$LINK_TARGET" ]; then
      REPORT="$REPORT"$'identical  '"$LINK_REL"$' -> '"$cur"$'\n'
    else
      CHG_REL+=("$LINK_REL"); CHG_KIND+=(link-replaced); CHG_OLD+=("$cur")
      REPORT="$REPORT"$'differs  '"$LINK_REL"$' (points to '"$cur"$', want '"$LINK_TARGET"$')\n'
    fi
  elif [ -e "$dest" ]; then
    CHG_REL+=("$LINK_REL"); CHG_KIND+=(replaced); CHG_OLD+=("")
    REPORT="$REPORT"$'differs  '"$LINK_REL"$' (a regular file where the link belongs)\n'
  else
    CHG_REL+=("$LINK_REL"); CHG_KIND+=(link-created); CHG_OLD+=("")
    REPORT="$REPORT"$'missing  '"$LINK_REL"$'\n'
  fi
}

# ---- restoring from a backup (apply's failure path, and rollback) ---------------

# restore_backup BACKUP_DIR puts back what its MANIFEST says apply replaced or created.
restore_backup() {
  local bk=$1 kind rel rest bad=0
  while read -r kind rel rest; do
    case "$kind" in
      replaced)
        rm -f "$ETC_DIR/$rel" && cp -p "$bk/files/$rel" "$ETC_DIR/$rel" || { echo "$PROG: could not restore $rel" >&2; bad=1; } ;;
      created|link-created)
        rm -f "$ETC_DIR/$rel" || { echo "$PROG: could not remove $rel" >&2; bad=1; } ;;
      link-replaced)
        ln -sfn "$rest" "$ETC_DIR/$rel" || { echo "$PROG: could not restore the link $rel" >&2; bad=1; } ;;
    esac
  done < "$bk/MANIFEST"
  return $bad
}

# reload_nginx runs the reload; a failure is exit 69 and leaves the files in place.
reload_nginx() {
  if ! "$SYSTEMCTL_BIN" reload nginx > "$WORK/reload.out" 2>&1; then
    cat "$WORK/reload.out" >&2
    die $EX_UNAVAILABLE "systemctl reload nginx failed; the files are installed and nginx -t passes, and nginx keeps serving the previous configuration (fix the cause and reload, or run: $PROG rollback)"
  fi
  echo "nginx reloaded"
}

# ---- the verbs ---------------------------------------------------------------

verb_check() {
  render_all
  prepare_legacy
  build_stage
  run_gates
  echo "check: the staged configuration for $SERVER_NAME passed; nothing was changed on this host"
}

verb_diff() {
  render_all
  plan_changes
  detect_legacy
  local nleg=0
  if [ "$LEG_CONF" -eq 1 ]; then
    REPORT="$REPORT"$'legacy  nginx.conf (differs from the nginx-common package\'s; --migrate-legacy restores the package\'s)\n'
    nleg=$((nleg+1))
  fi
  printf '%s' "$REPORT"
  if [ ${#CHG_REL[@]} -eq 0 ] && [ "$nleg" -eq 0 ]; then
    echo "no drift: the installed files match the repository's"
    exit $EX_OK
  fi
  echo "drift: $(( ${#CHG_REL[@]} + nleg )) item(s) differ, are missing or are legacy ($nleg legacy)"
  exit $EX_NEGATIVE
}

verb_apply() {
  render_all
  prepare_legacy
  build_stage
  run_gates
  plan_changes
  if [ ${#CHG_REL[@]} -eq 0 ]; then
    echo "apply: no change; the installed files already match the repository's"
    return
  fi
  echo "apply: ${#CHG_REL[@]} item(s) to install for $SERVER_NAME:"
  local i
  for i in "${!CHG_REL[@]}"; do echo "  ${CHG_KIND[$i]}  ${CHG_REL[$i]}"; done
  if [ "$YES" -ne 1 ]; then
    local answer=""
    printf 'Install these? [y/N] '
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "apply: declined; nothing was changed"; exit $EX_NEGATIVE ;;
    esac
  fi

  # the backup: made first, and nothing is installed unless it exists
  local stamp bk n=1
  stamp=$(date -u +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_ROOT" 2>/dev/null || die $EX_CANTCREAT "could not make the backup directory $BACKUP_ROOT; nothing was changed"
  bk=$BACKUP_ROOT/$stamp
  until mkdir "$bk" 2>/dev/null; do
    [ -e "$bk" ] || die $EX_CANTCREAT "could not make the backup directory $bk; nothing was changed"
    n=$((n+1)); bk=$BACKUP_ROOT/$stamp-$n
  done
  mkdir -p "$bk/files" || die $EX_CANTCREAT "could not make $bk/files; nothing was changed"
  {
    echo "etc_dir=$ETC_DIR"
    echo "created_utc=$stamp"
    echo "script=$PROG $VERSION"
  } > "$bk/MANIFEST" || die $EX_CANTCREAT "could not write $bk/MANIFEST; nothing was changed"
  local rel kind
  for i in "${!CHG_REL[@]}"; do
    rel=${CHG_REL[$i]}; kind=${CHG_KIND[$i]}
    case "$kind" in
      replaced)
        mkdir -p "$(dirname "$bk/files/$rel")" && cp -p "$ETC_DIR/$rel" "$bk/files/$rel" || die $EX_CANTCREAT "could not back up $rel; nothing was changed"
        echo "replaced $rel" >> "$bk/MANIFEST" ;;
      created) echo "created $rel" >> "$bk/MANIFEST" ;;
      link-created) echo "link-created $rel" >> "$bk/MANIFEST" ;;
      link-replaced) echo "link-replaced $rel ${CHG_OLD[$i]}" >> "$bk/MANIFEST" ;;
    esac
  done

  fail_and_restore() { # fail_and_restore CODE MESSAGE...
    local code=$1; shift
    if restore_backup "$bk"; then
      die "$code" "$* The previous files were restored from backup $(basename "$bk")."
    fi
    die "$code" "$* Restoring from backup $bk was incomplete: see the messages above and run: $PROG rollback $(basename "$bk")"
  }

  for i in "${!CHG_REL[@]}"; do
    rel=${CHG_REL[$i]}; kind=${CHG_KIND[$i]}
    case "$kind" in
      replaced|created)
        install -d -m 0755 $OWNER "$(dirname "$ETC_DIR/$rel")" 2>/dev/null \
          && install -m 0644 $OWNER "$RENDER/$rel" "$ETC_DIR/$rel.nginx-deploy.new" 2>/dev/null \
          && mv -f "$ETC_DIR/$rel.nginx-deploy.new" "$ETC_DIR/$rel" 2>/dev/null \
          || { rm -f "$ETC_DIR/$rel.nginx-deploy.new"; fail_and_restore $EX_IOERR "could not install $rel."; } ;;
      link-created|link-replaced)
        install -d -m 0755 $OWNER "$(dirname "$ETC_DIR/$rel")" 2>/dev/null \
          && ln -sfn "$LINK_TARGET" "$ETC_DIR/$rel" 2>/dev/null \
          || fail_and_restore $EX_IOERR "could not link $rel." ;;
    esac
  done

  if ! "$NGINX_BIN" -t -c "$ETC_DIR/nginx.conf" > "$WORK/installed-t.out" 2>&1; then
    cat "$WORK/installed-t.out" >&2
    fail_and_restore $EX_DATA "nginx -t rejected the installed tree."
  fi
  echo "nginx -t on the installed tree: ok"
  [ "$RELOAD" -ne 1 ] || reload_nginx
  echo "apply: installed ${#CHG_REL[@]} item(s); backup $(basename "$bk") in $BACKUP_ROOT; undo with: $PROG rollback $(basename "$bk")"
}

verb_rollback() {
  [ -d "$BACKUP_ROOT" ] || die $EX_NOINPUT "no backups: $BACKUP_ROOT does not exist"
  local stamp=$STAMP_ARG bk
  if [ -z "$stamp" ]; then
    stamp=$(ls -1 "$BACKUP_ROOT" | sort | tail -1)
    [ -n "$stamp" ] || die $EX_NOINPUT "no backups under $BACKUP_ROOT"
  fi
  bk=$BACKUP_ROOT/$stamp
  [ -f "$bk/MANIFEST" ] || die $EX_NOINPUT "no backup named $stamp under $BACKUP_ROOT"
  local from
  from=$(sed -n 's/^etc_dir=//p' "$bk/MANIFEST" | head -1)
  [ "$from" = "$ETC_DIR" ] || usage_error "backup $stamp belongs to the nginx directory $from, not $ETC_DIR"
  restore_backup "$bk" || die $EX_IOERR "restoring backup $stamp was incomplete; see the messages above"
  echo "rollback: restored the files of backup $stamp"
  if ! "$NGINX_BIN" -t -c "$ETC_DIR/nginx.conf" > "$WORK/installed-t.out" 2>&1; then
    cat "$WORK/installed-t.out" >&2
    die $EX_DATA "the files of backup $stamp are restored, but nginx -t rejects the tree"
  fi
  echo "nginx -t on the restored tree: ok"
  [ "$RELOAD" -ne 1 ] || reload_nginx
}

case "$VERB" in
  check) verb_check ;;
  diff) verb_diff ;;
  apply) verb_apply ;;
  rollback) verb_rollback ;;
esac
exit $EX_OK
