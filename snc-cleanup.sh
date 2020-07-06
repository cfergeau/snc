#!/bin/sh


INSTALL_DIR=crc-tmp-install-data
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-./openshift-install}

# Extract openshift-install binary if not present in current directory
if test -z ${OPENSHIFT_INSTALL-}; then
        # Destroy an existing cluster and resources
        ${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} destroy cluster || echo "No cluster to destroy"
fi

sudo rm /etc/NetworkManager/dnsmasq.d/crc-snc.conf
sudo rm /etc/NetworkManager/conf.d/crc-snc-dnsmasq.conf
sudo systemctl restart NetworkManager
