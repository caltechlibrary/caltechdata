
Database dump and restore
=========================

Two scripts are provided for dump and restore of an Invenio DB.
Both use the same `postgres_env.cfg` configuration file. You can
dump the database while Invenio-RDM is up and running but to restore
the web service must be down as the database in PostgreSQL needs to
be closed inorder to drop and create it.


