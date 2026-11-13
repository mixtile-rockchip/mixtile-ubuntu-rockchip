#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

# shellcheck source=/dev/null
source "../scripts/secure-boot-common.sh"

SECURE="${SECURE_BOOT:-}"
if [ "${SECURE}" = "Y" ]; then
    [ "${SECURE_BOOT_SUPPORTED}" = "Y" ] || {
        echo "Error: board ${BOARD} does not enable secure boot" >&2
        exit 1
    }
    [ -n "${SECURE_BOOT_KEY_DIR}" ] || {
        echo "Error: SECURE_BOOT_KEY_DIR is not set" >&2
        exit 1
    }
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    secure_boot_validate_keys "${SECURE_BOOT_KEY_DIR}" "${repo_root}"
    SECURE_BOOT_KEY_DIR="$(readlink -f -- "${SECURE_BOOT_KEY_DIR}")"
    export SECURE_BOOT_KEY_DIR
    if [ "${LAUNCHPAD}" = "Y" ]; then
        echo "Error: --launchpad U-Boot cannot be used in secure mode" >&2
        exit 1
    fi
fi

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_stamp="secureboot-${BOARD}.stamp"
    expected_mode="normal"
    expected_key=""
    if [ "${SECURE}" = "Y" ]; then
        expected_mode="secure"
        expected_key="$(secure_boot_key_id "${SECURE_BOOT_KEY_DIR}")"
    fi

    [ -f "${uboot_stamp}" ] || {
        echo "Error: missing ${uboot_stamp}; rebuild U-Boot for the current mode" >&2
        exit 1
    }
    stamp_mode="$(secure_boot_stamp_get "${uboot_stamp}" mode || true)"
    stamp_key="$(secure_boot_stamp_get "${uboot_stamp}" key_id || true)"
    [ "${stamp_mode}" = "${expected_mode}" ] || {
        echo "Error: U-Boot stamp mode '${stamp_mode}' does not match '${expected_mode}'" >&2
        exit 1
    }
    [ "${stamp_key}" = "${expected_key}" ] || {
        echo "Error: U-Boot stamp key does not match the current key" >&2
        exit 1
    }

    uboot_package="$(secure_boot_stamp_get "${uboot_stamp}" uboot_deb || true)"
    [ -n "${uboot_package}" ] && [ -f "${uboot_package}" ] || {
        echo "Error: selected U-Boot deb is missing: ${uboot_package}" >&2
        exit 1
    }
    if [ "$(secure_boot_file_sha256 "${uboot_package}")" != \
         "$(secure_boot_stamp_get "${uboot_stamp}" uboot_deb_sha256 || true)" ]; then
        echo "Error: selected U-Boot deb does not match the stamp" >&2
        exit 1
    fi

    linux_image_package="$(basename "$(find linux-image-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_image_package" ]; then
        echo "Error: could not find the linux image package"
        exit 1
    fi

    linux_headers_package="$(basename "$(find linux-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_headers_package" ]; then
        echo "Error: could not find the linux headers package"
        exit 1
    fi

    linux_modules_package="$(basename "$(find linux-modules-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_modules_package" ]; then
        echo "Error: could not find the linux modules package"
        exit 1
    fi

    linux_buildinfo_package="$(basename "$(find linux-buildinfo-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_buildinfo_package" ]; then
        echo "Error: could not find the linux buildinfo package"
        exit 1
    fi

    linux_rockchip_headers_package="$(basename "$(find linux-rockchip-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_rockchip_headers_package" ]; then
        echo "Error: could not find the linux rockchip headers package"
        exit 1
    fi
fi

setup_mountpoint() {
    local mountpoint="$1"

    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi

    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    # Provide more up to date apparmor features, matching target kernel
    # cgroup2 mount for LP: 1944004
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

teardown_mountpoint() {
    # Reverse the operations from setup_mountpoint
    local mountpoint
    mountpoint=$(realpath "$1")

    # ensure we have exactly one trailing slash, and escape all slashes for awk
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    # sort -r ensures that deeper mountpoints are unmounted first
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
}

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# Override localisation settings to address a perl warning
export LC_ALL=C

# Debootstrap options
chroot_dir=rootfs
overlay_dir=../overlay

# Extract the compressed root filesystem
rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
tar -xpJf "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir}

# Mount the root filesystem
setup_mountpoint $chroot_dir

# Update packages
chroot $chroot_dir apt-get update
chroot $chroot_dir apt-get -y upgrade
    
# Run config hook to handle board specific changes
if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi 

# Download and install U-Boot
if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y install "u-boot-${BOARD}"
else
    cp "${uboot_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} dpkg -i "/tmp/${uboot_package}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${uboot_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"

    # The selected deb must contain the exact final loader and U-Boot FIT
    # recorded in the stamp.
    [ "$(secure_boot_file_sha256 "${chroot_dir}/usr/lib/u-boot/idbloader.img")" = \
      "$(secure_boot_stamp_get "${uboot_stamp}" idbloader_sha256 || true)" ] || {
        echo "Error: installed idbloader does not match the stamp" >&2
        exit 1
    }
    [ "$(secure_boot_file_sha256 "${chroot_dir}/usr/lib/u-boot/u-boot.itb")" = \
      "$(secure_boot_stamp_get "${uboot_stamp}" uboot_itb_sha256 || true)" ] || {
        echo "Error: installed u-boot.itb does not match the stamp" >&2
        exit 1
    }

    cp "${linux_image_package}" "${linux_headers_package}" "${linux_modules_package}" "${linux_buildinfo_package}" "${linux_rockchip_headers_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{ print \$2 }')"
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/{${linux_image_package},${linux_modules_package},${linux_buildinfo_package},${linux_rockchip_headers_package}}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_image_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_modules_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_buildinfo_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_rockchip_headers_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
fi

# Update the initramfs
chroot ${chroot_dir} update-initramfs -u

# Remove packages
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean
chroot ${chroot_dir} apt-get -y autoremove

# disable casper-md5check
chroot "$chroot_dir" /bin/bash <<'EOF'
systemctl disable casper-md5check.service 2>/dev/null || true
systemctl mask casper-md5check.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/casper-md5check.service
rm -f /lib/systemd/system/casper-md5check.service
EOF

# Umount the root filesystem
teardown_mountpoint $chroot_dir

# Compress the root filesystem and then build a disk image.  The base tar
# without a board U-Boot is shared; this board tar contains the selected
# mode/key U-Boot deb and must never be reused across modes.
board_rootfs="ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "${board_rootfs}"
cd ${chroot_dir} && tar -cpf "../${board_rootfs}" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "${board_rootfs}"
rm -f "${board_rootfs}"
