import click, os
from io import SEEK_END, SEEK_SET

from flask.cli import with_appcontext
from invenio_cache import current_cache
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_pidstore.models import PersistentIdentifier
from invenio_records.api import Record
from invenio_records.models import RecordMetadata
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service, get_user_by_identifier
from invenio_utilities_tuw.cli.utils import set_record_owners


identity = get_identity_for_user(2)
service = get_record_service()


#from invenio_pidstore.resolver import Resolver

#record_resolver = Resolver(
#    pid_type='recid', object_type='rec', getter=ZenodoRecord.get_record
#)
#

#def get_service():
#    factory = lambda: current_rdm_records.records_service
#    return factory()

@click.command('add_file')
@click.argument('recid', type=str)
@click.argument('fp', type=click.File('rb'))
@click.option('--replace-existing', '-f', is_flag=True, default=False)
@with_appcontext
def add_file(recid, fp, replace_existing):
    """Add a new file to a published record."""
    #pid, record = record_resolver.resolve(recid)
    #service = get_service()
    record = service.read(id_=recid, identity=identity)._record
    bucket = record.files.bucket
    key = os.path.basename(fp.name)

    obj = ObjectVersion.get(bucket, key)
    if obj is not None and not replace_existing:
        click.echo(click.style(u'File with key "{key}" already exists.'
                   u' Use `--replace-existing/-f` to overwrite it.'.format(
                        key=key, recid=recid), fg='red'))
        return

    fp.seek(SEEK_SET, SEEK_END)
    size = fp.tell()
    fp.seek(SEEK_SET)

    print(record)

    click.echo(u'Will add the following file:\n')
    click.echo(click.style(
        u'  key: "{key}"\n'
        u'  bucket: {bucket}\n'
        u'  size: {size}\n'
        u''.format(
            key=key,
            bucket=bucket.id,
            size=size),
        fg='green'))
    click.echo(u'to record:\n')
    click.echo(click.style(
        u'  Title: "{title}"\n'
        u'  RECID: {recid}\n'
        u'  UUID: {uuid}\n'
        u''.format(
            recid=record['id'],
            title=record['metadata']['title'],
            uuid=record.id),
        fg='green'))
    if replace_existing and obj is not None:
        click.echo(u'and remove the file:\n')
        click.echo(click.style(
            u'  key: "{key}"\n'
            u'  bucket: {bucket}\n'
            u'  size: {size}\n'
            u''.format(
                key=obj.key,
                bucket=obj.bucket,
                size=obj.file.size),
            fg='green'))

    if click.confirm(u'Continue?'):
        bucket.locked = False
        if obj is not None and replace_existing:
            bucket.size -= obj.file.size
            ObjectVersion.delete(bucket, obj.key)
        ObjectVersion.create(bucket, key, stream=fp, size=size)
        bucket.locked = True

        record.files.flush()
        record.commit()
        db.session.commit()
        click.echo(click.style(u'File added successfully.', fg='green'))
    else:
        click.echo(click.style(u'File addition aborted.', fg='green'))

if __name__=="__main__":
    add_file()
