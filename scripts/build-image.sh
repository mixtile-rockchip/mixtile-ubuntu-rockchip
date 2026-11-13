#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cleanup_loopdev() {
    local loop="$1"

    sync --file-system
    sync

    sleep 1

    if [ -b "${loop}" ]; then
        for part in "${loop}"p*; do
            if mnt=$(findmnt -n -o target -S "$part"); then
                umount "${mnt}"
            fi
        done
        losetup -d "${loop}"
    fi
}

wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done

    ((++seconds))

    ls -l "${loop}" &> /dev/null
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 filename.rootfs.tar"
    exit 1
fi

rootfs="$(readlink -f "$1")"
if [[ "$(basename "${rootfs}")" != *".rootfs.tar" || ! -e "${rootfs}" ]]; then
    echo "Error: $(basename "${rootfs}") must be a rootfs tarfile"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

if [ -f "../config/boards/${BOARD}.sh" ]; then
    eval "$(bash -c '. "$1"; printf "KERNEL_DTB=%q\nUBOOT_PACKAGE=%q\nSECURE_BOOT_SUPPORTED=%q\n" "$KERNEL_DTB" "$UBOOT_PACKAGE" "$SECURE_BOOT_SUPPORTED"' _ "../config/boards/${BOARD}.sh")"
fi

SECURE="${SECURE_BOOT:-}"
if [ "${SECURE}" = "Y" ]; then
    # shellcheck source=/dev/null
    source ../scripts/secure-boot-common.sh
    [ -n "${SECURE_BOOT_KEY_DIR}" ] || {
        echo "Error: SECURE_BOOT_KEY_DIR is not set" >&2; exit 1; }
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    secure_boot_validate_keys "${SECURE_BOOT_KEY_DIR}" "${repo_root}"
    SECURE_BOOT_KEY_DIR="$(readlink -f -- "${SECURE_BOOT_KEY_DIR}")"
    export SECURE_BOOT_KEY_DIR

    if [ -z "${MKIMAGE}" ] && [ -n "${UBOOT_PACKAGE}" ]; then
        MKIMAGE=$(find "${PWD}" -path "*/${UBOOT_PACKAGE}/debian/build/*/tools/mkimage" -type f 2>/dev/null | head -n 1)
    fi
    if [ -z "${MKIMAGE}" ] || [ ! -x "${MKIMAGE}" ]; then
        echo "Error: no signed mkimage found; build U-Boot first or set MKIMAGE"
        exit 1
    fi
fi

BOOT_PART_MIB="${BOOT_PART_MIB:-128}"
if [ "${SECURE}" = "Y" ]; then
    ROOTFS_START_MIB="$((16 + BOOT_PART_MIB))"
    BOOT_CMDLINE_EXTRA="${BOOT_CMDLINE_EXTRA:-console=ttyS2,1500000 console=tty1}"
else
    ROOTFS_START_MIB=16
fi

img_suffix=""
[ "${SECURE}" = "Y" ] && img_suffix="-secure"
img="../images/$(basename "${rootfs}" .rootfs.tar)${KVER}${img_suffix}.img"
size="$(( $(wc -c < "${rootfs}" ) / 1024 / 1024 ))"
if [ "${SECURE}" = "Y" ]; then
    truncate -s "$(( size + 2048 + BOOT_PART_MIB ))M" "${img}"
else
    truncate -s "$(( size + 2048 ))M" "${img}"
fi

loop="$(losetup -f)"
losetup -P "${loop}" "${img}"
disk="${loop}"

trap 'cleanup_loopdev ${loop}' EXIT

mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

dd if=/dev/zero of="${disk}" count=4096 bs=512
if [ "${SECURE}" = "Y" ]; then
    parted --script "${disk}" \
    mklabel gpt \
    mkpart boot 16MiB "${ROOTFS_START_MIB}MiB" \
    mkpart rootfs "${ROOTFS_START_MIB}MiB" 100%
    rootfs_part=2
else
    parted --script "${disk}" \
    mklabel gpt \
    mkpart primary ext4 16MiB 100%
    {
        echo "t"
        echo "1"
        echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        echo "w"
    } | fdisk "${disk}" &> /dev/null || true
    rootfs_part=1
fi

partprobe "${disk}"
partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"
sleep 1
wait_loopdev "${disk}${partition_char}${rootfs_part}" 60 || {
    echo "Failure to create ${disk}${partition_char}${rootfs_part} in time"
    exit 1
}
sleep 1

root_uuid=$(uuidgen)
dd if=/dev/zero of="${disk}${partition_char}${rootfs_part}" bs=1KB count=10 > /dev/null
mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}${rootfs_part}"

mkdir -p ${mount_point}/writable
mount "${disk}${partition_char}${rootfs_part}" ${mount_point}/writable

tar --xattrs --xattrs-include="*" -xpf "${rootfs}" -C ${mount_point}/writable
echo "# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/writable/etc/fstab
echo "UUID=${root_uuid,,} /              ext4    defaults,x-systemd.growfs    0       1" >> ${mount_point}/writable/etc/fstab

if [ "${SECURE}" = "Y" ]; then
    BOOT_FIT_DIR="${PWD}/boot-fit"
    BOOT_IMG="${BOOT_FIT_DIR}/boot.img"
    rm -rf "${BOOT_FIT_DIR}"
    mkdir -p "${BOOT_FIT_DIR}"

    if [ -z "${KERNEL_DTB}" ]; then
        echo "Error: KERNEL_DTB is not set" >&2
        exit 1
    fi
    BOOT_DTB=$(find "${mount_point}/writable/lib/firmware" "${mount_point}/writable/boot" \
        -type f -name "${KERNEL_DTB}" 2>/dev/null | head -n 1)
    if [ -z "${BOOT_DTB}" ]; then
        echo "Error: ${KERNEL_DTB} not found in rootfs" >&2
        exit 1
    fi

    # Extract the control DTB from the final U-Boot FIT.  Kernel FIT signing
    # and verification use exactly the key carried by the delivered U-Boot
    # FIT, not a standalone DTB that could be modified later.
    UBOOT_ITB="${PWD}/u-boot.itb"
    CONTROL_DTB="${BOOT_FIT_DIR}/u-boot-control.dtb"
    [ -f "${UBOOT_ITB}" ] || { echo "Error: ${UBOOT_ITB} is missing" >&2; exit 1; }
    fdt_pos=$(fdtget -t u "${UBOOT_ITB}" /images/fdt data-position)
    fdt_size=$(fdtget -t u "${UBOOT_ITB}" /images/fdt data-size)
    dd if="${UBOOT_ITB}" of="${CONTROL_DTB}" bs=1 \
        skip="${fdt_pos}" count="${fdt_size}" status=none
    test "$(fdtget -t s "${CONTROL_DTB}" /signature/key-dev required)" = conf

    "../scripts/make-boot-fit.sh" \
        --rootfs "${mount_point}/writable" \
        --root-uuid "${root_uuid,,}" \
        --key-dir "${SECURE_BOOT_KEY_DIR}" \
        --out "${BOOT_IMG}" \
        --dtb "${BOOT_DTB}" \
        --verify-dtb "${CONTROL_DTB}" \
        --cmdline-extra "${BOOT_CMDLINE_EXTRA}" \
        --mkimage "${MKIMAGE}"

    boot_size=$(stat -c %s "${BOOT_IMG}")
    boot_limit=$((BOOT_PART_MIB * 1024 * 1024))
    if [ "${boot_size}" -gt "${boot_limit}" ]; then
        echo "Error: boot.img (${boot_size}) exceeds boot partition (${boot_limit})" >&2
        exit 1
    fi

    dd if="${mount_point}/writable/usr/lib/u-boot/idbloader.img" of="${loop}" seek=64 conv=notrunc
    dd if="${mount_point}/writable/usr/lib/u-boot/u-boot.itb" of="${loop}" seek=16384 conv=notrunc
    dd if="${BOOT_IMG}" of="${disk}${partition_char}1" bs=1M conv=fsync
else
    if [ -f "${mount_point}/writable/usr/lib/u-boot/u-boot-rockchip.bin" ]; then
        dd if="${mount_point}/writable/usr/lib/u-boot/u-boot-rockchip.bin" of="${loop}" seek=1 bs=32k conv=fsync
    else
        dd if="${mount_point}/writable/usr/lib/u-boot/idbloader.img" of="${loop}" seek=64 conv=notrunc
        dd if="${mount_point}/writable/usr/lib/u-boot/u-boot.itb" of="${loop}" seek=16384 conv=notrunc
    fi
    chroot "${mount_point}/writable" u-boot-update
fi

if [[ $(type -t build_image_hook__"${BOARD}") == function ]]; then
    build_image_hook__"${BOARD}"
fi

sync --file-system
sync
umount "${disk}${partition_char}${rootfs_part}" 2> /dev/null || true
losetup -d "${loop}"
trap '' EXIT

echo -e "\nCompressing $(basename "${img}.xz")\n"
xz -6 --force --keep --quiet --threads=0 "${img}"
[ -n "${KEEP_IMAGE}" ] || rm -f "${img}"
cd ../images
sha256sum "$(basename "${img}.xz")" > "$(basename "${img}.xz").sha256"

if [ "${SECURE}" = "Y" ]; then
    for f in idbloader.img u-boot.itb; do
        [ -f "../build/${f}" ] && cp -f "../build/${f}" .
    done
    [ -f ../build/MiniLoaderAll.signed.bin ] && cp -f ../build/MiniLoaderAll.signed.bin .
    [ -f ../build/boot-fit/boot.img ] && cp -f ../build/boot-fit/boot.img .
    [ -f ../build/otp-key-hash.txt ] && cp -f ../build/otp-key-hash.txt .
    artifacts=(idbloader.img u-boot.itb boot.img MiniLoaderAll.signed.bin otp-key-hash.txt)
    present=()
    for f in "${artifacts[@]}"; do
        [ -f "${f}" ] && present+=("${f}")
    done
    [ "${#present[@]}" -eq "${#artifacts[@]}" ] || {
        echo "Error: secure artifact set is incomplete" >&2
        exit 1
    }
    sha256sum "${present[@]}" > secure-artifacts.sha256
fi
