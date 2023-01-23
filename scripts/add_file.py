import click, os

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service

@click.command('add_file')
@click.argument('recid', type=str)
@click.argument('fp', type=click.File('rb'))
@click.argument('user', type=int)
@with_appcontext
def add_file(recid, fp, user):
    """Add a new file to a published record."""
    identity = get_identity_for_user(user)
    service = get_record_service()
    record = service.read(id_=recid,identity=identity)._record
    bucket = record.files.bucket
    key = os.path.basename(fp.name)

    obj = ObjectVersion.get(bucket, key)

    click.echo(u'Will add the following file:\n')
    click.echo(click.style(
        u'  key: "{key}"\n'
        u'  bucket: {bucket}\n'
        u''.format(
            key=key,
            bucket=bucket.id),
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
    if obj is not None:
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
        record.files[key] = fp
        bucket.locked = True

        record.commit()
        db.session.commit()
        click.echo(click.style(u'File added successfully.', fg='green'))
    else:
        click.echo(click.style(u'File addition aborted.', fg='green'))

if __name__=="__main__":
    add_file()
