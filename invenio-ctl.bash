#!/bin/bash

APP_NAME=$(basename $0)

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

${APP_NAME} start|stop

# DESCRIPTION

Bring invenio-rdm up or down easily. This is a convence script only.
It is not terribly bright or robust!

# EXAMPLES

~~~shell
     ${APP_HELP} help
     ${APP_NAME} stop
     ${APP_NAME} start
~~~

EOT

}

function start_invenio() {
	invenio-cli services start
	sudo systemctl start rdm_celery
	sudo systemctl start rdm_rest
	sudo systemctl start rdm
	sudo systemctl start nginx
}

function stop_invenio() {
	sudo systemctl stop nginx
	sudo systemctl stop rdm
	sudo systemctl stop rdm_rest
	sudo systemctl stop rdm_celery
	invenio-cli services stop
}

function status_invenio() {
	invenio-cli services status
	echo "Press q each status response"
	sudo systemctl status nginx
	sudo systemctl status rdm
	sudo systemctl status rdm_rest
	sudo systemctl status rdm_celery
}


#
# Main entry script point.
#
case "$1" in
	h|help|-h|--help)
		usage
		exit 0
		;;
	start)
		start_invenio
		;;
	stop)
		stop_invenio
		;;
	status)
		status_invenio
		;;
	*)
		usage
		exit 1
esac
