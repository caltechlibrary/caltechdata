from flask_security.utils import hash_password
from invenio_accounts.proxies import current_datastore
from invenio_db import db

user = current_datastore.get_user("joy@caltech.edu")
current_datastore.deactivate_user(user)
db.session.commit()
