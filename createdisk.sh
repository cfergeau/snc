#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

source tools.sh
source createdisk-library.sh

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"

CRC_VM_NAME=${CRC_VM_NAME:-crc-podman}
#BASE_OS=fedora-coreos
BASE_OS="centos-stream9"

INSTALL_DIR=${1:-crc-tmp-install-data}

VM_IP=$(sudo virsh domifaddr ${CRC_VM_NAME} | grep vnet | awk '{print $4}' | sed 's;/24;;')

case ${BASE_OS} in
  "centos-stream9")
    # FIXME: Should we use this group?
    # yum groupinfo 'Container Management'
    # Last metadata expiration check: 0:00:13 ago on Fri 20 Jan 2023 11:19:53 AM EST.
    # Group: Container Management
    # Description: Tools for managing Linux containers
    # Mandatory Packages:
    #   buildah
    #   containernetworking-plugins
    #   podman
    # Optional Packages:
    #   python3-psutil
    #   toolbox
    ${SSH} core@${VM_IP} -- 'sudo yum -y install podman'
  ;;
  *)
    ${SSH} core@${VM_IP} -- 'sudo rpm-ostree override remove moby-engine'
  ;;
esac

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

cleanup_vm_image ${CRC_VM_NAME} ${VM_IP}

podman_version=$(${SSH} core@${VM_IP} -- 'rpm -q --qf %{version} podman')

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

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    hypervDestDir="crc_podman_hyperv_${destDirSuffix}"
    generate_hyperv_bundle "$libvirtDestDir" "$hypervDestDir"
fi

# vfkit image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    start_vm ${CRC_VM_NAME} ${VM_IP}
    downgrade_kernel ${VM_IP} ${yq_ARCH}
    cleanup_vm_image ${CRC_VM_NAME} ${VM_IP}

    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@${VM_IP} -- 'cat /proc/cmdline')

    # Get the rhcos ostree Hash ID
    ostree_hash=$(echo ${kernel_cmd_line} | grep -oP "(?<=${BASE_OS}-).*(?=/vmlinuz)")

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

    vfkitDestDir="crc_podman_vfkit_${destDirSuffix}"
    generate_vfkit_bundle "$libvirtDestDir" "$vfkitDestDir" "$INSTALL_DIR" "$kernel_release" "$kernel_cmd_line"

    # Cleanup up vmlinux/initramfs files
    rm -fr "$INSTALL_DIR/vmlinuz*" "$INSTALL_DIR/initramfs*"
fi
