# nginx on a CaltechDATA host

The nginx configuration for CaltechDATA lives in this repository's `nginx/` tree and is installed on a host by
`nginx-deploy.bash`. This page is for whoever has to deploy it, check it, change it, or put it back, and
assumes you were not there when it was written. The script and its tests are ported from CaltechAUTHORS
(caltechauthors DR-0009 and DR-0010); the port is described in the WorkLab workspace at
`agents/projects/caltechdata/plans/nginx_deploy_port.md`.

## What is in the repository

`nginx/` mirrors `/etc/nginx`:

| File | Installed as | What it is |
|---|---|---|
| `sites-available/caltechdata.conf` | `/etc/nginx/sites-available/<site-name>.conf`, linked from `sites-enabled/` | The site: ports 80 and 443, the proxy locations, the large-upload location, `/static`, the TIND-number redirects. A **template**: the script replaces `@SERVER_NAME@` and `@REPO_DIR@`. |
| `tls/letsencrypt.conf` or `tls/self-signed.conf` | `snippets/caltechdata-tls.conf` | The certificate pair, chosen by `--tls`. |
| `snippets/ssl-params.conf` | `snippets/ssl-params.conf` | The TLS protocols, ciphers and session settings, for every `--tls`. It carries no `add_header`: the application sends the security headers. |

There is no `conf.d/` today. CaltechAUTHORS has one (a log format, concurrency caps, an IIIF cache, a Cloudflare
address list) because of incidents there; none of that was carried over without evidence that CaltechDATA needs
it. If the script finds `nginx/conf.d/*.conf` it overlays them like the rest, so adding one later needs no
script change.

The TIND-number redirect map is `nginx/redirect-map.conf`. It is not installed under `/etc/nginx`; the site
file includes it from the checkout by absolute path (`@REPO_DIR@/nginx/redirect-map.conf`).

The script installs by **copy**, never by symlink, so editing the checkout is never a live change to a host.
It never edits the packaged `/etc/nginx/nginx.conf`, except that `--migrate-legacy` puts the package's own file
back over a hand-edited one.

## The verbs

All of them need `--server-name` and `--tls`; `nginx-deploy.bash --help` is the full manual.

```shell
sudo ./nginx-deploy.bash check  --server-name data.caltech.edu --tls letsencrypt
sudo ./nginx-deploy.bash diff   --server-name data.caltech.edu --tls letsencrypt
sudo ./nginx-deploy.bash apply  --server-name data.caltech.edu --tls letsencrypt --reload
sudo ./nginx-deploy.bash rollback --reload
```

- **check** renders the files, builds a *staged* copy of the host's `/etc/nginx` with them laid over it, and
  tests that copy with `nginx -t -c`, and with `logagent check` when `logagent` is installed. It changes
  nothing on the host.
- **diff** compares what is installed with what would be rendered. Exit 1 means drift.
- **apply** runs check, backs up what it will replace, copies, runs `nginx -t` on the installed tree, and
  **restores the backup if that fails**. It reloads nginx only with `--reload`, and asks first unless `--yes`.
- **rollback** puts back the latest backup (or the one named by its stamp), tests it, and reloads only with
  `--reload`. Backups are in `/var/backups/caltechdata-nginx`.

Use `--cert-name` when the Let's Encrypt lineage is not named after the server name, and `--site-name` to change
the file's name under `sites-available/` (default `caltechdata`). A new instance's `cloud-init` calls
`apply --yes --reload --site-name caltechdata --tls self-signed --server-name _`.

### Exit status

The script uses the workspace's exit codes. The ones that matter in practice: **1** drift (`diff`) or a declined
`apply`; **2** a bad command line; **65** the configuration was rejected (`nginx -t` failed or `logagent` found a
gap, before any change or after one that was then restored), a token was left unreplaced, the host has a
hand-edited `nginx.conf` and `--migrate-legacy` was not given, or the package's file does not match its
recorded checksum; **66** something the command needs is missing; **69** `--reload` could not reload nginx (the
files are installed and `nginx -t` passes, nginx keeps serving the old configuration), or `apt-get` could not
download the package for `--migrate-legacy` (nothing was changed); **74** a copy failed part way (the backup was
restored); **77** not root. `--help` lists all of them under EXIT STATUS.

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
**The `3600s` is a starting value.** It has not been tuned against Granian: a large-upload test through nginx and
Granian together is still to be done (plan phase 5).

## Certificates

The script needs only the certificate pair. With `--tls letsencrypt` it is
`/etc/letsencrypt/live/<cert-name>/fullchain.pem` and `privkey.pem`; with `--tls self-signed` (test instances) it
is the pair and `snippets/self-signed.conf` that `cloud-init` writes, and the script stops if that file is
missing. How the pair got there is up to the host.

`Adding-a-Certbot-Hostname.md` is the how-to. The one rule is `certbot certonly`, **never `certbot --nginx`**, on a
host this script manages: `certbot --nginx` inserts certificate lines into the site file, and the next deployment
would remove or duplicate them. Renewals replace the files under `/etc/letsencrypt/live/` and do not touch the
repository's files.

## A host that was configured by hand

A host set up before this layout (production, until it is migrated) may have an `/etc/nginx/nginx.conf` edited
away from the nginx-common package's. `check` and `apply` refuse such a host with exit 65 and change nothing.
Rerun with `--migrate-legacy`: it backs up `nginx.conf`, puts back the package's own (taken from the
nginx-common `.deb`, and accepted only if its checksum is the one `dpkg` recorded), and installs. `rollback`
undoes all of it. Do this in a quiet window, with `--reload`.

- **The package's file is fetched by version, then by archive.** The script first asks `apt-get` for the
  installed version of nginx-common. A host that has not taken the latest update may have a version the archive
  no longer carries, so it then tries the archive's current package. The checksum test is the same either way: the
  file must be the one `dpkg` recorded for the *installed* version, or nothing is changed (exit 65). If
  `apt-get` finds nothing at all, the package index is probably stale: run `apt-get update` and repeat
  (exit 69, nothing changed).
- **Without `dpkg` nothing can be recognised.** Where `dpkg-query` cannot say what the package's `nginx.conf` is,
  a hand edit cannot be seen, so `check` and `apply` treat the host as stock, and `--migrate-legacy` stops with
  exit 66 instead of reporting success.
- **Other sites are not touched.** The script manages only the files in the table above. An older hand-made site
  file still linked from `sites-enabled/` (including Ubuntu's `default`) keeps answering, and nginx will warn about
  a conflicting `server_name` or `listen` and pick one. **Take the old site out of `sites-enabled/` yourself, by
  moving the link, not deleting the file, before `apply`**, and run `diff` first to see what will change.
  Production's actual layout has not been surveyed (plan phase 0), so check it rather than assume.

`snippets/ssl-params.conf` is not legacy. It is an ordinary managed file, so `diff` shows how a host's copy
differs and `apply` replaces it, with a backup.

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
passes through untouched. To add an entry, add a line inside the `map { }` block, then `check`, `diff` and
`apply --reload`.

## What has been verified, and what has not

On 2026-10-28, in the Multipass VM `nginx-stage` (Ubuntu 24.04, nginx 1.24.0, a hand-edited `nginx.conf`):

- `check` refused the hand-edited host (65), and `check --migrate-legacy` passed `nginx -t` on the staged tree
  with the real redirect map.
- `diff`, then `apply --migrate-legacy --yes --reload`, installed five items and left the package's own
  `nginx.conf`; `rollback --reload` restored the host exactly.
- Through two stand-in upstreams on ports 5000 and 5001: `/records/204` redirected to `/records/qrrzg-tr757`,
  `/terms` to the library page, and an unlisted path was proxied; `/api/...` and the draft-file content path
  reached 5001 unmodified; `X-User-ID` and `X-Session-ID` did not reach the client while HSTS and `X-Request-ID`
  did; `.mjs` was `text/javascript` and `.css` `text/css`; port 80 redirected to https.
- A 150 MB body reached the upstream in full on the file-content location (and its `/content/3` form) and was
  refused with 413 on `/api`, on `/`, and on a similar-looking `/files/.../content` path.

Not verified: `--tls letsencrypt` on a real certificate; Granian behind nginx (the upstreams were stand-ins, on
loopback, so the `0.25 s` for 150 MB says nothing about real speed or the `3600s` timeouts); `logagent check`
(not installed on the stage VM); and production's current configuration.

## Where to look when it is wrong

- `sudo ./nginx-deploy.bash diff ...` says what differs from the repository.
- `sudo nginx -t` tests the installed tree. `/var/log/nginx/error.log` has the `413` and upstream errors.
- `sudo ./nginx-deploy.bash check ...` on a copy of the host's configuration is the way to try a change.
- The reasons for each choice are in the workspace's decision records: caltechdata DR-0001 and DR-0002, and
  caltechauthors DR-0009 and DR-0010 for the script.
