#!/bin/bash

PODMAN=${PODMAN:-podman}
VIRT_INSTALL=${VIRT_INSTALL:-virt-install}

if ! command -v ${PODMAN} &>/dev/null; then
    sudo yum -y install /usr/bin/podman
fi

if ! command -v ${VIRT_INSTALL} &>/dev/null; then
    sudo yum -y install /usr/bin/virt-install
fi

OPENSHIFT_INSTALL=/bin/true
OPENSHIFT_RELEASE_VERSION="0.0.0"
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
BUNDLE_TYPE="fakesnc"
INSTALL_DIR=crc-tmp-install-data
