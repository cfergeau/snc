#!/bin/bash

JQ=${JQ:-jq}

QEMU_IMG=${QEMU_IMG:-qemu-img}
VIRT_FILESYSTEMS=${VIRT_FILESYSTEMS:-virt-filesystems}
GUESTFISH=${GUESTFISH:-guestfish}

XMLLINT=${XMLLINT:-xmllint}

DIG=${DIG:-dig}
UNZIP=${UNZIP:-unzip}
ZSTD=${ZSTD:-zstd}
CRC_ZSTD_EXTRA_FLAGS=${CRC_ZSTD_EXTRA_FLAGS:-"--ultra -22"}

HTPASSWD=${HTPASSWD:-htpasswd}
PATCH=${PATCH:-patch}

ARCH=$(uname -m)

case "${ARCH}" in
    x86_64)
        yq_ARCH="amd64"
        SNC_GENERATE_MACOS_BUNDLE=1
        SNC_GENERATE_WINDOWS_BUNDLE=1
	;;
    aarch64)
        yq_ARCH="arm64"
        SNC_GENERATE_MACOS_BUNDLE=1
        SNC_GENERATE_WINDOWS_BUNDLE=
	;;
    *)
        yq_ARCH=${ARCH}
        SNC_GENERATE_MACOS_BUNDLE=
        SNC_GENERATE_WINDOWS_BUNDLE=
	;;
esac

# Download yq/jq for manipulating in place yaml configs
if test -z ${YQ-}; then
    echo "Downloading yq binary to manipulate yaml files"
    curl -L https://github.com/mikefarah/yq/releases/download/v4.5.1/yq_linux_${yq_ARCH} -o yq
    chmod +x yq
    YQ=./yq
fi

if ! command -v ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

# Add virt-filesystems/guestfish/qemu-img
if ! command -v ${VIRT_FILESYSTEMS}; then
    sudo yum -y install /usr/bin/virt-filesystems
fi

if ! command -v ${GUESTFISH}; then
    sudo yum -y install /usr/bin/guestfish
fi

if ! command -v ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi
# The CoreOS image uses an XFS filesystem
# Beware than if you are running on an el7 system, you won't be able
# to resize the crc VM XFS filesystem as it was created on el8
if ! rpm -q libguestfs-xfs; then
    sudo yum install libguestfs-xfs
fi

if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ];then
    if ! command -v ${UNZIP}; then
        sudo yum -y install /usr/bin/unzip
    fi
fi

if ! command -v ${XMLLINT}; then
    sudo yum -y install /usr/bin/xmllint
fi

if ! command -v ${DIG}; then
    sudo yum -y install /usr/bin/dig
fi

if ! command -v ${ZSTD}; then
    sudo yum -y install /usr/bin/zstd
fi

if ! command -v ${HTPASSWD}; then
    sudo yum -y install /usr/bin/htpasswd
fi

if ! command -v ${PATCH}; then
    sudo yum -y install /usr/bin/patch
fi

function retry {
    local retries=10
    local count=0
    until "$@"; do
        exit=$?
        wait=$((2 ** $count))
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..." 1>&2
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left." 1>&2
            return $exit
        fi
    done
    return 0
}

function get_vm_prefix {
    local crc_vm_name=$1
    # This random_string is created by installer and added to each resource type,
    # in installer side also variable name is kept as `random_string`
    # so to maintain consistancy, we are also using random_string here.
    random_string=$(sudo virsh list --all | grep -oP "(?<=${crc_vm_name}-).*(?=-master-0)")
    if [ -z $random_string ]; then
        echo "Could not find virtual machine created by snc.sh"
        exit 1;
    fi
    echo ${crc_vm_name}-${random_string}
}

function shutdown_vm {
    local vm_prefix=$1
    retry sudo virsh shutdown ${vm_prefix}-master-0
    # Wait till instance started successfully
    until sudo virsh domstate ${vm_prefix}-master-0 | grep shut; do
        echo " ${vm_prefix}-master-0 still running"
        sleep 3
    done
}

function start_vm {
    local vm_prefix=$1
    retry sudo virsh start ${vm_prefix}-master-0
    # Wait till ssh connection available
    until ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "exit 0" >/dev/null 2>&1; do
        echo " ${vm_prefix}-master-0 still booting"
        sleep 2
    done
}

function generate_htpasswd_file {
   local auth_file_dir=$1
   local pass_file=$2
   random_password=$(cat $1/auth/kubeadmin-password)
   ${HTPASSWD} -c -B -b ${pass_file} developer developer
   ${HTPASSWD} -B -b ${pass_file} kubeadmin ${random_password}
}
