# Run with `pipenv run invenio shell change_owner.py`

from invenio_db import db
from invenio_accounts import current_accounts
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service, get_user_by_identifier
from invenio_utilities_tuw.cli.utils import set_record_owners

pids = ['a7f64-a8k10']
owners = [360]

u = get_identity_for_user(2)
service = get_record_service()

for pid in pids:
    record = service.read(id_=pid, identity=u)._record
    owners = [get_user_by_identifier(owner) for owner in owners]
    set_record_owners(record, owners)
    if service.indexer:
        service.indexer.index(record)

