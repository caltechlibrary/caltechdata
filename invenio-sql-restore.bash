#!/bin/bash
APP_NAME="$(basename "$0")"

#
# This script can bring invenio-rdm down in an orderly fashion
# or start it back up.
#

function usage() {
	cat <<EOT
% ${APP_NAME}() ${APP_NAME} user manual
% R. S. Doiel
% August 17, 2022

# NAME

${APP_NAME}

# SYNOPSIS

${APP_NAME} CONTAINER_NAME BACKUP_NAME

# DESCRIPTION

Restore the Postgres databases for CONTAINER_NAME from BACKUP_NAME.
CONTAINER_NAME is the name of your Invenio instance and will be
used as the prefix to the backup up filename. BACKUP_NAME is the
path to your SQL dump file.

# EXAMPLES

Restore the Postgres running in 'caltechdata_db_1' and write them
to '/var/backups/postgres/caltechdata-dump-2022-09-19.sql'.

~~~shell
     ${APP_NAME} caltechdata_db_1 /var/backups/postgres/caltechdata-dump-2022-09-19.sql
~~~

EOT

}

function restore_postgres_from() {
	BACKUP_FILE="$1"
	DOCKER="$2"
	CONTAINER="$3"
	if [ "${CONTAINER}" = "" ]; then
		echo "Missing the container name"
		exit 1
	fi
	$DOCKER container exec -it "${CONTAINER}" /usr/bin/psql -U "${DB_USERNAME}" --dbname postgres -c "DROP DATABASE IF EXISTS ${DB_NAME}"
	$DOCKER container exec -it "${CONTAINER}" /usr/bin/psql -U "${DB_USERNAME}" --dbname postgres -c "CREATE DATABASE ${DB_NAME}"
	$DOCKER container exec /usr/bin/createdb -U "${DB_USERNAME}" caltechdata
 	cat "${BACKUP_FILE}" | $DOCKER container exec \
 		-i "${CONTAINER}" /usr/bin/psql \
 		--username="${DB_USERNAME}" \
 		"${DB_NAME}"
}

function run_restore() {
	#
	# Sanity check our requiremented environment
	#
	SCRIPTNAME="$(readlink -f "$0")"
	DNAME="$(dirname "${SCRIPTNAME}")"
	cd "${DNAME}" || exit 1
	# Source the file "postgres_env.cfg" it contains the
	# value $DB_USERNAME.
	if [ -f postgres_env.cfg ]; then
		. postgres_env.cfg
	fi
	if [ "$DB_NAME" = "" ]; then
		echo "The environment variable DB_NAME is not set."
		exit 1
	fi
	if [ "$DB_USERNAME" = "" ]; then
		echo "The environment variable DB_USERNAME is not set."
		exit 1
	fi

	DOCKER="/usr/bin/docker"
	if [ ! -f "${DOCKER}" ]; then
		DOCKER=$(which docker)
	fi
	if [ "${DOCKER}" = "" ]; then
		echo "Cannot find docker program, aborting"
		exit 1
	fi
	restore_postgres_from "$2" "$DOCKER" "$1"
}

#
# Main entry script point.
#
case "$1" in
h | help | -h | --help)
	usage
	exit 0
	;;
*)
	if [ "$1" = "" ]; then
		usage
		exit 1
	fi
	run_restore "$1" "$2"
	;;
esac
