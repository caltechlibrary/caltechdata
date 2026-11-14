# nginx on a CaltechDATA host

The nginx configuration for CaltechDATA lives in this repository's `nginx/` tree. `nginx-deploy.bash` **links** it
into `/etc/nginx` on a host (caltechdata DR-0007), so a `git pull` changes what nginx reads. This page is for
whoever has to deploy it, check it, change it, or put it back, and assumes you were not there when it was
written. The script and its tests are ported from CaltechAUTHORS (caltechauthors DR-0009 to DR-0011); the port is
described in the WorkLab workspace at `agents/projects/caltechdata/plans/nginx_deploy_port.md`.

## What is in the repository

`nginx/` mirrors `/etc/nginx`:

| File | Installed as | What it is |
|---|---|---|
| `sites-available/caltechdata.conf` | linked as `/etc/nginx/sites-available/<site-name>.conf`, which `sites-enabled/` links to | The site: ports 80 and 443, the proxy locations, the large-upload location, `/static`, the TIND-number redirects. It holds **no host-specific value**. |
| `redirect-map.conf` | linked as `snippets/caltechdata-redirect-map.conf` | The TIND-number redirect map, included by the site file. |
| *(written by the script)* | `snippets/caltechdata-host.conf` | Not a link. The host's `server_name` and the path of the static files (`set $caltechdata_static ...`), the one file that differs per host besides the next. |
| `tls/letsencrypt.conf` or `tls/self-signed.conf` | `snippets/caltechdata-tls.conf` | Not a link. The certificate pair, chosen by `--tls`. |
| `snippets/ssl-params.conf` | linked as `snippets/ssl-params.conf` | The TLS protocols, ciphers and session settings, for every `--tls`. It carries no `add_header`: the application sends the security headers. |
| `conf.d/caltechdata_log.conf` | linked into `conf.d/` | The extended access-log format `caltechdata_bots`: the stock combined fields plus request and upstream time, Cloudflare ray, country, bot score and TLS fingerprints, the connecting address, and language and client-hint headers. It only **defines** the format; each server block of the site sets `access_log ... caltechdata_bots;` itself. `logagent` reads this layout. |
| `conf.d/cloudflare_real_ip.conf` | linked into `conf.d/` | The published Cloudflare address ranges that nginx trusts to say who the client is (`real_ip_header CF-Connecting-IP`). Inert where no Cloudflare is in front. The same list as CaltechAUTHORS'; refresh it from Cloudflare's published list when that changes. |

`conf.d/` holds only the log format and the Cloudflare list. CaltechAUTHORS has more in its `conf.d/` (concurrency
caps, an IIIF cache) because of incidents there; none of that was carried over without evidence that CaltechDATA
needs it. The log format is production's, unchanged; it is CaltechAUTHORS' without the trailing
`cache="$upstream_cache_status"` field, because CaltechDATA has no such cache. If the script finds
`nginx/conf.d/*.conf` it links them like the rest, so adding another needs no script change.

Do not add an `access_log` to either file: at `http` level it would log every request a second time, in a
different layout.

The site file is included through `/etc/nginx`, never by a path into the checkout, so a file that moves in the
repository leaves a **dangling link** that `check` and `verify` report, instead of a configuration that will not
load. The script never edits the packaged `/etc/nginx/nginx.conf`.

## Upgrading a host

A `git pull` is a live change to a linked host: nginx reads the checkout's files at its next reload or restart,
including a restart nobody asked for (an unattended upgrade restarts every service). So **after any pull, and
before restarting anything**:

```shell
git pull
sudo ./nginx-deploy.bash verify
sudo systemctl restart nginx          # then the RDM services, as usual
```

`verify` needs no server name and no `--tls`. It is read-only: every link and host file must be in place and
point into this checkout, `nginx -t` must accept the **installed** tree (the one a restart loads), and the log
format and both servers' `access_log` must be in effect. It exits 65 and names what is wrong. If it fails because
of a link, run `apply` (it repairs links and is safe to run again), then `verify` again. `check` is the other
direction: it tests what `apply` *would* install, and needs `--server-name` and `--tls`.

`apply` also sets `core.hooksPath` to `.githooks` in the checkout, because git does not copy hooks. After that a
`post-merge` hook (and `post-rewrite`, for `git pull --rebase`) runs `verify` after each pull on a deployed host
and prints a banner if it fails or could not run. It only warns: git ignores a hook's exit status, and it does
not run on `git reset --hard` or `git checkout`, so the step above is still the guard. The hook needs passwordless
`sudo`; without it the banner says the check was not run, and gives the command. A clone that was never deployed
(a developer's laptop) prints nothing. The hook uses `verify`'s default site name; a host deployed with
`--site-name` needs to run `verify --site-name NAME` by hand. When a pull *moves or removes* a repository file,
`verify` cannot find its input and exits 66, so the banner is the weaker "could not be run, nginx is NOT checked"
one; treat it the same way: do not restart nginx until `apply` and `verify` are clean.

## The verbs

`check`, `diff` and `apply` need `--server-name` and `--tls`; `nginx-deploy.bash --help` is the full manual.

```shell
sudo ./nginx-deploy.bash check  --server-name data.caltechlibrary.dev --tls letsencrypt
sudo ./nginx-deploy.bash diff   --server-name data.caltechlibrary.dev --tls letsencrypt
sudo ./nginx-deploy.bash apply  --server-name data.caltechlibrary.dev --tls letsencrypt --reload
sudo ./nginx-deploy.bash verify
sudo ./nginx-deploy.bash rollback --reload
```

- **check** first fails (65) on a dangling link or one that does not point into this checkout. It then builds a
  *staged* copy of the host's `/etc/nginx` with copies of the repository's files and the host files laid over it,
  tests that copy with `nginx -t -c`, confirms that the `caltechdata_bots` log format exists and that both server
  blocks set an `access_log` in it, and runs `logagent check` when `logagent` is installed. It changes nothing on
  the host.
- **verify** is the read-only check of a host that is already deployed (see *Upgrading a host*).
- **diff** compares what is installed with what `apply` would install. Exit 1 means drift: a missing or wrong
  link, a regular file where a link belongs, or a host file that differs. A changed file behind a correct link is
  not drift; that is a pull.
- **apply** runs check, backs up what it will replace, makes the links and writes the host files, runs `nginx -t`
  on the installed tree, and **restores the backup if that fails**. It replaces a hand-made copy with a link (the
  copy is in the backup). It reloads nginx only with `--reload`, and asks first unless `--yes`.
- **rollback** puts back the latest backup (or the one named by its stamp, which `apply` prints), tests it, and
  reloads only with `--reload`. Backups are in `/var/backups/caltechdata-nginx`.

Use `--cert-name` when the Let's Encrypt lineage is not named after the server name, and `--site-name` to change
the file's name under `sites-available/` (default `caltechdata`). A new instance's `cloud-init` calls
`apply --yes --reload --site-name caltechdata --tls self-signed --server-name _`.

### Exit status

The script uses the workspace's exit codes. The ones that matter in practice: **1** drift (`diff`) or a declined
`apply`; **2** a bad command line; **65** the configuration was rejected (`nginx -t` failed or `logagent` found a
gap, before any change or after one that was then restored), a token was left in a linked file, a link is
missing, dangling or points outside the checkout, or **another enabled site answers for the same `server_name`**
(see below); **66** something the command needs is missing; **69** `--reload` could not reload nginx (the files
are installed and `nginx -t` passes, nginx keeps serving the old configuration); **74** a copy failed part way
(the backup was restored); **77** not root. `--help` lists all of them under EXIT STATUS.

## Reloading

`--reload` runs `systemctl reload nginx`, which only *signals* the master process and returns at once. The new
listening sockets can take a moment to open, so a check made in the same instant can still see the old ones.
After a reload, wait a second or two and try again before concluding anything is wrong.

## The pairs that must change together

- **`/api` and Granian's prefix.** `location /api` has no trailing slash on `proxy_pass`, so nginx forwards
  `/api/...` unmodified, and `rdm_rest.service` runs Granian with `--url-path-prefix /api`, which strips it and
  tells the REST app where it is mounted. Change one without the other and every `/api` request breaks, or
  every redirect the REST app builds loses its prefix (caltechauthors DR-0007).
- **Security headers.** The application sends them (Talisman, `APP_DEFAULT_SECURE_HEADERS` in `invenio.cfg`).
  nginx's `add_header` *appends*, so an `X-Frame-Options` here as well as the application's leaves two
  conflicting values, which browsers read as one invalid directive and refuse to frame (caltechauthors DR-0005).
  The site file sends only HSTS and `X-Request-ID`. A location-level `add_header` *replaces* every inherited one,
  so `/static` restates both.
- **The redirect map comes first in the site file.** `redirect-map.conf` sets `map_hash_max_size` and
  `map_hash_bucket_size`, and nginx rejects them if any `map` was parsed before them.

## Uploads

Deposits can be large, so the files location is the generous one:

| Location | Body limit | Notes |
|---|---|---|
| `/` and `/api` | `100m` | Everything that is not a file body. |
| `/api/records/<id>/draft/files/<key>/content` (optionally `/<part>`) | `500G` | `gzip off`; `proxy_read_timeout` and `proxy_send_timeout` are `3600s`. |

`proxy_request_buffering off` and `proxy_buffering off` apply to the whole server, so a body streams to the
application and nginx does not spool it to disk. uWSGI's `buffer-size` and 120 s socket timeouts were settings
of the uwsgi protocol and have no counterpart here; the limits above are where upload size and time are decided
(caltechdata DR-0001).

A body over the limit is refused with `413`, and `error.log` says `client intended to send too large body`.
**`client_body_timeout 3600s` is set on that location too.** The `proxy_*` timeouts cover the upstream. A gap in the
*client's* sending is `client_body_timeout`, which nginx defaults to 60 s, and a client that paused longer (a laptop
asleep, a link that dropped and resumed) was cut with a 408 and no response. Data files here can be very large, so this
location waits up to an hour; every other location keeps the default.

**The `3600s` values are still starting values.** Tested through nginx and Granian on a Multipass VM with local storage
(2026-10-29): four concurrent 1 GiB uploads, a 1 GiB upload that took 258 s, and a 200 MiB upload with a 90 s client pause
all completed with matching MD5s. Not tested: the `proxy_*` timeouts themselves (they act when Granian is slow to accept
data, as with a slow S3 write), the real `invenio-s3` path to OSN, and a single upload over an hour. The scripts are in the
WorkLab workspace, `agents/projects/caltechdata/notes/upload_tests/`.

## Certificates

The script needs only the certificate pair. With `--tls letsencrypt` it is
`/etc/letsencrypt/live/<cert-name>/fullchain.pem` and `privkey.pem`; with `--tls self-signed` (test instances) it
is the pair and `snippets/self-signed.conf` that `cloud-init` writes, and the script stops if that file is
missing. How the pair got there is up to the host.

`Adding-a-Certbot-Hostname.md` is the how-to. The one rule is `certbot certonly`, **never `certbot --nginx`**, on a
host this script manages: `certbot --nginx` inserts certificate lines into the site file, and the next deployment
would remove or duplicate them. Renewals replace the files under `/etc/letsencrypt/live/` and do not touch the
repository's files. A host whose renewal is configured for the nginx authenticator (`certbot --nginx`) could write
through a link into the checkout: reissue it with `certbot certonly --standalone` and stop and start hooks for nginx
(or a DNS challenge), and compare the checkout's `git status` after any renewal or dry run.

## A host that was set up before this layout

A host from before the link layout (this one, until 2026-11) has the same files as **regular copies**:
`conf.d/*` and `sites-available/caltechdata.conf`, with the host's paths written in. `diff` lists each as drift,
and `apply` replaces each with a link, keeping the copy in the backup, so `rollback` puts it back. Run `diff`
first and read it.

- **This script has no `--migrate-legacy`.** CaltechAUTHORS's does, for a hand-edited `nginx.conf`; that code was
  not carried over, because the replacement host does not need it (DR-0007). Production (`new-data`) was surveyed read-only
  on 2026-10-29: its live site is Ubuntu's `default`, edited in place, and its `nginx.conf` includes a hand-made
  log file. Moving production is a separate piece of work with its own decision record.
- **Other sites are not touched, but a clash is refused.** The script manages only the files in the table above.
  An older hand-made site still linked from `sites-enabled/` (including Ubuntu's `default`) stays where it is.
  `nginx -t` *passes* when two enabled sites claim one `server_name` on one port: it only warns `conflicting
  server name ... ignored` and serves whichever it read first. So `check` and `apply` stop (exit 65, nothing
  changed) when that warning appears in the staged test, quote it, and list what is in `sites-enabled/`. **Move
  the old site's link out of `sites-enabled/` yourself, the link and not the file**, then repeat the command.
  `data.caltechlibrary.dev` has an old `sites-available/data.caltechlibrary.dev-tom` that is not enabled, so it
  does not clash while it stays out of `sites-enabled/`.

`snippets/ssl-params.conf` is an ordinary managed file, so `diff` shows how a host's copy differs and `apply`
replaces it, with a backup.

## Changing the hostname

The site file is one `server` block, plus the redirect map and the `.mjs` type at http level. To put a host
under a different name, get its certificate pair in place (`Adding-a-Certbot-Hostname.md` for a Let's Encrypt
one), then run `apply` with the new `--server-name` and, if needed, `--cert-name`.

This layout does **not** serve two hostnames from two rendered site files on one host. Each file includes the
same `redirect-map.conf`, which sets `map_hash_*`, and CaltechAUTHORS found that nginx rejects the second include
as a duplicate (nginx 1.24.0). The same structure is here; it was not separately tested for CaltechDATA.

## The redirect map

`nginx/redirect-map.conf` holds about 20,000 entries of one shape, `/records/204` to `/records/qrrzg-tr757`:
the numeric record numbers CaltechDATA had when it was TIND, mapped to its RDM identifiers. It was last updated in
September 2022, and nothing in the repository says how often those old URLs are still requested. The site file
turns a match into a `301` with `if ($redirect_uri) { return 301 $redirect_uri; }` at server level, placed after
the locations. The map yields an empty string for any URI it does not list, which is falsy, so every current URL
passes through untouched. To add an entry, add a line inside the `map { }` block and commit it; on a host, pull, then
`verify`, and reload nginx (the link means no `apply` is needed for an edit to an existing file).

## What has been verified, and what has not

On 2026-11-06, in a Multipass VM (Ubuntu 24.04, nginx 1.24.0, the host's version), the link-based script (0.0.5) over a read-only
capture of `data.caltechlibrary.dev`'s `/etc/nginx`: `diff` found 6 items; `apply` made 4 `link-over-file`; `verify`,
`diff` and a second `apply` were then clean and changed nothing; `nginx -t` passed on the staged and installed trees;
a restart of nginx came back; and `/records/204` and `/terms` redirected through the linked map. Whether the same
holds on the real host is recorded in the plan's phase R8, not here.

Earlier, on 2026-10-28, in the Multipass VM `nginx-stage` (Ubuntu 24.04, nginx 1.24.0, a hand-edited `nginx.conf`),
with the copy-based script 0.0.4 (which still had `--migrate-legacy`):

- `check` refused the hand-edited host (65), and `check --migrate-legacy` passed `nginx -t` on the staged tree
  with the real redirect map.
- `diff`, then `apply --migrate-legacy --yes --reload`, installed five items and left the package's own
  `nginx.conf`; `rollback --reload` restored the host exactly.
- Through two stand-in upstreams on ports 5000 and 5001: `/records/204` redirected to `/records/qrrzg-tr757`,
  `/terms` to the library page, and an unlisted path was proxied; `/api/...` and the draft-file content path
  reached 5001 unmodified; `X-User-ID` and `X-Session-ID` did not reach the client while HSTS and `X-Request-ID`
  did; `.mjs` was `text/javascript` and `.css` `text/css`; port 80 redirected to https.
- With an old site on the same name enabled, real nginx printed `conflicting server name "_" ... ignored`, `check`
  refused (65), and after the link was moved out `check` passed.
- A 150 MB body reached the upstream in full on the file-content location (and its `/content/3` form) and was
  refused with 413 on `/api`, on `/`, and on a similar-looking `/files/.../content` path.

Not verified: `--tls letsencrypt` on a real certificate; Granian behind nginx (the upstreams were stand-ins, on
loopback, so the `0.25 s` for 150 MB says nothing about real speed or the `3600s` timeouts); `logagent check`
(not installed on the stage VM, and the tree's own format has not been run through it; production's identical format
passed on 2026-10-23); and production's current configuration beyond the survey.

## What a replacement host does differently from production

- **It sends HSTS.** Production's three `server_name` lines have no closing semicolon, so each swallowed the next
  directive, `add_header Strict-Transport-Security` among them. The template's lines are terminated, so a host
  built from this tree sends `Strict-Transport-Security: max-age=15768000`.
- **It logs in the extended format on both ports,** and `nginx.conf` stays the package's.

On the stage VM (nginx 1.24.0, script 0.0.4), `apply --migrate-legacy` installed the seven items, both server blocks logged in the
format with the Cloudflare headers carried through, and `rollback` restored `/etc/nginx` byte for byte.

## Where to look when it is wrong

- `sudo ./nginx-deploy.bash diff ...` says what differs from the repository.
- `sudo ./nginx-deploy.bash verify` says whether the installed tree is intact and loadable.
- `sudo nginx -t` tests the installed tree. `/var/log/nginx/error.log` has the `413` and upstream errors.
- `sudo ./nginx-deploy.bash check ...` on a copy of the host's configuration is the way to try a change.
- The reasons for each choice are in the workspace's decision records: caltechdata DR-0001 and DR-0002, and
  caltechdata DR-0007 (links, the check after a pull, the reboot scripts), and caltechauthors DR-0009 to DR-0011
  for the script.
