#!/bin/bash

SOURCE_MACHINE="ubuntu@data.caltechlibrary.dev"
SOURCE_PATH='/home/ubuntu/invenio-sql-backups/*.sql.gz'
DEST_PATH='/home/ubuntu/invenio-sql-backups/'

if [ ! -d "${DEST_PATH}" ]; then
	mkdir -p "${DEST_PATH}"
fi
scp "${SOURCE_MACHINE}:${SOURCE_PATH}" "${DEST_PATH}"
