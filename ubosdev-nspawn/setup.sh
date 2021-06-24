#!/bin/bash
#
# Create the default UBOS development setup with systemd-nspawn containers
#

set -e

# Single-point fatal exit
die() {
    echo "FATAL: $*" 1>&2
    exit 1;
}

# How to boot a container
bootContainer() {
    name="$1"

    echo "Booting container ${name}..."
    sudo systemd-nspawn -b -n -M "${name}" -D "${name}" >/dev/null 2>&1 &
    sleep 10 
    until sudo machinectl shell "${name}" /usr/bin/ubos-admin status --ready >/dev/null 2>&1; do
        echo "Waiting for container ${name} to be ready..."
        sleep 5
    done
}

# How to determinate a container
terminateContainer() {
    name="$1"

    echo "Shutting down container ${name}..."
    sudo machinectl terminate "${name}"
}

echo "Checking pre-conditions..."

## Check we have all required executables
for e in systemd-nspawn btrfs perl; do
    which $e > /dev/null 2>&1 || die "Cannot find executable: $e"
done

## Check the current filesystem is btrfs
df --output=fstype . | grep btrfs > /dev/null 2>&1 || die "Working directory is not on a btrfs filesystem"

## default release channel is yellow
[[ -z "${CHANNEL}" ]] && CHANNEL=yellow

## Names of the files and subvolumes
[[ -z "${BASE_IMAGE_NAME}" ]] && BASE_IMAGE_NAME="ubos_${CHANNEL}_x86_64-CONTAINER_latest.tar.xz"

## Image file argument given, and file exists
[[ "$#" == 1 ]] || die "Provide a single argument: name of the downloaded image file"

imageFile=$1
[[ -f "${imageFile}" ]] || die "Image file does not exist: ${imageFile}"

baseSubvol=ubos-${CHANNEL}
developSubvol=ubos-develop-${CHANNEL}
targetSubvol=ubos-target-${CHANNEL}


## if needed, unpack base image and update it
if [[ ! -d "${baseSubvol}" ]]; then
    echo "Creating subvol ${baseSubvol}..."
    sudo btrfs subvolume create "${baseSubvol}"

    echo "Unpacking image..."
    ( cd "${baseSubvol}"; sudo tar xfJ "../${imageFile}" )

    bootContainer "${baseSubvol}"

    echo "Updating to latest version..."
    sudo machinectl shell "${baseSubvol}" /usr/bin/ubos-admin update -v

    terminateContainer "${baseSubvol}"

else
    echo "Directory exists, skipping create / unpack: ${baseSubvol}"
fi

## if needed, create develop subvolume, set hostname, install develop packages, create ubosdev user
if [[ ! -d "${developSubvol}" ]]; then
    echo "Creating subvol ${developSubvol}..."
    sudo btrfs subvolume snapshot "${baseSubvol}" "${developSubvol}"

    bootContainer "${developSubvol}"

    echo "Settng hostname to ${developSubvol}..."
    sudo machinectl shell "${developSubvol}" /usr/bin/hostnamectl set-hostname "${developSubvol}"

    echo "Installing development packages..."
    sudo machinectl shell "${developSubvol}" /usr/bin/pacman -S ubos-base-devel --noconfirm

    echo "Adding user ubosdev with ssh keys and necessary permissions..."
    sudo machinectl shell "${developSubvol}" /usr/bin/useradd -m ubosdev -u $(id -u)
    sudo machinectl shell "ubosdev@${developSubvol}" /usr/bin/ssh-keygen -q -f /home/ubosdev/.ssh/id_rsa -P ''
    echo "ubosdev ALL = NOPASSWD: ALL" | sudo tee "${developSubvol}/etc/sudoers.d/ubosdev" > /dev/null

    if [[ -e "${HOME}/.ssh/id_rsa.pub" ]]; then
        cp "${HOME}/.ssh/id_rsa.pub" "${developSubvol}/home/ubosdev/.ssh/authorized_keys"
    else
        echo "No ssh keypair found on host; not enabling authorized_hosts for ubodev in ${developSubvol}"
    fi

    terminateContainer "${developSubvol}"

else
    echo "Directory exists, skipping create: ${developSubvol}"
fi

## if needed, create target subvolume, allow shepherd login from ubosdev and unsigned package installs
if [[ ! -d "${targetSubvol}" ]]; then
    echo "Creating subvol ${targetSubvol}..."
    sudo btrfs subvolume snapshot "${baseSubvol}" "${targetSubvol}"

    bootContainer "${targetSubvol}"

    echo "Settng hostname to ${targetSubvol}..."
    sudo machinectl shell "${targetSubvol}" /usr/bin/hostnamectl set-hostname "${targetSubvol}" 

    echo "Permit unsigned package installs and login from"
    sudo perl -pi -e 's!LocalFileSigLevel.*!LocalFileSigLevel = Optional!' "${targetSubvol}/etc/pacman.conf"

    echo "Permit ssh login from ubosdev"
    cat "${developSubvol}/home/ubosdev/.ssh/id_rsa.pub" | sudo systemd-run -P -M "${targetSubvol}" /usr/bin/ubos-admin setup-shepherd -v

    terminateContainer "${targetSubvol}"

else
    echo "Directory exists, skipping create: ${targetSubvol}"
fi

echo "DONE."

