# Run with `pipenv run invenio shell change_owner.py`

import click,csv

from flask.cli import with_appcontext
from invenio_db import db
from invenio_accounts import current_accounts
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service, get_user_by_identifier
from invenio_utilities_tuw.cli.utils import set_record_owners

@click.group()
def cli():
    pass

# @click.command('change_owner')
# @click.argument('recid', type=str)
# @click.argument('owner', type=int)
# @click.argument('user', type=int)
def change_owner(recid, owner, user):
    u = get_identity_for_user(user)
    service = get_record_service()
    record = service.read(id_=recid, identity=u)._record
    all_owners = [get_user_by_identifier(owner)]
    set_record_owners(record, all_owners)
    if service.indexer:
        service.indexer.index(record)

@click.command('change_owners')
@click.argument('owner_file', type=click.File('r'))
def change_owners(owner_file):
    reader = csv.reader(owner_file)
    for line in reader:
        print(line[0])
        change_owner(line[0],int(line[1]),2)
        exit()

#cli.add_command(change_owner)
cli.add_command(change_owners)

if __name__=="__main__":
    cli()
