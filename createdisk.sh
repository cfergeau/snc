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

VM_IP=$(sudo virsh domifaddr ${CRC_VM_NAME} | grep vnet | awk '{print $4}' | sed 's;/24;;')

# Remove audit logs
${SSH} core@${VM_IP} -- 'sudo find /var/log/ -iname "*.log" -exec rm -f {} \;'

# Remove moby-engine package
${SSH} core@${VM_IP} -- 'sudo rpm-ostree override remove moby-engine'

prepare_cockpit ${VM_IP}
prepare_hyperV ${VM_IP}
prepare_qemu_guest_agent ${VM_IP}

# Add gvisor-tap-vsock
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock --privileged --net=host -v /etc/resolv.conf:/etc/resolv.conf -it quay.io/crcont/gvisor-tap-vsock:latest
  podman generate systemd --restart-policy=no gvisor-tap-vsock > /etc/systemd/system/gvisor-tap-vsock.service
  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock.service
EOF

# Shutdown and Start the VM after modifying the set of installed packages
# This is required to get the latest ostree layer which have those installed packages.
shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

${SSH} core@${VM_IP} 'bash -x -s' <<EOF
  curl -L -O https://kojipkgs.fedoraproject.org//packages/kernel/5.18.19/200.fc36/x86_64/kernel-5.18.19-200.fc36.x86_64.rpm -L -O https://kojipkgs.fedoraproject.org//packages/kernel/5.18.19/200.fc36/x86_64/kernel-core-5.18.19-200.fc36.x86_64.rpm  -L -O https://kojipkgs.fedoraproject.org//packages/kernel/5.18.19/200.fc36/x86_64/kernel-modules-5.18.19-200.fc36.x86_64.rpm
  sudo rpm-ostree override -C replace *.rpm
  rm *.rpm
EOF

shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  ostree admin pin 0
  ostree admin pin 1
  rpm-ostree rollback
  rpm-ostree cleanup --rollback --base --repomd
EOF

# Only used for macOS bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # 'rpm-ostree rollback' changed deployment indexes, the one with the older kernel is now 1
    kernel_cmd_line="$(${SSH} core@${VM_IP} -- 'rpm-ostree kargs --deploy-index 1')"
    ostree_hash=$(echo $kernel_cmd_line | grep -oP "(?<=ostree=/ostree/boot.[01]/${BASE_OS}/).*(?=/[01])")
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Copy kernel/initramfs
    # A temporary location is needed as the initramfs cannot be directly read
    # by the 'core' user
    ${SSH} core@${VM_IP} -- 'bash -x -s' <<EOF
        mkdir /tmp/kernel
        sudo cp -r /boot/ostree/${BASE_OS}-${ostree_hash}/*${kernel_release}* /tmp/kernel
        sudo chmod 644 /tmp/kernel/initramfs*
EOF
    ${SCP} -r core@${VM_IP}:/tmp/kernel/* $INSTALL_DIR
    ${SSH} core@${VM_IP} -- "sudo rm -fr /tmp/kernel"
fi

echo "kernel cmdline: $kernel_cmd_line"
read
read

# Shutdown and start the VM after rpm-ostree rollback.
# This is required because kernel/kernel commandline/initrd are
# different between the 2 ostree deployments.
# We want the deployment with the latest kernel to be used by default.
shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

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
