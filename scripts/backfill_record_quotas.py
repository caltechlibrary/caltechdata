# SPDX-FileCopyrightText: 2026 California Institute of Technology.
# SPDX-License-Identifier: MIT

"""Backfill per-record quota entries for records uploaded before quotas were tracked.

Records whose bucket quota was raised before per-record quotas existed (e.g.
directly on the bucket) have no ``RDMRecordQuota`` entry. They don't show up on
the owner's ``/account/settings/quota/`` page, don't count towards the owner's
additional quota allowance, and new drafts of them get a default-sized bucket.

For every record (parent) whose largest bucket quota across all published
versions and drafts exceeds the owner's default quota, this script creates an
``RDMRecordQuota`` entry. Existing entries without a ``user_id`` get the owner
assigned. Records owned by the system user or without an owner are skipped.

It only reads from the database by default. Run it from the instance's
environment (so ``invenio.cfg`` is picked up)::

    uv run invenio shell backfill_record_quotas.py           # dry run, reports changes
    uv run invenio shell backfill_record_quotas.py --apply   # writes the changes

Run the dry run first: every created entry counts against its owner's
``RDM_FILES_DEFAULT_MAX_ADDITIONAL_QUOTA_SIZE`` allowance.
"""

import argparse
import sys
from collections import defaultdict

from flask import current_app
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


def default_quota(user_id):
    """Default quota for a user (same lookup as the storage service)."""
    user_quota = RDMUserQuota.query.filter(
        RDMUserQuota.user_id == user_id
    ).one_or_none()
    return getattr(user_quota, "quota_size", None) or current_app.config.get(
        "RDM_FILES_DEFAULT_QUOTA_SIZE", 10 * GB
    )


def max_bucket_quotas():
    """Largest bucket quota (and max file size) per parent, across versions."""
    result = {}
    for model in (RDMRecordMetadata, RDMDraftMetadata):
        query = (
            db.session.query(
                model.parent_id,
                func.max(Bucket.quota_size),
                func.max(Bucket.max_file_size),
            )
            .join(Bucket, Bucket.id == model.bucket_id)
            .filter(model.parent_id.isnot(None), model.json.isnot(None))
            .group_by(model.parent_id)
        )
        if model is RDMRecordMetadata:
            query = query.filter(
                model.deletion_status == RecordDeletionStatusEnum.PUBLISHED
            )

        for parent_id, quota_size, max_file_size in query:
            if quota_size is None:
                continue
            prev_quota, prev_max_file = result.get(parent_id, (0, None))
            result[parent_id] = (
                max(prev_quota, quota_size),
                max(filter(None, (prev_max_file, max_file_size)), default=None),
            )
    return result


def parent_owner(parent_id):
    """Owner user id of a parent, or None for system-owned/unowned parents."""
    parent = db.session.get(RDMParentMetadata, parent_id)
    owned_by = ((parent.json or {}).get("access") or {}).get("owned_by") or {}
    owner_id = owned_by.get("user")
    if owner_id is None or str(owner_id) == str(system_user_id):
        return None
    return int(owner_id)


def backfill_record_quotas(dry_run=True):
    """Create missing ``RDMRecordQuota`` entries from existing bucket quotas.

    Doesn't commit; the caller decides.

    :returns: list of dicts describing the (planned) changes.
    """
    existing = {q.parent_id: q for q in RDMRecordQuota.query.all()}
    default_quotas = {}
    changes = []

    for parent_id, (quota_size, max_file_size) in max_bucket_quotas().items():
        record_quota = existing.get(parent_id)
        if record_quota is not None and record_quota.user_id is not None:
            continue

        owner_id = parent_owner(parent_id)
        if owner_id is None:
            continue

        if record_quota is not None:
            changes.append(
                {
                    "action": "set_owner",
                    "parent_id": str(parent_id),
                    "user_id": owner_id,
                    "quota_size": record_quota.quota_size,
                    "extra_quota": 0,
                }
            )
            if not dry_run:
                record_quota.user_id = owner_id
            continue

        if owner_id not in default_quotas:
            default_quotas[owner_id] = default_quota(owner_id)
        if quota_size <= default_quotas[owner_id]:
            continue

        changes.append(
            {
                "action": "create",
                "parent_id": str(parent_id),
                "user_id": owner_id,
                "quota_size": quota_size,
                "extra_quota": quota_size - default_quotas[owner_id],
            }
        )
        if not dry_run:
            db.session.add(
                RDMRecordQuota(
                    parent_id=parent_id,
                    user_id=owner_id,
                    quota_size=quota_size,
                    max_file_size=max_file_size or quota_size,
                    notes="Backfilled from existing bucket quota",
                )
            )

    return changes


def report(changes, out=sys.stdout):
    """Print each change and the additional quota per user."""
    per_user = defaultdict(int)
    for change in changes:
        print(
            f"{change['action']}: parent={change['parent_id']} "
            f"user={change['user_id']} quota_size={change['quota_size']}",
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
