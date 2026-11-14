#!/bin/bash
APP_NAME="$(basename "$0")"

#
# This script fully resets a dev/test instance's backing services --
# Postgres, OpenSearch, everything invenio-cli manages -- and starts them
# over from scratch. It exists because `invenio-cli services destroy` alone
# is NOT enough once docker-services.yml's `search` service has the
# OpenSearch persistent-volume retrofit (bind-mounted host directories
# instead of a Docker-managed volume): those host directories survive
# `destroy` untouched, so a plain `destroy && setup` remounts stale
# OpenSearch data into the "fresh" container instead of starting clean.
#

function usage() {
	cat <<EOT
% ${APP_NAME}() ${APP_NAME} user manual
% R. S. Doiel
% September 28, 2026

# NAME

${APP_NAME}

# SYNOPSIS

${APP_NAME} [--yes-i-know]

# DESCRIPTION

Reset a dev/test RDM instance to a genuinely clean state: destroys all
backing service containers (Postgres, OpenSearch, Redis, RabbitMQ), wipes
the host directories that OpenSearch's bind-mounted volumes point at, then
recreates everything with 'invenio-cli services setup'.

**This is destructive and irreversible.** It discards the Postgres
database and every OpenSearch index on this instance. Never run it against
an instance whose data matters -- production, or any dev/test instance
someone else has work in progress on. If you only need to rebuild search
indexes without losing Postgres data, see building_indexes.md instead;
that path never touches the containers or these host directories at all.

Without '--yes-i-know' this only prints what it would do and exits.
Even with the flag, it still pauses for a typed 'yes' before touching
anything -- the flag alone is not enough to run it.

# EXAMPLES

~~~shell
     ${APP_NAME} --yes-i-know
~~~

EOT

}

# The host paths bind-mounted into the search service. Must match
# docker-services.yml's search: volumes: entries exactly -- checked below
# rather than trusted blindly, since a future docker-services.yml edit
# could move them without this script being updated to match.
OPENSEARCH_DATA_DIR="/opt/rdm_opensearch_data_migrated"
OPENSEARCH_BACKUPS_DIR="/opt/rdm_opensearch_backups"

# opensearchproject/opensearch's official image runs as this uid:gid;
# a bind-mounted directory the container can't write to as this user
# fails silently or refuses to start.
OPENSEARCH_UID=1000
OPENSEARCH_GID=1000

function check_compose_file() {
	if [ ! -f "docker-services.yml" ]; then
		echo "docker-services.yml not found in $(pwd) -- run this from the instance's app directory."
		exit 1
	fi
	for DIR in "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_BACKUPS_DIR}"; do
		if ! grep -qF "${DIR}:" docker-services.yml; then
			echo "WARNING: ${DIR} not found in docker-services.yml's search: volumes."
			echo "This script's OPENSEARCH_DATA_DIR/OPENSEARCH_BACKUPS_DIR may be stale --"
			echo "check the search: service's volumes: block before proceeding:"
			grep -n -A 20 "^  search:" docker-services.yml
			exit 1
		fi
	done
}

function reset_services() {
	check_compose_file

	echo "This will destroy Postgres and OpenSearch data on this instance,"
	echo "including ${OPENSEARCH_DATA_DIR} and ${OPENSEARCH_BACKUPS_DIR}."
	echo "Never run this against production or a shared instance without checking first."
	echo ""
	read -r -p "Type 'yes' to continue: " CONFIRMATION
	if [ "${CONFIRMATION}" != "yes" ]; then
		echo "Aborted, nothing was touched."
		exit 1
	fi

	invenio-cli services destroy

	echo "Clearing bind-mounted OpenSearch host directories..."
	sudo rm -rf "${OPENSEARCH_DATA_DIR:?}"/* "${OPENSEARCH_BACKUPS_DIR:?}"/*
	sudo chown -R "${OPENSEARCH_UID}:${OPENSEARCH_GID}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_BACKUPS_DIR}"

	invenio-cli services setup
}

#
# Main entry script point.
#
case "$1" in
h | help | -h | --help)
	usage
	exit 0
	;;
--yes-i-know)
	reset_services
	;;
*)
	usage
	echo "Nothing done -- pass --yes-i-know to actually run this."
	exit 1
	;;
esac
