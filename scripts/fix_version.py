# Run with `pipenv run invenio shell fix_version.py`

from invenio_db import db
from invenio_accounts import current_accounts
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service


pids = ['ct5kt-cv878']

u = get_identity_for_user(2)
service = get_record_service()

for pid in pids:
    record = service.record_cls.pid.resolve(pid)
    print(record.versions)
    record.versions.clear_next()
    record.commit()
    db.session.commit()
    service.indexer.index(record)
    print(record.versions)
    #print(service.read_draft(id_=pid, identity=u)._record)
    #version = service.new_version(id_=pid, identity=u)
    #print(version._record)
