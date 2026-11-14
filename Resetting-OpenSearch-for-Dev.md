
Resetting OpenSearch for dev/test
==================================

`docker-services.yml`'s `search` service bind-mounts two host directories
(`/opt/rdm_opensearch_data_migrated`, `/opt/rdm_opensearch_backups`) instead
of using a Docker-managed volume. That's deliberate -- it's what lets
OpenSearch snapshots survive a container recreate -- but it also means
**`invenio-cli services destroy` does not actually clear OpenSearch data.**
Those host directories are untouched by `destroy`, so a following
`invenio-cli services setup` remounts the old data into the "fresh"
container instead of starting clean.

Symptom: repeated `invenio-cli services destroy` / `invenio-cli services
setup` cycles never actually reset OpenSearch -- stale documents, or
`services setup` failing partway through index/template creation.
`docker system prune -a` and reinstalling `.venv` don't help either, since
neither touches the bind-mounted host directories.

**If you only need to rebuild search indexes and don't need a fresh
Postgres database too**, use the `invenio index`/`invenio rdm` CLI directly
against the already-running instance instead of the full reset below (see
CaltechAUTHORS' `building_indexes.md` for the exact command sequence --
same Invenio RDM commands apply here). That path never recreates the
container, so it never hits this at all. Reach for the full reset only
when you actually need Postgres wiped too (e.g. testing fixture or
`invenio.cfg` changes that need a genuinely empty database).

Full reset, dev/test instances only -- **never run this against
production or an instance someone else has work in progress on**:

```bash
./reset-opensearch-dev-data.bash --yes-i-know
```

This destroys the backing service containers, clears
`/opt/rdm_opensearch_data_migrated` and `/opt/rdm_opensearch_backups`,
`chown`s both back to `1000:1000` (the uid/gid the `opensearchproject/opensearch`
image runs as), then runs `invenio-cli services setup` to recreate
everything. Confirm it actually started clean by checking that every real
index shares one new generation suffix, not a mix of old and new:

```bash
curl -s 'http://127.0.0.1:9200/_cat/indices/<prefix>-*?v&h=index,docs.count'
```
