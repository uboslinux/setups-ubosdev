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
    sudo systemd-nspawn -b -n -M "${name}" -D "${name}" > /dev/null &
    sleep 10 
    until sudo machinectl shell "${name}" /usr/bin/ubos-admin status --ready > /dev/null; do
        echo "Waiting for container ${name} to be ready..."
        sleep 5
    done
}

# How to determinate a container
terminateContainer() {
    name="$1"

    echo "Shutting down container ${name}..."
    sudo machinectl terminate -q "${name}" > /dev/null
}

echo "** Checking pre-conditions..."

## Check we have all required executables
for e in systemd-nspawn btrfs perl; do
    which $e > /dev/null 2>&1 || die "Cannot find executable: $e"
done

## Check the current filesystem is btrfs
df --output=fstype . | grep btrfs > /dev/null 2>&1 || die "Working directory is not on a btrfs filesystem"

## default release channel is green
[[ -z "${CHANNEL}" ]] && CHANNEL=green
baseSubvol=ubos-${CHANNEL}
developSubvol=ubos-develop-${CHANNEL}
targetSubvol=ubos-target-${CHANNEL}

## Names of the files and subvolumes
[[ -z "${BASE_IMAGE_NAME}" ]] && BASE_IMAGE_NAME="ubos_${CHANNEL}_x86_64-CONTAINER_latest.tar.xz"

## Image file argument given, and file exists
[[ "$#" == 1 ]] || die "Provide a single argument: name of the downloaded image file"

imageFile=$1
[[ -f "${imageFile}" ]] || die "Image file does not exist: ${imageFile}"

echo ${imageFile} | grep ${CHANNEL}  > /dev/null 2>&1 || die "Image name (${imageFile}) does not contain the channel name (${CHANNEL})"

[[ -d "${baseSubvol}"    ]] && die "Directory exists: $baseSubvol"
[[ -d "${developSubvol}" ]] && die "Directory exists: $developSubvol"
[[ -d "${targetSubvol}"  ]] && die "Directory exists: $targetSubvol"

echo "Setting up for channel ${CHANNEL}"

####

echo "** Setting up base subvol ${baseSubvol}"

echo "Creating subvol..."
sudo btrfs subvolume create "${baseSubvol}" >/dev/null

echo "Unpacking image..."
( cd "${baseSubvol}"; sudo tar xfJ "../${imageFile}" )

bootContainer "${baseSubvol}"

echo "Updating to latest version..."
sudo machinectl shell -q "${baseSubvol}" /usr/bin/ubos-admin update >/dev/null

terminateContainer "${baseSubvol}"

####

echo "** Setting up develop subvol ${developSubvol}"

echo "Creating subvol..."
sudo btrfs subvolume snapshot "${baseSubvol}" "${developSubvol}" >/dev/null

bootContainer "${developSubvol}"

echo "Setting hostname to ${developSubvol}..."
sudo machinectl shell -q "${developSubvol}" /usr/bin/hostnamectl set-hostname "${developSubvol}" >/dev/null

echo "Permit unsigned package installs..."
sudo perl -pi -e 's!LocalFileSigLevel.*!LocalFileSigLevel = Optional!' "${developSubvol}/etc/pacman.conf"

echo "Installing development packages..."
sudo machinectl shell -q "${developSubvol}" /usr/bin/pacman -S ubos-base-devel --noconfirm >/dev/null

echo "Adding user ubosdev with ssh keys and necessary permissions..."
sudo machinectl shell -q "${developSubvol}" /usr/bin/useradd -m ubosdev -d /ubosdev -u $(id -u) >/dev/null # Create outside /home, so we can --bind /home if desired
sudo machinectl shell -q "ubosdev@${developSubvol}" /usr/bin/ssh-keygen -q -f /ubosdev/.ssh/id_rsa -P '' >/dev/null
echo "ubosdev ALL = NOPASSWD: ALL" | sudo tee "${developSubvol}/etc/sudoers.d/ubosdev" >/dev/null

if [[ -e "${HOME}/.ssh/id_rsa.pub" ]]; then
    cp "${HOME}/.ssh/id_rsa.pub" "${developSubvol}/ubosdev/.ssh/authorized_keys"
else
    echo "No ssh keypair found on host; not enabling authorized_hosts for ubosdev in ${developSubvol}"
fi

echo "Opening port 8888 for Java debugging..."
echo "8888/tcp" | sudo tee "${developSubvol}/etc/ubos/open-ports.d/java-debugging" >/dev/null
sudo machinectl shell -q "${developSubvol}" /usr/bin/ubos-admin setnetconfig container >/dev/null

terminateContainer "${developSubvol}"

####

echo "** Setting up target subvol ${targetSubvol}"

echo "Creating subvol..."
sudo btrfs subvolume snapshot "${baseSubvol}" "${targetSubvol}" >/dev/null

bootContainer "${targetSubvol}"

echo "Setting hostname to ${targetSubvol}..."
sudo machinectl shell -q "${targetSubvol}" /usr/bin/hostnamectl set-hostname "${targetSubvol}" >/dev/null

echo "Permit unsigned package installs"
sudo perl -pi -e 's!LocalFileSigLevel.*!LocalFileSigLevel = Optional!' "${targetSubvol}/etc/pacman.conf"

echo "Permit ssh login from ubosdev"
cat "${developSubvol}/ubosdev/.ssh/id_rsa.pub" | sudo systemd-run -q -P -M "${targetSubvol}" /usr/bin/ubos-admin setup-shepherd -v >/dev/null

echo "Opening port 8888 for Java debugging..."
echo "8888/tcp" | sudo tee "${targetSubvol}/etc/ubos/open-ports.d/java-debugging" >/dev/null
sudo machinectl shell -q "${targetSubvol}" /usr/bin/ubos-admin setnetconfig container >/dev/null

terminateContainer "${targetSubvol}"

####

echo "DONE."

