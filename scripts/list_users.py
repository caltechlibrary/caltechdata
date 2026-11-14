# SPDX-FileCopyrightText: 2026 California Institute of Technology.
# SPDX-License-Identifier: MIT

"""Print all user accounts and their email addresses as CSV.

Columns: ``id``, ``email``, ``username``, ``full_name``, ``active``. Rows are
ordered by user id. It only reads from the database. Run it with the
instance's Python (so ``invenio.cfg`` is picked up the same way ``invenio``
commands do)::

    uv run python list_users.py                   # all users
    uv run python list_users.py --active-only     # skip deactivated accounts
    uv run python list_users.py > users.csv

The output contains personal data (email addresses and names); don't leave
copies of it lying around.
"""

import argparse
import csv
import sys

from flask import current_app, has_app_context
from invenio_accounts.models import User

FIELDS = ["id", "email", "username", "full_name", "active"]


def list_users(active_only=False):
    """Yield one dict per user, ordered by id."""
    query = User.query.order_by(User.id)
    if active_only:
        query = query.filter(User.active.is_(True))
    for user in query.yield_per(500):
        profile = user.user_profile or {}
        yield {
            "id": user.id,
            "email": user.email,
            "username": user.username or "",
            "full_name": profile.get("full_name", ""),
            "active": user.active,
        }


def main(argv=None):
    """Command line entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--active-only",
        action="store_true",
        help="Only list active (not deactivated) accounts.",
    )
    args = parser.parse_args(argv)

    if has_app_context():  # e.g. run from ``invenio shell``
        app = current_app._get_current_object()
    else:
        from invenio_app.factory import create_app

        app = create_app()
    with app.app_context():
        writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
        writer.writeheader()
        for row in list_users(active_only=args.active_only):
            writer.writerow(row)


if __name__ == "__main__":
    main()
