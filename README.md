# CaltechDATA

This is the source repsository for CaltechDATA, Caltech's Institutional Data
and Software Repository. It is an instance of the [InvenioRDM repository
platform](https://inveniosoftware.org/products/rdm/).

[![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg?color=orange)](https://choosealicense.com/licenses/bsd-3-clause)
[![Latest release](https://img.shields.io/github/v/release/caltechlibrary/caltechdata.svg?color=b44e88)](https://github.com/caltechlibrary/caltechdata/releases)



## Table of contents

* [Introduction](#introduction)
* [Installation](#installation)
* [Usage](#usage)
* [Known issues and limitations](#known-issues-and-limitations)
* [Getting help](#getting-help)
* [Contributing](#contributing)
* [License](#license)
* [Authors and history](#authors-and-history)
* [Acknowledgments](#authors-and-acknowledgments)


## Introduction

This repository was initialized following [the InvenioRDM
instructions/](https://inveniordm.docs.cern.ch/install/). It was then
customized to meet the needs of the Caltech community. This is only one
deployment example, and may or not be appropriate for your specific
institution and IT setup. 

## Installation

We currently deploy CaltechDATA on a m6i.xlarge AWS EC2 instance with Ubuntu
20.04. We use this [cloud-init
file](https://github.com/caltechlibrary/cloud-init-examples/blob/main/caltechdata-init.yaml)
to do most of the initial setup.

### Install NVM

We haven't gotten NVM to install with cloud-init. Run `curl -o-
https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash`, then
reboot and type `nvm install 14`

### Install InvenioRDM

Clone this repository into /Sites, then go to that directory

```
invenio-cli install
invenio-cli services setup --no-demo-data
```

You'll need a rdm.conf file in /Sites, which includes secrets:

```
INVENIO_DATACITE_PASSWORD=
INVENIO_SECRET_KEY=
INVENIO_S3_ACCESS_KEY_ID=
INVENIO_S3_SECRET_ACCESS_KEY=
FLASK_ENV=
INVENIO_LOGGING_CONSOLE_LEVEL=
```

This configuration uses S3 for storage. You need to change the bucket name with

`pipenv run invenio files location s3-default s3://caltechdata --default`

You can load the funders vocabulary with

```
wget https://zenodo.org/record/7038913/files/v1.5-2022-08-31-ror-data.zip?download=1 -O ror.zip
pipenv run invenio vocabularies import --vocabulary funders --origin "/Sites/caltechdata/ror.zip"
```

We have a local CaltechPEOPLE list, which is loaded with

```
pipenv run invenio vocabularies import --vocabulary names --filepath ./vocabularies-future.yaml
```

### Domain Configuration

You'll need a domain name, and set an A record to point the domain name to your
AWS instance.

Move nginx.conf to `/etc/nginx/sites-enabled/default`

Copy redirect-map.conf to `/etc/nginx/`

Get a certificate with `sudo certbot --nginx`

Restart nginx with `sudo service nginx restart`

### Systemctl

We need three services to run InvenioRDM. Set them up with

```
sudo cp rdm_rest.service /etc/systemd/system/.
sudo cp rdm.service /etc/systemd/system/.
sudo cp rdm_celery.service /etc/systemd/system/.
sudo systemctl daemon-reload
sudo systemctl start rdm
sudo systemctl start rdm_rest
sudo systemctl start rdm_celery
```

You should now have a InvenioRDM repository fully running!

## Usage

### Stopping InvenioRDM

```
cd /Sites/caltechdata
sudo systemctl stop nginx
sudo systemctl stop rdm
sudo systemctl stop rdm_rest
sudo systemctl stop rdm_celery
invenio-cli services stop
```

### Starting InvenioRDM

```
cd /Sites/caltechdata
invenio-cli services start
# Make sure there are no errors in the invenio-saml install
sudo systemctl start rdm_celery
sudo systemctl start rdm_rest
sudo systemctl start rdm
sudo systemctl start nginx
```

## Known issues and limitations

These insttallation instructions are intended for this specific Caltech
deployment, and you may need to modify them to work for your specific
configuration.

## Getting help

Please open an issue or pull request if you notice any problems or have
questions.

## Contributing

Please see our [Contributing
guidelines](https://github.com/caltechlibrary/caltechdata/blob/main/CONTRIBUTING.md)

## License

Software produced by the Caltech Library is Copyright © 2022 California Institute of Technology.  This software is freely distributed under a BSD/MIT type license.  Please see the [LICENSE](LICENSE) file for more information.


## Authors and history

Tom Morrell led the CaltechDATA InvenioRDM development. Tommy Keswick did all
the themeing and site design. Robert Doiel implemented the Shibboleth login.
Mike Hucka worked on the GitHub integration. TUGraz and all the other
InvenioRDM partners were instrumental in getting all the customizations
working.

## Acknowledgments

This work was funded by the California Institute of Technology Library.


<div align="center">
  <br>
  <a href="https://www.caltech.edu">
    <img width="100" height="100" src="https://raw.githubusercontent.com/caltechlibrary/template/main/.graphics/caltech-round.png">
  </a>
</div>
