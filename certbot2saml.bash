#!/bin/bash
echo $(readlink -f $0)
SCRIPTNAME=$(readlink -f $0)
DNAME=$(dirname ${SCRIPTNAME})
cd "${DNAME}"
if [ $USER != "root" ]; then
	cat <<EOT

ERROR: This script is run from the root account only since it works
with prividged keys.

EOT
exit 1
fi
HOSTNAME="data.caltechlibrary.dev"

if [ ! -d ./saml ]; then 
cat <<EOT
You need to setup the ./saml directory, e.g.

   mkdir saml
   chown -R ubuntu:ubuntu saml
   chmod ug=rwxs,o= saml
   chmod ug=r,o= sam/sp.key
   chmod ugo=r sam/sp.crt

EOT
exit 1
fi

cp -vp "/etc/letsencrypt/live/${HOSTNAME}/privkey.pem" ./saml/
cp -vp "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" ./saml/

# This converts /etc/letsencrypt/live/$HOSTNAME/privkey.pem 
# to ./saml/sp.key
if openssl rsa -in ./saml/privkey.pem -out ./saml/sp.key; then
	echo "./saml/sp.key created"
	chmod ug=r,o= ./saml/sp.key
else
	echo "Error creating ./saml/sp.key"
	exit 1
fi

# This converts /etc/letsencrypt/live/$HOSTNAME/fullchain.pem
# to ./saml/sp.crt
if openssl x509 -in ./saml/fullchain.pem -out ./saml/sp.crt; then
	echo "./saml/sp.crt created"
	chmod ugo=r ./saml/sp.crt
else
	echo "Error creating ./saml/sp.cert"
	exit 1
fi

# Cleanup unneeded files after conversion
rm ./saml/privkey.pem
rm ./saml/fullchain.pem
