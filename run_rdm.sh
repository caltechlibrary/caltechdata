/usr/local/bin/pipenv run celery --app invenio_app.celery worker --beat --events --loglevel INFO
/usr/local/bin/pipenv run uwsgi --logger syslog:inveniordm_ui uwsgi_ui.ini
