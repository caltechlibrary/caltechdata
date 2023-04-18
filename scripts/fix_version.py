# Run with `pipenv run invenio shell fix_version.py`

from invenio_db import db
from invenio_accounts import current_accounts
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service


pids = ['brzrq-t3789']

u = get_identity_for_user(2)
service = get_record_service()

for pid in pids:
    version = service.new_version(id_=pid, identity=u)
    print(version._record)
