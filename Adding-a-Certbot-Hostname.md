
Adding a new hostname with certbot
===================================

`nginx-sites-enabled-default`'s pattern for a real hostname puts everything
in **one** `server {}` block: the app's proxying/location config *and* the
certbot-managed `ssl_certificate`/`ssl_certificate_key` lines, all together,
keyed to that one `server_name`. That's deliberate, and it's easy to get
wrong when adding a hostname by hand.

**The gotcha:** certbot's nginx plugin only *finds* an existing `server {}`
block matching the `server_name` you give it and *appends* the
`listen 443 ssl` + cert directives to that same block -- it never copies in
any proxy/location config, and it never creates a new app-serving block for
you. If the block it finds is a bare redirect stub (e.g. something added
just so certbot has a `server_name` to attach to: `server_name
new.example.dev; return 301 https://$host$request_uri;`, with no
`location` blocks in it at all), the result after certbot runs is a
cert-bearing `server {}` block whose entire body is still just that
redirect -- to itself. Any HTTPS request for that hostname matches this
block (a specific `server_name` beats a generic `server_name _;`
catch-all every other hostname/IP request lands on) and 301s to the exact
URL it was already given: an infinite redirect loop, invisible in
`nginx -t` (it's syntactically valid) and easy to mistake for something
wrong with certbot itself.

**Before running certbot for a new hostname**, give it a block that already
has the same `location` blocks as the existing app-serving block --
`nginx-sites-enabled-default`'s `newdata.caltechlibrary.dev` block is the
reference to copy from, not a bare stub. Certbot will then append the cert
directives to a block that already knows how to serve the app, instead of
to an empty one.

If this happens after the fact (cert already issued, hostname already
looping): keep the certbot-managed `listen`/`ssl_certificate*` lines as-is
and add the missing `location` blocks (copied from the existing
app-serving block) into the same `server {}` -- don't touch the separate
port-80 redirect block certbot also created, that part is normal and
correct.

Hit live 2026-09-28 on CaltechAUTHORS' `caltechauthors-test-v13` after
adding `authors.caltechlibrary.dev` for certbot there -- fixed the same
way described above. Documented here too since caltechdata's own nginx
config follows the identical one-block-per-hostname pattern and would hit
the same gotcha.
