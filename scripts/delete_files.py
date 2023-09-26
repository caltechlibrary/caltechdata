import click, os
import json

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service

@with_appcontext
def delete_file(recid, filename, user):
    """Delete a file in a published record."""
    identity = get_identity_for_user(user)
    service = get_record_service()
    record = service.read(id_=recid,identity=identity)._record
    bucket = record.files.bucket
    key = filename

    bucket.locked = False
    record.files.delete(key)
    bucket.locked = True

    record.commit()
    db.session.commit()

if __name__=="__main__":
    with open('files.json','r') as infile:
        files = json.load(infile)
        for f in files['entries']:
            delete_file('pa710-cdn95',f['key'],2)
