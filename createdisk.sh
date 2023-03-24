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

# Remove moby-engine package
${SSH} core@${VM_IP} -- 'sudo rpm-ostree override remove moby-engine'

prepare_cockpit ${VM_IP}
prepare_hyperV ${VM_IP}
prepare_qemu_guest_agent ${VM_IP}

# create the tap device interface with specified mac address
# this mac addresss is used to allocate a specific IP to the VM
# when tap device is in use.
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  nmcli connection add type tun ifname tap0 con-name tap0 mode tap autoconnect yes 802-3-ethernet.cloned-mac-address 5A:94:EF:E4:0C:EE
EOF

# Add gvisor-tap-vsock
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock quay.io/crcont/gvisor-tap-vsock:latest
  mkdir -p /usr/libexec/podman/
  podman cp gvisor-tap-vsock:/vm /usr/libexec/podman/gvforwarder
  podman rm gvisor-tap-vsock
  tee /etc/systemd/system/gv-user-network@.service <<TEE
[Unit]
Description=gvisor-tap-vsock Network Traffic Forwarder
After=NetworkManager.service
BindsTo=sys-devices-virtual-net-%i.device
After=sys-devices-virtual-net-%i.device

[Service]
Environment=GV_VSOCK_PORT="1024"
EnvironmentFile=-/etc/sysconfig/gv-user-network
ExecStart=/usr/libexec/podman/gvforwarder -preexisting -iface %i -url vsock://2:\\\${GV_VSOCK_PORT}/connect

[Install]
WantedBy=multi-user.target
TEE
  systemctl daemon-reload
  systemctl enable gv-user-network@tap0.service
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
