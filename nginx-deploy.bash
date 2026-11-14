#!/bin/bash
#
# nginx-deploy.bash - link this repository's nginx configuration into a host's /etc/nginx.
#
# caltechdata DR-0007 (ported from caltechdata DR-0009 as amended by DR-0011; the plan is
# agents/projects/caltechdata/plans/nginx_deploy_port.md). Verbs: check, diff, apply, rollback, verify. The
# repository's nginx/ tree mirrors /etc/nginx and IS the configuration: apply links its files
# into /etc/nginx (a git pull is then a live change, so every pull is followed by `check`), and
# writes the two small files that differ per host. Everything is tested on a STAGED copy of
# the host's /etc/nginx first, what apply replaces is backed up, and rollback puts it back.
# The packaged /etc/nginx/nginx.conf is never edited.
#
# Written for bash 3.2 (macOS) and later.

set -u

VERSION=0.0.5
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
  nginx-deploy.bash - link the repository's nginx configuration into a host's /etc/nginx

SYNOPSIS
  nginx-deploy.bash check    [OPTIONS]
  nginx-deploy.bash diff     [OPTIONS]
  nginx-deploy.bash apply    [OPTIONS] [--reload] [--yes]
  nginx-deploy.bash rollback [--etc-dir DIR] [--backup-dir DIR] [--reload] [STAMP]
  nginx-deploy.bash verify   [--repo-dir DIR] [--etc-dir DIR] [--site-name NAME]
  nginx-deploy.bash --help | --version

DESCRIPTION
  The repository's nginx/ tree mirrors /etc/nginx and is the configuration. apply installs a
  symbolic link under /etc/nginx for each of its files (conf.d/*.conf, the site file, the
  ssl-params snippet and the redirect map, as snippets/caltechdata-redirect-map.conf), so
  a git pull changes what nginx reads. Two small files differ per host and are written, not
  linked: snippets/caltechdata-host.conf (server_name, and the static files' path) and
  snippets/caltechdata-tls.conf (the certificate pair). The packaged
  /etc/nginx/nginx.conf is never edited.

UPGRADING A HOST
  After ANY git pull in the checkout, before restarting nginx or the RDM services:

    git pull
    sudo ./nginx-deploy.bash verify
    sudo systemctl restart nginx    (and the RDM services)

  A pull that moves or removes a file makes a link dangle, and nginx would not start at its
  next restart (the 2026-11-05 outage). verify reports that without needing a server name or
  --tls; `apply` repairs it. apply also sets git's core.hooksPath to .githooks in the checkout,
  so a post-merge hook runs verify after each pull and warns if it fails. The hook only warns:
  git ignores a hook's exit status, and it does not run on `git reset --hard`.

VERBS
  check     fail (exit 65) on a dangling link or one that no longer points into this checkout;
            build a STAGED copy of the host's /etc/nginx with copies of the repository's files
            and the host files laid over it; test that copy with `nginx -t -c`, confirm the
            log_format and the access_log of both server blocks, and run `logagent check` if
            installed; changes nothing on the host
  diff      show the installed files against what apply would install; exit 1 when they differ
  apply     check, then back up what will be replaced, make the links and write the host files,
            run `nginx -t` on the installed tree, and restore the backup if that fails. Safe to
            run again: it repairs a moved checkout or a renamed file. Reloads nginx only with
            --reload. Asks first unless --yes is given.
  rollback  put a backup back (the latest, or the named STAMP), run `nginx -t`, and reload
            only with --reload
  verify    read-only check of a host that has been deployed; needs no --server-name or --tls, so
            the post-merge hook and verify_rdm_boot.bash can call it. Fails (65) if a link or host
            file is missing, dangling or not pointing into this checkout, if nginx -t rejects the
            INSTALLED tree (the one a restart loads), or if the logging is not in effect

OPTIONS
  --server-name NAME     the host's name, for server_name ("_" is a catch-all). Required for
                         check, diff and apply.
  --tls letsencrypt|self-signed
                         which certificate pair the site uses. Required for check, diff, apply.
  --cert-name NAME       the Let's Encrypt lineage under /etc/letsencrypt/live/
                         (default: the server name; used with --tls letsencrypt)
  --site-name NAME       the site file's name under sites-available/ (default: caltechdata)
  --repo-dir DIR         the checkout holding nginx/ (default: this script's directory); every
                         link points into it, and the static files are found under it
  --etc-dir DIR          the nginx configuration directory (default: /etc/nginx)
  --backup-dir DIR       where apply keeps its backups (default: /var/backups/caltechdata-nginx)
  --logagent-config FILE logagent's host configuration (default: /etc/logagent/logagent.yaml)
  --require-logagent     a missing logagent is an error, not a skipped step
  --no-logagent          do not run logagent check
  --reload               apply and rollback: reload nginx after a good test
  --yes                  apply: do not ask first (for installers)
  --keep-stage           keep the staged tree and print its path (for debugging)
  --help, --version

ENVIRONMENT
  NGINX      the nginx program (default: nginx)
  LOGAGENT   the logagent program (default: logagent)
  SYSTEMCTL  the systemctl program, used by --reload (default: systemctl)

EXIT STATUS
   0  success, or nothing to do (diff found no drift; --help and --version)
   1  the answer is no: diff found drift, or apply was declined at the prompt
   2  usage: unknown verb or option, a missing or surplus argument, a bad value
  65  the configuration was rejected: nginx -t failed, nginx -t reported a conflicting server name
      (another enabled site answers for the same name), or logagent found a gap (before any
      change, or after one that was then restored), a token is left in a linked file, or a link
      is missing, dangling or points outside the checkout
  66  a needed input is missing: nginx, systemctl with --reload, the repository's nginx/ tree,
      the etc directory, a snippet or dhparam.pem it requires, a backup, logagent with
      --require-logagent, or logagent's configuration file when logagent is run
  69  --reload: systemctl could not reload nginx (the files are installed and nginx -t
      passes; nginx keeps serving the previous configuration)
  70  an error nothing classified (a bug): the awk read of the nginx -T dump failed, or logagent
      check exited with a status this script does not know
  73  the backup directory could not be made (nothing was changed)
  74  a copy or write failed: in apply part way (the backup was restored), or while rendering or
      staging, before any change to the host
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
    --keep-stage) KEEP=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
    -*) usage_error "unknown option: $arg" ;;
    *) POS+=("$arg"); shift ;;
  esac
done

[ ${#POS[@]} -gt 0 ] || usage_error "no verb given (the verbs are: check, diff, apply, rollback, verify)"
VERB=${POS[0]}
case "$VERB" in
  check|diff|apply|rollback|verify) ;;
  *) usage_error "unknown verb: $VERB (the verbs are: check, diff, apply, rollback, verify)" ;;
esac
STAMP_ARG=""
if [ "$VERB" = rollback ]; then
  [ ${#POS[@]} -le 2 ] || usage_error "surplus argument: ${POS[2]}"
  [ ${#POS[@]} -lt 2 ] || STAMP_ARG=${POS[1]}
else
  [ ${#POS[@]} -le 1 ] || usage_error "surplus argument: ${POS[1]}"
fi
case "$VERB" in
  check|diff|verify) [ "$RELOAD" -eq 0 ] || usage_error "--reload only applies to apply and rollback" ;;
esac
[ "$VERB" = apply ] || [ "$YES" -eq 0 ] || usage_error "--yes only applies to apply"

# ---- validating the values ---------------------------------------------------

name_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }
abs_path_ok() { printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/-]+$'; }

ETC_DIR=${ETC_DIR%/}
[ -n "$ETC_DIR" ] || usage_error "--etc-dir must not be /"
BACKUP_ROOT=${BACKUP_ROOT%/}
abs_path_ok "$BACKUP_ROOT" || usage_error "--backup-dir '$BACKUP_ROOT' must be an absolute path of letters, digits, . _ - and /"

if [ "$VERB" != rollback ]; then
  if [ "$VERB" != verify ]; then
    [ -n "$SERVER_NAME" ] || usage_error "--server-name is required"
    name_ok "$SERVER_NAME" || usage_error "--server-name '$SERVER_NAME' may only contain letters, digits, . _ and -"
    [ -n "$TLS" ] || usage_error "--tls is required (letsencrypt or self-signed)"
    case "$TLS" in
      letsencrypt|self-signed) ;;
      *) usage_error "--tls '$TLS' is not one of: letsencrypt, self-signed" ;;
    esac
    [ -n "$CERT_NAME" ] || CERT_NAME=$SERVER_NAME
    name_ok "$CERT_NAME" || usage_error "--cert-name '$CERT_NAME' may only contain letters, digits, . _ and -"
  fi
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
  [ -d "$SRC/conf.d" ] || die $EX_NOINPUT "missing: $SRC/conf.d"
  [ -f "$SRC/sites-available/caltechdata.conf" ] || die $EX_NOINPUT "missing: $SRC/sites-available/caltechdata.conf"
  [ "$VERB" = verify ] || [ -f "$SRC/tls/$TLS.conf" ] || die $EX_NOINPUT "missing: $SRC/tls/$TLS.conf"
  [ -f "$SRC/snippets/ssl-params.conf" ] || die $EX_NOINPUT "missing: $SRC/snippets/ssl-params.conf"
  [ -f "$SRC/redirect-map.conf" ] || die $EX_NOINPUT "missing: $SRC/redirect-map.conf (linked as snippets/caltechdata-redirect-map.conf)"
fi

if [ "$VERB" = check ] || [ "$VERB" = apply ] || [ "$VERB" = verify ]; then
  [ -f "$ETC_DIR/nginx.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/nginx.conf"
fi
if [ "$VERB" = check ] || [ "$VERB" = apply ]; then
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

# render_file SOURCE DEST replaces the closed set of tokens and fails if a token is left.
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
MANAGED=()      # the files this script WRITES (the two host files), relative to the etc directory
LNK_REL=()      # the links into the checkout, relative to the etc directory
LNK_TGT=()      # and the file in the checkout each one must point to
LINK_REL=""     # the sites-enabled link: it points at sites-available, not at the checkout
LINK_TARGET=""

# add_link REL TARGET records a link from the etc directory into the checkout.
add_link() { LNK_REL+=("$1"); LNK_TGT+=("$2"); }

# check_repo_tokens fails (65) if a file that will be LINKED holds an @TOKEN@: a linked file cannot be
# rendered, so the token would reach nginx as it is (DR-0011: host values live in the generated host files).
check_repo_tokens() {
  local f left
  for f in "${LNK_TGT[@]}"; do
    left=$(grep -n -o '@[A-Z][A-Z_]*@' "$f" | head -3 | tr '\n' ' ')
    [ -z "$left" ] || die $EX_DATA "a token is left in $f: $left (a linked file cannot be rendered; host values belong in the generated host files)"
  done
}

# list_links lists the links (conf.d, the site file, ssl-params, the redirect map) that apply makes.
list_links() {
  local f
  for f in "$SRC"/conf.d/*.conf; do
    [ -f "$f" ] || continue
    add_link "conf.d/$(basename "$f")" "$f"
  done
  add_link "sites-available/$SITE_NAME.conf" "$SRC/sites-available/caltechdata.conf"
  add_link "snippets/ssl-params.conf" "$SRC/snippets/ssl-params.conf"
  add_link "snippets/caltechdata-redirect-map.conf" "$SRC/redirect-map.conf"
  check_repo_tokens
}

# render_all lists the links and renders the two files that differ per host into $RENDER, in the layout of
# the etc directory.
render_all() {
  mkdir -p "$RENDER/snippets" || die $EX_IOERR "could not make $RENDER"
  list_links
  {
    echo "# Written by nginx-deploy.bash (caltechdata DR-0011). Not a link: this is one of the two files that differ per host."
    echo "# Run nginx-deploy.bash apply to change it; do not edit it by hand."
    echo "server_name $SERVER_NAME;"
    echo "set \$caltechdata_static $REPO_DIR/.venv/var/instance/static;"
  } > "$RENDER/snippets/caltechdata-host.conf" || die $EX_IOERR "could not write the host file"
  MANAGED+=("snippets/caltechdata-host.conf")
  render_file "$SRC/tls/$TLS.conf" "$RENDER/snippets/caltechdata-tls.conf"
  MANAGED+=("snippets/caltechdata-tls.conf")
  LINK_REL="sites-enabled/$SITE_NAME.conf"
  LINK_TARGET="$ETC_DIR/sites-available/$SITE_NAME.conf"
}

# verify_links is the check's answer to a pull that moved or removed a file (2026-11-05): every link of
# ours that is already installed must resolve and point into this checkout. It lists all of them, then
# fails (65). check calls it as it is: a link that is not installed yet, or a regular file where a link
# belongs, is not an error there (apply makes or replaces it). verify calls it "strict": a host that is
# supposed to be deployed must have every link, and the host files and the sites-enabled link too.
verify_links() {
  local i rel tgt dest cur msg="" strict=${1:-}
  for i in "${!LNK_REL[@]}"; do
    rel=${LNK_REL[$i]}; tgt=${LNK_TGT[$i]}; dest=$ETC_DIR/$rel
    if [ ! -L "$dest" ]; then
      if [ "$strict" = strict ]; then
        if [ -e "$dest" ]; then msg="$msg  not a link: $rel (a regular file where the link belongs; apply replaces it)"$'\n'
        else msg="$msg  missing: $rel (apply makes it)"$'\n'; fi
      fi
      continue
    fi
    cur=$(readlink "$dest")
    if [ ! -e "$dest" ]; then
      msg="$msg  dangling: $rel -> $cur (nothing is there; this checkout wants $tgt)"$'\n'
    elif [ "$cur" != "$tgt" ]; then
      case "$cur" in
        "$REPO_DIR"/*) msg="$msg  stale: $rel -> $cur (this checkout wants $tgt)"$'\n' ;;
        *) msg="$msg  outside the checkout: $rel -> $cur (this checkout wants $tgt)"$'\n' ;;
      esac
    fi
  done
  if [ "$strict" = strict ]; then
    for rel in snippets/caltechdata-host.conf snippets/caltechdata-tls.conf; do
      [ -f "$ETC_DIR/$rel" ] || msg="$msg  missing: $rel (apply writes it)"$'\n'
    done
    dest=$ETC_DIR/sites-enabled/$SITE_NAME.conf
    if [ ! -L "$dest" ]; then msg="$msg  missing: sites-enabled/$SITE_NAME.conf (apply makes it)"$'\n'
    elif [ ! -e "$dest" ]; then msg="$msg  dangling: sites-enabled/$SITE_NAME.conf -> $(readlink "$dest")"$'\n'; fi
  fi
  [ -z "$msg" ] || { printf '%s' "$msg" >&2; die $EX_DATA "$ETC_DIR is not a good deployment of this checkout: a link is missing, dangling or does not point into the checkout; nothing was changed (apply repairs it)"; }
}

# ---- the post-merge hook (git does not copy hooks, so the checkout is pointed at .githooks) ------

# hooks_path prints the checkout's core.hooksPath, or nothing; it prints "n/a" when the checkout is not a git
# repository with a .githooks directory, which is nothing this script manages. (safe.directory: the script
# runs as root over a checkout owned by another user.)
hooks_path() {
  { [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; } && [ -d "$REPO_DIR/.githooks" ] || { echo "n/a"; return; }
  command -v git >/dev/null 2>&1 || { echo "n/a"; return; }
  git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" config --get core.hooksPath 2>/dev/null
  return 0
}

# set_hooks_path makes core.hooksPath .githooks if it is unset, and says so if it is set to something else.
# Written as root it would leave .git/config owned by root, so the owner of .git is restored.
set_hooks_path() {
  local cur; cur=$(hooks_path)
  case "$cur" in
    "n/a"|.githooks) return 0 ;;
    "") ;;
    *) echo "note: core.hooksPath in $REPO_DIR is '$cur', not .githooks, so the post-merge nginx check is not enabled"; return 0 ;;
  esac
  if git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null; then
    [ "$(id -u)" != 0 ] || [ ! -d "$REPO_DIR/.git" ] || chown --reference="$REPO_DIR/.git" "$REPO_DIR/.git/config" 2>/dev/null || true
    echo "hooks: core.hooksPath is now .githooks in $REPO_DIR (the post-merge hook runs nginx-deploy.bash verify after a pull)"
  else
    echo "note: could not set core.hooksPath in $REPO_DIR; run: git -C $REPO_DIR config core.hooksPath .githooks"
  fi
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
  local l rel i
  find "$ETC_DIR" -type l | while read -r l; do
    [ -e "$l" ] && continue
    rel=${l#"$ETC_DIR"/}
    mkdir -p "$(dirname "$STAGE/$rel")" && ln -sfn "$(readlink "$l")" "$STAGE/$rel"
  done
  mkdir -p "$STAGE/conf.d" "$STAGE/sites-available" "$STAGE/sites-enabled" "$STAGE/snippets"
  for rel in "${MANAGED[@]}"; do
    cp "$RENDER/$rel" "$STAGE/$rel" || die $EX_IOERR "could not stage $rel"
  done
  # the stage holds COPIES of what the links point to, never links into the checkout, so a test can not touch it
  for i in "${!LNK_REL[@]}"; do
    rel=${LNK_REL[$i]}
    mkdir -p "$(dirname "$STAGE/$rel")" && rm -f "$STAGE/$rel" && cp "${LNK_TGT[$i]}" "$STAGE/$rel" || die $EX_IOERR "could not stage $rel"
  done
  ln -sfn "$STAGE/sites-available/$SITE_NAME.conf" "$STAGE/$LINK_REL" || die $EX_IOERR "could not link the site into the stage"
  # Point the staged copy at itself, so even a test cannot change the host.
  rewrite_in_tree "$STAGE" "$ETC_DIR/" "$STAGE/"
  if [ "$KEEP" -eq 1 ]; then echo "stage: $STAGE" >&2; fi
}

# check_logging confirms the logging changes are in the staged configuration (DR-0009 decision 3): the
# log_format exists, and every server block of this site (the ones that include the host file) sets an
# access_log in that format, or redirect traffic writes combined-format lines into the extended log.
check_logging() {
  local what=${1:-staged}
  grep -Eq '^[[:space:]]*log_format[[:space:]]+caltechdata_bots([[:space:]]|$)' "$DUMP" \
    || die $EX_DATA "the $what configuration defines no log_format caltechdata_bots (conf.d/caltechdata_log.conf); nothing was changed on this host"
  local bad rc
  bad=$(awk '
    { line=$0; sub(/^[ \t]*#.*/,"",line); sub(/[ \t]#.*$/,"",line) }
    !insrv && line ~ /^[ \t]*server[ \t]*\{/ { insrv=1; sd=depth; ours=0; seen=0; first=NR }
    insrv {
      if (line ~ /caltechdata-host\.conf/) ours=1
      if (line ~ /access_log[ \t]+[^;]*caltechdata_bots/) seen=1
    }
    { o=gsub(/\{/,"{",line); c=gsub(/\}/,"}",line); depth += o - c }
    insrv && depth <= sd { if (ours && !seen) print first; insrv=0 }
  ' "$DUMP" 2> "$WORK/awk.err")
  rc=$?
  [ "$rc" -eq 0 ] || { cat "$WORK/awk.err" >&2; die $EX_INTERNAL "could not read the nginx -T dump for the access_log check (awk exited $rc)"; }
  bad=$(printf '%s' "$bad" | tr '\n' ' ')
  [ -z "$bad" ] || die $EX_DATA "a server block of this site sets no access_log with the caltechdata_bots format (dump line $bad of the $what configuration): both server blocks, ports 80 and 443, must; nothing was changed on this host"
  echo "logging: log_format caltechdata_bots and an access_log in every server block of the site: ok"
}

run_gates() {
  if ! "$NGINX_BIN" -t -c "$STAGE/nginx.conf" > "$WORK/nginx-t.out" 2>&1; then
    cat "$WORK/nginx-t.out" >&2
    die $EX_DATA "nginx -t rejected the staged configuration; nothing was changed on this host"
  fi
  echo "nginx -t on the staged tree: ok"
  # nginx -t PASSES when two enabled sites claim one server_name on one port: it warns "conflicting server
  # name ... ignored" and serves whichever it read first. An older hand-made site still linked from
  # sites-enabled would then keep answering while this script reported success. Only this warning is a
  # refusal; nginx -t prints others on healthy hosts.
  if grep -q 'conflicting server name' "$WORK/nginx-t.out"; then
    {
      echo "$PROG: another enabled site answers for the same server name, and nginx would ignore one of the two:"
      grep 'conflicting server name' "$WORK/nginx-t.out" | sed 's/^/  /'
      echo "Enabled in $ETC_DIR/sites-enabled:"
      ls -1 "$ETC_DIR/sites-enabled" 2>/dev/null | sed 's/^/  /'
      echo "Move the old site's link out of $ETC_DIR/sites-enabled (move the link, do not delete the file) and repeat the"
      echo "command. Nothing was changed."
    } >&2
    exit $EX_DATA
  fi

  if ! "$NGINX_BIN" -T -c "$STAGE/nginx.conf" > "$DUMP" 2> "$WORK/nginx-T.err"; then
    cat "$WORK/nginx-T.err" >&2
    die $EX_DATA "nginx -T could not dump the staged configuration"
  fi
  check_logging

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
CHG_KIND=()    # created | replaced | link-created | link-replaced | link-over-file
CHG_OLD=()     # link-replaced: the old link target
CHG_TGT=()     # the link kinds: what the link must point to
REPORT=""      # the lines diff prints

# plan_link REL WANT plans one link: what is installed against where it must point.
plan_link() {
  local rel=$1 want=$2 dest=$ETC_DIR/$1 cur
  if [ -L "$dest" ]; then
    cur=$(readlink "$dest")
    if [ "$cur" = "$want" ] && [ -e "$dest" ]; then
      REPORT="$REPORT"$'identical  '"$rel"$' -> '"$cur"$'\n'
    else
      CHG_REL+=("$rel"); CHG_KIND+=(link-replaced); CHG_OLD+=("$cur"); CHG_TGT+=("$want")
      if [ -e "$dest" ]; then
        REPORT="$REPORT"$'differs  '"$rel"$' (points to '"$cur"$', want '"$want"$')\n'
      else
        REPORT="$REPORT"$'differs  '"$rel"$' (dangling: points to '"$cur"$', where nothing is; want '"$want"$')\n'
      fi
    fi
  elif [ -e "$dest" ]; then
    CHG_REL+=("$rel"); CHG_KIND+=(link-over-file); CHG_OLD+=(""); CHG_TGT+=("$want")
    REPORT="$REPORT"$'differs  '"$rel"$' (a regular file where the link belongs)\n'
    if [ -f "$want" ]; then REPORT="$REPORT$(diff -u -L "installed/$rel" -L "repository/$rel" "$dest" "$want" 2>&1)"$'\n'; fi
  else
    CHG_REL+=("$rel"); CHG_KIND+=(link-created); CHG_OLD+=(""); CHG_TGT+=("$want")
    REPORT="$REPORT"$'missing  '"$rel"$'\n'
  fi
}

# plan_changes fills CHG_* and REPORT.
plan_changes() {
  local rel dest i
  for rel in "${MANAGED[@]}"; do
    dest=$ETC_DIR/$rel
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      CHG_REL+=("$rel"); CHG_KIND+=(created); CHG_OLD+=(""); CHG_TGT+=("")
      REPORT="$REPORT"$'missing  '"$rel"$'\n'
    elif cmp -s "$RENDER/$rel" "$dest"; then
      REPORT="$REPORT"$'identical  '"$rel"$'\n'
    else
      CHG_REL+=("$rel"); CHG_KIND+=(replaced); CHG_OLD+=(""); CHG_TGT+=("")
      REPORT="$REPORT"$'differs  '"$rel"$'\n'
      REPORT="$REPORT$(diff -u -L "installed/$rel" -L "rendered/$rel" "$dest" "$RENDER/$rel" 2>&1)"$'\n'
    fi
  done
  for i in "${!LNK_REL[@]}"; do plan_link "${LNK_REL[$i]}" "${LNK_TGT[$i]}"; done
  plan_link "$LINK_REL" "$LINK_TARGET"
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
  verify_links
  build_stage
  run_gates
  echo "check: the staged configuration for $SERVER_NAME passed; nothing was changed on this host"
}

# verify is the read-only check of a host that has been deployed. It needs no server name and no --tls, so
# the post-pull hook and verify_rdm_boot.bash can call it: every link and host file is in place and points into
# this checkout, nginx accepts the INSTALLED tree (the one a restart will load), and the logging changes are in it.
verb_verify() {
  list_links
  verify_links strict
  if ! "$NGINX_BIN" -t -c "$ETC_DIR/nginx.conf" > "$WORK/installed-t.out" 2>&1; then
    cat "$WORK/installed-t.out" >&2
    die $EX_DATA "nginx -t rejects the installed tree under $ETC_DIR; a restart of nginx would fail"
  fi
  echo "nginx -t on the installed tree: ok"
  if ! "$NGINX_BIN" -T -c "$ETC_DIR/nginx.conf" > "$DUMP" 2> "$WORK/nginx-T.err"; then
    cat "$WORK/nginx-T.err" >&2
    die $EX_DATA "nginx -T could not dump the installed configuration"
  fi
  check_logging installed
  echo "verify: $ETC_DIR is a good deployment of $REPO_DIR; nothing was changed on this host"
  case "$(hooks_path)" in
    "n/a"|.githooks) ;;
    *) echo "note: git core.hooksPath in $REPO_DIR is not .githooks, so no nginx check runs after a pull; run: git -C $REPO_DIR config core.hooksPath .githooks" >&2 ;;
  esac
}

verb_diff() {
  render_all
  plan_changes
  printf '%s' "$REPORT"
  if [ ${#CHG_REL[@]} -eq 0 ]; then
    echo "no drift: the installed files match the repository's"
    exit $EX_OK
  fi
  echo "drift: ${#CHG_REL[@]} item(s) differ or are missing"
  exit $EX_NEGATIVE
}

verb_apply() {
  render_all
  build_stage
  run_gates
  plan_changes
  if [ ${#CHG_REL[@]} -eq 0 ]; then
    echo "apply: no change; the installed files already match the repository's"
    set_hooks_path
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
      replaced|link-over-file)
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
      link-created|link-replaced|link-over-file)
        install -d -m 0755 $OWNER "$(dirname "$ETC_DIR/$rel")" 2>/dev/null \
          && ln -sfn "${CHG_TGT[$i]}" "$ETC_DIR/$rel" 2>/dev/null \
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
  set_hooks_path
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
  verify) verb_verify ;;
esac
exit $EX_OK
