"""Tests that Sentry is off unless INVENIO_SENTRY_DSN is set, as in CaltechAUTHORS.

invenio.cfg used to call sentry_sdk.init() unconditionally with production's DSN
written into the file, so every instance built from this repository (a Multipass
VM, a test instance) reported its errors into production's Sentry project.

The mechanism is now CaltechAUTHORS': the instance's .env sets INVENIO_SENTRY_DSN,
invenio-config turns it into the SENTRY_DSN setting, and invenio-logging starts
Sentry only when that setting is present. invenio.cfg holds no DSN and calls nothing
itself; it carries LOGGING_SENTRY_INIT_KWARGS, and it allows Sentry's hosts in the
Content-Security-Policy only when the variable is set.

Each case loads invenio.cfg in a fresh interpreter, because sentry_sdk.init() sets
process-global state. Only fake DSNs are used here.

Run from the repository root, inside the project's environment:

    uv run --no-sync python -m pytest tests/test_invenio_cfg_sentry.py

The wiring test starts the real application, so it needs the instance's services
and its .env exported; it is skipped otherwise.
"""

import json
import os
import re
import subprocess
import sys

import pytest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(REPO, "invenio.cfg")

VAR = "INVENIO_SENTRY_DSN"
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
    "defines_sentry_dsn": "SENTRY_DSN" in ns,
    "init_kwargs": ns.get("LOGGING_SENTRY_INIT_KWARGS"),
    "default_src": csp["default-src"],
    "script_src": csp["script-src"],
}))
"""

# Starts the real application and reports whether Sentry has a client, and its DSN.
APP = r"""
import json
from invenio_app.factory import create_app
app = create_app()
import sentry_sdk
client = sentry_sdk.Hub.current.client
print(json.dumps({"client": client is not None and client.dsn is not None,
                  "dsn": str(client.dsn) if client is not None and client.dsn is not None else None}))
"""


def run_python(code, **env):
    """run_python runs a snippet in a fresh interpreter and returns its last JSON line.

    @param code {str} the Python source to run, with the repository root as the working directory
    @param env {dict} environment variables to set; the value None removes the variable
    @returns {dict} the JSON object the snippet printed last
    @example
        result = run_python(LOADER, INVENIO_SENTRY_DSN=None)
        assert result["client"] is False
    """
    full = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith("SENTRY_") and not k.startswith("INVENIO_SENTRY_")
    }
    for key, value in env.items():
        if value is None:
            full.pop(key, None)
        else:
            full[key] = value
    run = subprocess.run(
        [sys.executable, "-c", code],
        cwd=REPO,
        env=full,
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert run.returncode == 0, run.stderr[-2000:]
    return json.loads(run.stdout.strip().splitlines()[-1])


def sentry_entries(hosts):
    return [h for h in hosts if "sentry" in h or "ingest" in h]


def test_the_config_file_starts_no_sentry_client_of_its_own():
    # invenio-logging does that, at application start, when SENTRY_DSN is set
    assert run_python(LOADER, **{VAR: None})["client"] is False
    assert run_python(LOADER, **{VAR: FAKE_DSN})["client"] is False


def test_the_config_file_defines_no_sentry_dsn_setting():
    # the instance's environment is the only source of it
    assert run_python(LOADER, **{VAR: None})["defines_sentry_dsn"] is False


def test_the_sampling_rate_production_used_is_kept():
    kwargs = run_python(LOADER, **{VAR: None})["init_kwargs"]
    assert kwargs["traces_sample_rate"] == 0.01


def test_the_committed_file_holds_no_dsn_and_no_production_sentry_host():
    with open(CFG) as f:
        text = f.read()
    assert not re.search(r"https://[0-9a-f]{16,}@", text), "a DSN is written into invenio.cfg"
    assert "ingest.us.sentry.io" not in text, "a production Sentry host is written into invenio.cfg"
    assert "sentry_sdk.init" not in text, "invenio.cfg starts Sentry itself"


@pytest.mark.parametrize("value", [None, "", "   "])
def test_without_a_dsn_the_csp_names_no_sentry_host(value):
    result = run_python(LOADER, **{VAR: value})
    assert sentry_entries(result["default_src"]) == []
    assert sentry_entries(result["script_src"]) == []


def test_with_a_dsn_the_csp_allows_the_hosts_sentry_needs():
    result = run_python(LOADER, **{VAR: FAKE_DSN})
    for directive in ("default_src", "script_src"):
        hosts = result[directive]
        assert FAKE_INGEST_HOST in hosts, directive
        assert "js.sentry-cdn.com" in hosts, directive
        assert "browser.sentry-cdn.com" in hosts, directive


def test_the_ingest_host_comes_from_the_dsn_not_from_the_file():
    other = run_python(LOADER, **{VAR: "https://k@o999.ingest.other.test/1"})
    assert "o999.ingest.other.test" in other["default_src"]
    assert FAKE_INGEST_HOST not in other["default_src"]


needs_instance = pytest.mark.skipif(
    not os.environ.get("INVENIO_SECRET_KEY"),
    reason="starts the real application: export the instance's .env first",
)


@needs_instance
def test_wiring_the_variable_reaches_sentry_when_the_application_starts():
    result = run_python(APP, **{VAR: FAKE_DSN})
    assert result["client"] is True
    assert result["dsn"] == FAKE_DSN


@needs_instance
def test_wiring_without_the_variable_the_application_starts_no_sentry():
    assert run_python(APP, **{VAR: None})["client"] is False
