# SPDX-FileCopyrightText: 2026 California Institute of Technology.
# SPDX-License-Identifier: MIT

"""Backfill per-record quota entries for records uploaded before quotas were tracked.

Records that use more storage than the default quota but were uploaded before
per-record quotas existed have no ``RDMRecordQuota`` entry. They don't show up
on the owner's ``/account/settings/quota/`` page, don't count towards the
owner's additional quota allowance, and new versions of them get a
default-sized bucket.

For every record (parent) whose largest version or draft uses more than the
owner's default quota, this script creates an ``RDMRecordQuota`` entry sized to
what is actually used, rounded up to the next GB (the same minimum the quota
increase form enforces). The bucket's own quota is ignored, since it is often
just an old, larger default.

Entries created by an earlier run of this script are resized the same way.
Existing entries without a ``user_id`` get the owner assigned. Records owned by
the system user or without an owner are skipped. Bucket quotas are not changed.

It only reads from the database by default. Run it with the instance's Python
(so ``invenio.cfg`` is picked up the same way ``invenio`` commands do)::

    uv run python backfill_record_quotas.py           # dry run, reports changes
    uv run python backfill_record_quotas.py --apply   # writes the changes

``invenio shell backfill_record_quotas.py`` works for the dry run, but IPython
swallows ``--apply``, so use ``python`` to write changes.

Run the dry run first: every created entry counts against its owner's
``RDM_FILES_DEFAULT_MAX_ADDITIONAL_QUOTA_SIZE`` allowance.
"""

import argparse
import sys
from collections import defaultdict
from math import ceil

from flask import current_app, has_app_context
from invenio_access.permissions import system_user_id
from invenio_db import db
from invenio_files_rest.models import Bucket
from sqlalchemy import func

from invenio_rdm_records.records.models import (
    RDMDraftMetadata,
    RDMParentMetadata,
    RDMRecordMetadata,
    RDMRecordQuota,
    RDMUserQuota,
)
from invenio_rdm_records.records.systemfields.deletion_status import (
    RecordDeletionStatusEnum,
)

GB = 10**9
BACKFILL_NOTE = "Backfilled from existing bucket quota"


def default_quota(user_id):
    """Default quota for a user (same lookup as the storage service)."""
    user_quota = RDMUserQuota.query.filter(
        RDMUserQuota.user_id == user_id
    ).one_or_none()
    return getattr(user_quota, "quota_size", None) or current_app.config.get(
        "RDM_FILES_DEFAULT_QUOTA_SIZE", 10 * GB
    )


def max_bucket_usage():
    """Largest bucket size per parent, across published versions and drafts."""
    result = defaultdict(int)
    for model in (RDMRecordMetadata, RDMDraftMetadata):
        query = (
            db.session.query(model.parent_id, func.max(Bucket.size))
            .join(Bucket, Bucket.id == model.bucket_id)
            .filter(model.parent_id.isnot(None), model.json.isnot(None))
            .group_by(model.parent_id)
        )
        if model is RDMRecordMetadata:
            query = query.filter(
                model.deletion_status == RecordDeletionStatusEnum.PUBLISHED
            )

        for parent_id, size in query:
            result[parent_id] = max(result[parent_id], int(size or 0))
    return result


def needed_quota(used_bytes, default):
    """Smallest quota covering ``used_bytes``, in whole GB above the default."""
    extra = max(used_bytes - default, 0)
    return default + ceil(extra / GB) * GB


def parent_owner(parent_id):
    """Owner user id of a parent, or None for system-owned/unowned parents."""
    parent = db.session.get(RDMParentMetadata, parent_id)
    owned_by = ((parent.json or {}).get("access") or {}).get("owned_by") or {}
    owner_id = owned_by.get("user")
    if owner_id is None or str(owner_id) == str(system_user_id):
        return None
    return int(owner_id)


def backfill_record_quotas(dry_run=True):
    """Create (or resize previously backfilled) ``RDMRecordQuota`` entries.

    Doesn't commit; the caller decides.

    :returns: list of dicts describing the (planned) changes.
    """
    existing = {q.parent_id: q for q in RDMRecordQuota.query.all()}
    default_quotas = {}
    changes = []

    for parent_id, used_bytes in max_bucket_usage().items():
        record_quota = existing.get(parent_id)
        backfilled = record_quota is not None and record_quota.notes == BACKFILL_NOTE
        if record_quota is not None and record_quota.user_id and not backfilled:
            continue  # set by an admin or a quota request; leave it alone

        owner_id = parent_owner(parent_id)
        if owner_id is None:
            continue

        if record_quota is not None and not backfilled:
            changes.append(
                {
                    "action": "set_owner",
                    "parent_id": str(parent_id),
                    "user_id": owner_id,
                    "used_bytes": used_bytes,
                    "quota_size": record_quota.quota_size,
                    "extra_quota": 0,
                }
            )
            if not dry_run:
                record_quota.user_id = owner_id
            continue

        if owner_id not in default_quotas:
            default_quotas[owner_id] = default_quota(owner_id)
        default = default_quotas[owner_id]
        quota_size = needed_quota(used_bytes, default)

        if record_quota is not None:  # created by an earlier run
            if record_quota.quota_size == quota_size:
                continue
            action = "resize"
        elif quota_size <= default:
            continue
        else:
            action = "create"

        changes.append(
            {
                "action": action,
                "parent_id": str(parent_id),
                "user_id": owner_id,
                "used_bytes": used_bytes,
                "quota_size": quota_size,
                "extra_quota": quota_size - default,
            }
        )
        if dry_run:
            continue
        if record_quota is None:
            record_quota = RDMRecordQuota(parent_id=parent_id, notes=BACKFILL_NOTE)
            db.session.add(record_quota)
        record_quota.user_id = owner_id
        record_quota.quota_size = quota_size
        record_quota.max_file_size = quota_size

    return changes


def report(changes, out=sys.stdout):
    """Print each change and the additional quota per user."""
    per_user = defaultdict(int)
    for change in changes:
        print(
            f"{change['action']}: parent={change['parent_id']} "
            f"user={change['user_id']} "
            f"used={change['used_bytes'] / GB:.1f} GB "
            f"quota={change['quota_size'] / GB:.1f} GB",
            file=out,
        )
        per_user[change["user_id"]] += change["extra_quota"]

    if per_user:
        max_additional = current_app.config.get(
            "RDM_FILES_DEFAULT_MAX_ADDITIONAL_QUOTA_SIZE", 0
        )
        print(file=out)
        for user_id, extra in sorted(per_user.items()):
            over = " (over allowance)" if extra > max_additional else ""
            print(f"user {user_id}: +{extra / GB:.1f} GB additional{over}", file=out)


def main(argv=None):
    """Command line entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the changes (default: dry run, only report them).",
    )
    args = parser.parse_args(argv)

    if has_app_context():  # e.g. run from ``invenio shell``
        app = current_app._get_current_object()
    else:
        from invenio_app.factory import create_app

        app = create_app()
    with app.app_context():
        changes = backfill_record_quotas(dry_run=not args.apply)
        report(changes)
        if args.apply:
            db.session.commit()
            print(f"\nApplied {len(changes)} change(s).")
        else:
            db.session.rollback()
            print(
                f"\nDry run: {len(changes)} change(s) not applied. "
                "Re-run with --apply to write them."
            )


if __name__ == "__main__":
    main()
