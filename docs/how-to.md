
How To Invenio-RDM
===================

The follow are the "How To" for Invenio RDM 9.1.4

Find out your Invenio-RDM version
----------------------------------

```
pipenv run pip freeze | grep invenio-app-rdm
```


How can recreate the index without destroying the database and data?
--------------------------------------------------------------------

```
# recreate the indices
pipenv run invenio index destroy --yes-i-know
pipenv run invenio index init
# reindex the records
pipenv run invenio rdm-records rebuild-index
pipenv run invenio communities rebuild-index
```

How to publish a record which has "pending" file uploads where the upload failed?
----------------------------------------------------------------------------------

This problem happens when one or more files timeout on upload. The "pending" display
never updates. If you press "publish" you get an error like

```
Oops, something went wrong! The draft was not published. Please try again. If the problem persists, contact user support.
```

NOTE: This is documented in DR-488.





