#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

# kill all the child processes for this script when it exits
trap 'jobs=($(jobs -p)); [ -n "${jobs-}" ] && ((${#jobs})) && kill "${jobs[@]}" || true' EXIT

CRC_VM_NAME=${CRC_VM_NAME:-crc-podman}
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"

run_preflight_checks

sudo virsh destroy ${CRC_VM_NAME} || true
sudo virsh undefine --nvram ${CRC_VM_NAME} || true
sudo rm -fr /var/lib/libvirt/images/crc-podman.qcow2

CRC_INSTALL_DIR=crc-tmp-install-data
rm -fr ${CRC_INSTALL_DIR}
mkdir ${CRC_INSTALL_DIR}
chcon --verbose unconfined_u:object_r:svirt_home_t:s0 ${CRC_INSTALL_DIR}

# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

# Download the latest fedora coreos latest qcow2
mkdir ${PWD}/${CRC_INSTALL_DIR}/tmp/
# Download HTML directory listing of cloud images sorted in date descending order,
# only keep the lines corresponding to an actual image (".*GenericCloud.*qcow2"),
# and extract the filename from '<a href=".*qcow2">'
MIRROR="https://cloud.centos.org/centos/9-stream/${ARCH}/"
latest_image=$((curl --silent "${MIRROR}/images/?C=M;O=D"; true) | grep --max-count=1 GenericCloud.*qcow2\" | sed 's/.*<a href="\(.*.qcow2\)".*>/\1/')
echo "${latest_image}"
if [ ! -e ${latest_image} ]; then
	rm CentOS-Stream-GenericCloud-9.*.${ARCH}.qcow2
	curl -L -O "${MIRROR}/images/${latest_image}"
fi
ln ${latest_image} ${CRC_INSTALL_DIR}/tmp/CentOS-Stream-GenericCloud-9.${ARCH}.qcow2
sudo mv ${CRC_INSTALL_DIR}/tmp/CentOS-Stream-GenericCloud-9.${ARCH}.qcow2 /var/lib/libvirt/images/
rmdir ${PWD}/${CRC_INSTALL_DIR}/tmp/

#sudo setfacl -m u:qemu:rx $HOME
#sudo systemctl restart libvirtd

create_json_description

#CAREFUL: different --cloud-init options between rhel8 and f37
# -> see c8afd1f5, ssh-key is aliased to root-ssh-key
# rhel8:
#$ virt-install --cloud-init=?
#--cloud-init options:
#  disable
#  meta-data
#  root-password-file
#  root-password-generate
#  ssh-key
#  user-data
#
# f37:
# --cloud-init options:
#  clouduser-ssh-key
#  disable
#  meta-data
#  network-config
#  root-password-file
#  root-password-generate
#  root-ssh-key
#  user-data
sudo ${VIRT_INSTALL} --name=${CRC_VM_NAME} --vcpus=2 --ram=2048 --arch=${ARCH}\
        --import --graphics=none \
	--cloud-init ssh-key=$(pwd)/id_ecdsa_crc.pub,disable=on \
	--disk=size=31,backing_store=/var/lib/libvirt/images/CentOS-Stream-GenericCloud-9.${ARCH}.qcow2 \
        --os-variant=centos-stream9 \
	--noautoconsole --quiet
sleep 120

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"
BASE_OS=centos-stream9
INSTALL_DIR=${1:-crc-tmp-install-data}
VM_IP=$(sudo virsh domifaddr ${CRC_VM_NAME} | grep vnet | awk '{print $4}' | sed 's;/24;;')
${SSH} root@${VM_IP} 'sudo bash -x -s' <<EOF
  useradd core
  cp -a /root/.ssh /home/core/
  chown -R core.core /home/core/.ssh
  rm -rf /root/.ssh
  echo 'core ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/core
EOF
