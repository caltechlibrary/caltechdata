import click, os

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service

@click.command('delete_file')
@click.argument('recid', type=str)
@click.argument('filename', type=str)
@click.argument('user', type=int)
@with_appcontext
def delete_file(recid, filename, user):
    """Delete a file in a published record."""
    identity = get_identity_for_user(user)
    service = get_record_service()
    record = service.read(id_=recid,identity=identity)._record
    bucket = record.files.bucket
    key = filename

    obj = ObjectVersion.get(bucket, key)

    click.echo(u'Will delete the following file:\n')
    click.echo(click.style(
        u'  key: "{key}"\n'
        u'  bucket: {bucket}\n'
        u''.format(
            key=key,
            bucket=bucket.id),
        fg='green'))
    click.echo(u'from record:\n')
    click.echo(click.style(
        u'  Title: "{title}"\n'
        u'  RECID: {recid}\n'
        u'  UUID: {uuid}\n'
        u''.format(
            recid=record['id'],
            title=record['metadata']['title'],
            uuid=record.id),
        fg='green'))

    if click.confirm(u'Continue?'):
        bucket.locked = False
        record.files.delete(key)
        bucket.locked = True

        record.commit()
        db.session.commit()
        click.echo(click.style(u'File deletion successful.', fg='green'))
    else:
        click.echo(click.style(u'File deletion aborted.', fg='green'))

if __name__=="__main__":
    delete_file()
