"""Tests that invenio.cfg enables Sentry only when SENTRY_DSN is set.

invenio.cfg used to call sentry_sdk.init() unconditionally with production's DSN
written into the file, so every instance built from this repository (a Multipass
VM, a test instance) reported its errors into production's Sentry project. The DSN
now comes from the environment, and without it Sentry is off: no client, and none of
Sentry's hosts in the Content-Security-Policy.

Each case loads invenio.cfg in a fresh interpreter, because sentry_sdk.init() sets
process-global state. Only fake DSNs are used here.

Run from the repository root, inside the project's environment:

    uv run --no-sync python -m pytest tests/test_invenio_cfg_sentry.py
"""

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(REPO, "invenio.cfg")

FAKE_DSN = "https://publickey@o123456.ingest.example.test/7"
FAKE_INGEST_HOST = "o123456.ingest.example.test"

# Loads invenio.cfg the way Flask's from_pyfile does (exec into a namespace) and reports
# what matters, as JSON, on stdout.
LOADER = r"""
import json
ns = {"__name__": "invenio_cfg"}
with open("invenio.cfg") as f:
    exec(compile(f.read(), "invenio.cfg", "exec"), ns)
import sentry_sdk
client = sentry_sdk.Hub.current.client
csp = ns["APP_DEFAULT_SECURE_HEADERS"]["content_security_policy"]
print(json.dumps({
    "client": client is not None,
    "dsn": client.options["dsn"] if client is not None else None,
    "default_src": csp["default-src"],
    "script_src": csp["script-src"],
}))
"""


def load_cfg(**env):
    """load_cfg runs invenio.cfg in a fresh interpreter and returns what it reported.

    @param env {dict} environment variables to set; the value None removes the variable
    @returns {dict} client (bool), dsn, default_src and script_src
    @example
        result = load_cfg(SENTRY_DSN=None)
        assert result["client"] is False
    """
    full = {k: v for k, v in os.environ.items() if not k.startswith("SENTRY_")}
    for key, value in env.items():
        if value is None:
            full.pop(key, None)
        else:
            full[key] = value
    run = subprocess.run(
        [sys.executable, "-c", LOADER],
        cwd=REPO,
        env=full,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert run.returncode == 0, run.stderr[-2000:]
    return json.loads(run.stdout.strip().splitlines()[-1])


def sentry_entries(hosts):
    return [h for h in hosts if "sentry" in h or "ingest" in h]


def test_without_a_dsn_sentry_is_off():
    assert load_cfg(SENTRY_DSN=None)["client"] is False


def test_an_empty_dsn_is_the_same_as_none():
    assert load_cfg(SENTRY_DSN="")["client"] is False


def test_a_blank_dsn_is_the_same_as_none():
    assert load_cfg(SENTRY_DSN="   ")["client"] is False


def test_with_a_dsn_sentry_uses_exactly_that_dsn():
    result = load_cfg(SENTRY_DSN=FAKE_DSN)
    assert result["client"] is True
    assert result["dsn"] == FAKE_DSN


def test_without_a_dsn_the_csp_names_no_sentry_host():
    result = load_cfg(SENTRY_DSN=None)
    assert sentry_entries(result["default_src"]) == []
    assert sentry_entries(result["script_src"]) == []


def test_with_a_dsn_the_csp_allows_the_hosts_sentry_needs():
    result = load_cfg(SENTRY_DSN=FAKE_DSN)
    for directive in ("default_src", "script_src"):
        hosts = result[directive]
        assert FAKE_INGEST_HOST in hosts, directive
        assert "js.sentry-cdn.com" in hosts, directive
        assert "browser.sentry-cdn.com" in hosts, directive


def test_the_ingest_host_comes_from_the_dsn_not_from_the_file():
    other = load_cfg(SENTRY_DSN="https://k@o999.ingest.other.test/1")
    assert "o999.ingest.other.test" in other["default_src"]
    assert FAKE_INGEST_HOST not in other["default_src"]


def test_the_committed_file_holds_no_dsn_and_no_production_sentry_host():
    with open(CFG) as f:
        text = f.read()
    assert not re.search(r"https://[0-9a-f]{16,}@", text), "a DSN is written into invenio.cfg"
    assert "ingest.us.sentry.io" not in text, "a production Sentry host is written into invenio.cfg"
