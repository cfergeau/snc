#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

source tools.sh
source createdisk-library.sh

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"

CRC_VM_NAME=${CRC_VM_NAME:-crc-podman}
BASE_OS=fedora-coreos

INSTALL_DIR=${1:-crc-tmp-install-data}

VM_IP=$(sudo virsh domifaddr ${CRC_VM_NAME} | grep vnet0 | awk '{print $4}' | sed 's;/24;;')

# Remove audit logs
${SSH} core@${VM_IP} -- 'sudo find /var/log/ -iname "*.log" -exec rm -f {} \;'

# Remove moby-engine package
${SSH} core@${VM_IP} -- 'sudo rpm-ostree override remove moby-engine'

prepare_cockpit ${VM_IP}
prepare_hyperV ${VM_IP}

# Add gvisor-tap-vsock
${SCP} -r ./gvisor-tap-vsock core@${VM_IP}:
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  chown -R root.root gvisor-tap-vsock
  mv -Z gvisor-tap-vsock/crc-tap0.nmconnection /etc/NetworkManager/system-connections/
  mv -Z gvisor-tap-vsock/gvisor-tap-vsock-forwarder.service /etc/systemd/system/
  mv -Z gvisor-tap-vsock/gvisor-tap-vsock-forwarder /usr/local/bin/
  chmod 755 /usr/local/bin/gvisor-tap-vsock-forwarder
  #chcon --reference /usr/bin/true /usr/local/bin/gvisor-tap-vsock-forwarder

  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock-forwarder.service
EOF

# Shutdown and Start the VM after modifying the set of installed packages
# This is required to get the latest ostree layer which have those installed packages.
shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

# Remove miscellaneous unneeded data from rpm-ostree
${SSH} core@${VM_IP} -- 'sudo rpm-ostree cleanup --rollback --base --repomd'
# Shutdown and Start the VM after removing base deployment tree
# This is required because kernel commandline changed, namely
# ostree=/ostree/boot.1/fedora-coreos/$hash/0 which switches 
# between boot.0 and boot.1 when cleanup is run
shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

# Only used for macOS bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # Get the rhcos ostree Hash ID
    ostree_hash=$(${SSH} core@${VM_IP} -- "cat /proc/cmdline | grep -oP \"(?<=${BASE_OS}-).*(?=/vmlinuz)\"")

    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@${VM_IP} -- 'cat /proc/cmdline')

    # SCP the vmlinuz/initramfs from VM to Host in provided folder.
    ${SCP} -r core@${VM_IP}:/boot/ostree/${BASE_OS}-${ostree_hash}/* $INSTALL_DIR
fi

podman_version=$(${SSH} core@${VM_IP} -- 'rpm -q --qf %{version} podman')

# Remove the journal logs.
# Note: With `sudo journalctl --rotate --vacuum-time=1s`, it doesn't
# remove all the journal logs so separate commands are used here.
${SSH} core@${VM_IP} -- 'sudo journalctl --rotate'
${SSH} core@${VM_IP} -- 'sudo journalctl --vacuum-time=1s'

# Shutdown the VM
shutdown_vm ${CRC_VM_NAME}

# Download podman clients
download_podman $podman_version ${yq_ARCH}

# libvirt image generation
get_dest_dir_suffix "${podman_version}"
destDirSuffix="${DEST_DIR_SUFFIX}"

libvirtDestDir="crc_podman_libvirt_${destDirSuffix}"
mkdir "$libvirtDestDir"

create_qemu_image "$libvirtDestDir" "fedora-coreos-qemu.${ARCH}.qcow2" "${CRC_VM_NAME}.qcow2"
copy_additional_files "$INSTALL_DIR" "$libvirtDestDir" "$podman_version"
create_tarball "$libvirtDestDir"

# vfkit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    vfkitDestDir="crc_podman_vfkit_${destDirSuffix}"
    generate_vfkit_bundle "$libvirtDestDir" "$vfkitDestDir" "$INSTALL_DIR" "$kernel_release" "$kernel_cmd_line"
fi

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    hypervDestDir="crc_podman_hyperv_${destDirSuffix}"
    generate_hyperv_bundle "$libvirtDestDir" "$hypervDestDir"
fi

# Cleanup up vmlinux/initramfs files
rm -fr "$INSTALL_DIR/vmlinuz*" "$INSTALL_DIR/initramfs*"
