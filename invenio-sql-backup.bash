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

${APP_NAME} CONTAINER_NAME BACKUP_DIR

# DESCRIPTION

Dump the Postgres databases for CONTAINER_NAME into BACKUP_DIR.
CONTAINER_NAME is the name of your Invenio instance and will be
used as the prefix to the backup up filename.

# EXAMPLES

Backup the Postgres running in 'caltechdata_db_1' and write them
to '/var/backups/postgres'.

~~~shell
     ${APP_NAME} caltechdata_db_1 /var/backups/postgres
~~~

EOT

}

function backup_postgres_to() {
	DOCKER="$1"
	CONTAINER="$2"
	BACKUP_DIR="$3"
	if [ "${CONTAINER}" = "" ]; then
		echo "Missing the container name"
		exit 1
	fi
	if [ "${BACKUP_DIR}" = "" ]; then
		echo "Missing the backup directory name"
		exit 1
	fi
	if [ ! -d "${BACKUP_DIR}" ]; then
		echo "${BACKUP_DIR} does not exist"
		exit 1
	fi
	BACKUP_FILE="${BACKUP_DIR}/${CONTAINER}-${DB_NAME}-$(date +%Y-%m-%d).sql"
	$DOCKER container exec \
		"${CONTAINER}" /usr/bin/pg_dump \
		--username="${DB_USERNAME}" \
		--column-inserts \
		"${DB_NAME}" \
		>"${BACKUP_FILE}"
	if [ -f "${BACKUP_FILE}" ]; then
		gzip "${BACKUP_FILE}"
	else
		echo "WARNING: ${BACKUP_FILE} not found!"
	fi
}

function run_backups() {
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
	backup_postgres_to "$DOCKER" "$1" "$2"
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
	run_backups "$1" "$2"
	;;
esac
