Adding a hostname with certbot
==============================

This page is for developers running a test instance, and for other institutions adapting this code. Certbot is
a convenience for them: it gets a Let's Encrypt certificate for a hostname so the instance can serve HTTPS.
`nginx-deploy.bash` only needs the certificate pair to exist; how it got there is up to the host (see
`nginx.md`). If your certificates come from somewhere else, put the pair where `--tls letsencrypt` expects it,
or ask for a new `--tls` value (the vocabulary is closed on purpose, as in caltechauthors DR-0009).

The one rule: **use `certbot certonly`, never `certbot --nginx`**, on a host `nginx-deploy.bash` manages. The
site file is a template the script renders, and the next deployment would remove or duplicate anything certbot
put into it. The reason is at the end of this page.

Steps
-----

1. **DNS.** Point an `A` record for the new name at the instance, and let it propagate. Let's Encrypt connects to
   the name on port 80.

2. **Get the certificate.** The site's port-80 server only redirects to HTTPS, and the application would not
   answer a challenge file, so use certbot's own web server and stop nginx around it:

   ```shell
   sudo certbot certonly --standalone -d new.example.dev \
     --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
   ```

   nginx is down for the few seconds this takes, which is fine on a test instance. The hooks are saved in the
   certificate's renewal configuration, so `certbot renew` does the same thing later and nginx starts again on
   the renewed certificate. (A DNS challenge avoids the downtime if your DNS has a certbot plugin.)
   `certbot --nginx`, and `certbot certonly --nginx`, edit the site file even if only for the challenge.

3. **Deploy with that certificate.** The certificate lineage is named after the first `-d` name unless you gave
   `--cert-name`:

   ```shell
   sudo ./nginx-deploy.bash check  --server-name new.example.dev --tls letsencrypt
   sudo ./nginx-deploy.bash apply  --server-name new.example.dev --tls letsencrypt --reload
   ```

   Add `--cert-name NAME` to both if the lineage has another name. `check` tests a staged copy first and changes
   nothing. A host serves one hostname from this layout, so this *replaces* the name the site answered to
   before; see "Changing the hostname" in `nginx.md`.

4. **Look.** `curl -sI http://new.example.dev/` should answer `301` to `https://new.example.dev/`, and
   `curl -sI https://new.example.dev/` should answer from the application, not redirect again.
   `sudo certbot certificates` shows the expiry and that renewal is configured.

This path with `--tls letsencrypt` has not been run on a real certificate in this repository's testing: the
nginx stage instance has no certificates, so only `--tls self-signed` was exercised (see `nginx.md`).

Why not `certbot --nginx`
-------------------------

The nginx plugin finds an existing `server {}` block that matches the name and **appends** the
`listen 443 ssl` and certificate lines to it. It never copies in any `location` blocks. If the block it finds is
a bare redirect stub (something added only so certbot has a `server_name` to attach to:
`server_name new.example.dev; return 301 https://$host$request_uri;`), the result is a certificate-bearing block
whose whole body is that redirect, to itself. Every HTTPS request for the name matches it, because a specific
`server_name` beats the `_` catch-all, and gets a `301` to the URL it already asked for: an infinite redirect
loop. `nginx -t` passes, since the file is valid, and it is easy to blame certbot.

This was hit live on 2026-09-28 on CaltechAUTHORS' `caltechauthors-test-v13`, after adding
`authors.caltechlibrary.dev`, and fixed by keeping the certbot-added `listen` and `ssl_certificate*` lines and
copying the missing `location` blocks from the app-serving block into the same `server {}`. This repository's
old `nginx-sites-enabled-default` had the same one-block-per-hostname shape and would have hit the same trap,
which is why this page used to describe how to avoid it by hand.

With `nginx-deploy.bash` the stub never exists: the site file is one `server` block with its `location`
blocks, and the certificate is a separate snippet the script includes. If you do not use the script and still
run `certbot --nginx`, give it a block that already has the `location` blocks to attach to, and leave the
separate port-80 redirect block it creates alone; that part is normal.
