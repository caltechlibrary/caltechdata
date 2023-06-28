# Run with `pipenv run invenio shell update_user_info.py`

import click
from flask_security.confirmable import confirm_user
from invenio_accounts.proxies import current_datastore
from invenio_db import db
from invenio_users_resources.services.users.tasks import reindex_user

@click.group()
def cli():
    pass

@click.command('change_username')
@click.argument('user', type=int)
@click.argument('new_username', type=str)
def change_username(user, new_username):
    user = current_datastore.get_user(user)
    user.username = new_username
    db.session.commit()
    reindex_user(user.id)

@click.command('confirm_user')
@click.argument('user', type=int)
def confirm_user(user):
    user = current_datastore.get_user(user)
    confirm_user(user)
    db.session.commit()
    reindex_user(user.id)

cli.add_command(change_username)
cli.add_command(confirm_user)

if __name__=="__main__":
    cli()
