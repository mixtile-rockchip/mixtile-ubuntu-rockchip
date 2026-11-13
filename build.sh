#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")"

usage() {
cat << HEREDOC
Usage: $0 --board=[orangepi-5] --suite=[jammy|noble] --flavor=[server|desktop]

Required arguments:
  -b, --board=BOARD      target board
  -s, --suite=SUITE      ubuntu suite
  -f, --flavor=FLAVOR    ubuntu flavor

Optional arguments:
  -h,  --help            show this help message and exit
  -c,  --clean           clean the build directory
  -ko, --kernel-only     only compile the kernel
  -uo, --uboot-only      only compile uboot
  -ro, --rootfs-only     only build rootfs
  -l,  --launchpad       use kernel and uboot from launchpad repo
  -k,  --key-dir=DIR     secure boot key directory (dev.key/dev.pubkey/dev.crt)
      --secure-boot      build the complete signed boot chain
  -v,  --verbose         increase the verbosity of the bash script

Secure boot key directory must be outside the repository.  Without
--secure-boot no key is read and the loader is not signed.
HEREDOC
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")"

while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help)
            usage
            exit 0
            ;;
        -b=*|--board=*)
            export BOARD="${1#*=}"
            shift
            ;;
        -b|--board)
            export BOARD="${2}"
            shift 2
            ;;
        -s=*|--suite=*)
            export SUITE="${1#*=}"
            shift
            ;;
        -s|--suite)
            export SUITE="${2}"
            shift 2
            ;;
        -f=*|--flavor=*)
            export FLAVOR="${1#*=}"
            shift
            ;;
        -f|--flavor)
            export FLAVOR="${2}"
            shift 2
            ;;
        -ko|--kernel-only)
            export KERNEL_ONLY=Y
            shift
            ;;
        -uo|--uboot-only)
            export UBOOT_ONLY=Y
            shift
            ;;
        -ro|--rootfs-only)
            export ROOTFS_ONLY=Y
            shift
            ;;
        -l|--launchpad)
            export LAUNCHPAD=Y
            shift
            ;;
        -k=*|--key-dir=*)
            export SECURE_BOOT_KEY_DIR="${1#*=}"
            export KEY_DIR_OPT=Y
            shift
            ;;
        -k|--key-dir)
            export SECURE_BOOT_KEY_DIR="${2}"
            export KEY_DIR_OPT=Y
            shift 2
            ;;
        --secure-boot)
            export SECURE_BOOT=Y
            shift
            ;;
        -c|--clean)
            export CLEAN=Y
            shift
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        -*)
            echo "Error: unknown argument \"${1}\""
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "${BURN_KEY_HASH}" ]; then
    echo "Error: BURN_KEY_HASH is not used; OTP provisioning is not part of this build" >&2
    exit 1
fi

if [ "${KEY_DIR_OPT}" = "Y" ] && [ "${SECURE_BOOT}" != "Y" ]; then
    echo "Error: --key-dir requires --secure-boot" >&2
    exit 1
fi

if [ "${SUITE}" == "help" ]; then
    for file in config/suites/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${SUITE}" ]; then
    while :; do
        for file in config/suites/*; do
            if [ "${SUITE}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${SUITE}\" is an unsupported suite"
        exit 1
    done
fi

if [ "${FLAVOR}" == "help" ]; then
    for file in config/flavors/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${FLAVOR}" ]; then
    while :; do
        for file in config/flavors/*; do
            if [ "${FLAVOR}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${FLAVOR}\" is an unsupported flavor"
        exit 1
    done
fi

if [ "${BOARD}" == "help" ]; then
    for file in config/boards/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${BOARD}" ]; then
    while :; do
        for file in config/boards/*; do
            if [ "${BOARD}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${BOARD}\" is an unsupported board"
        exit 1
    done
fi

if [ "${CLEAN}" == "Y" ]; then
    if [ -d build/rootfs ]; then
        umount -lf build/rootfs/dev/pts 2> /dev/null || true
        umount -lf build/rootfs/* 2> /dev/null || true
    fi
    rm -rf build
fi

mkdir -p build/logs && exec > >(tee "build/logs/build-$(date +"%Y%m%d%H%M%S").log") 2>&1

# shellcheck source=/dev/null
source scripts/secure-boot-common.sh

# These stages do not consume a key and do not produce boot-chain artifacts.
if [ "${KERNEL_ONLY}" == "Y" ]; then
    if [ -z "${SUITE}" ]; then
        usage
        exit 1
    fi
    [ "${SECURE_BOOT}" != "Y" ] || \
        echo "Warning: --kernel-only does not build the signed boot chain" >&2
    ./scripts/build-kernel.sh
    exit 0
fi

if [ "${ROOTFS_ONLY}" == "Y" ]; then
    if [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; then
        usage
        exit 1
    fi
    [ "${SECURE_BOOT}" != "Y" ] || \
        echo "Warning: --rootfs-only does not build the signed boot chain" >&2
    ./scripts/build-rootfs.sh
    exit 0
fi

# U-Boot-only and complete builds need a board.  Secure ones also need a key.
if [ "${UBOOT_ONLY}" == "Y" ] && [ -z "${BOARD}" ]; then
    usage
    exit 1
fi
if [ "${UBOOT_ONLY}" != "Y" ]; then
    if [ -z "${BOARD}" ] || [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; then
        usage
        exit 1
    fi
fi

if [ "${SECURE_BOOT}" == "Y" ]; then
    # shellcheck source=/dev/null
    source scripts/secure-boot-common.sh

    if [ -z "${SECURE_BOOT_KEY_DIR}" ]; then
        echo "Error: --secure-boot requires --key-dir DIR or SECURE_BOOT_KEY_DIR" >&2
        exit 1
    fi
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    secure_boot_validate_keys "${SECURE_BOOT_KEY_DIR}" "${repo_root}"
    SECURE_BOOT_KEY_DIR="$(readlink -f -- "${SECURE_BOOT_KEY_DIR}")"
    export SECURE_BOOT_KEY_DIR

    if [ "${SECURE_BOOT_SUPPORTED}" != "Y" ]; then
        echo "Error: board ${BOARD} does not enable secure boot" >&2
        exit 1
    fi
    if [ "${LAUNCHPAD}" = "Y" ] && [ "${UBOOT_ONLY}" != "Y" ]; then
        echo "Error: --launchpad U-Boot is not signed; secure boot requires a local build" >&2
        exit 1
    fi
else
    # Normal builds must not accidentally consume secure-mode state.
    unset SECURE_BOOT SECURE_BOOT_KEY_DIR
fi

if [ "${UBOOT_ONLY}" == "Y" ]; then
    ./scripts/build-u-boot.sh
    exit 0
fi

# Build the Linux kernel if not found.
if [[ ${LAUNCHPAD} != "Y" ]]; then
    if [[ ! -e "$(find build/linux-image-*.deb | sort | tail -n1)" || ! -e "$(find build/linux-headers-*.deb | sort | tail -n1)" ]]; then
        ./scripts/build-kernel.sh
    fi
fi

# Build U-Boot if missing, built for the other mode, signed with another key,
# or if its packaging inputs changed.
if [[ ${LAUNCHPAD} != "Y" ]]; then
    # shellcheck source=/dev/null
    source "packages/${UBOOT_PACKAGE}/debian/upstream"
    uboot_inputs="$(secure_boot_packaging_hash "packages/${UBOOT_PACKAGE}" "${COMMIT}")"
    uboot_deb="$(find build/u-boot-"${BOARD}"_*.deb 2>/dev/null | sort | tail -n1)"
    uboot_stamp="build/secureboot-${BOARD}.stamp"
    expected_mode="normal"
    expected_key_id=""
    if [ "${SECURE_BOOT}" = "Y" ]; then
        expected_mode="secure"
        expected_key_id="$(secure_boot_key_id "${SECURE_BOOT_KEY_DIR}")"
    fi

    stamp_mode="$(secure_boot_stamp_get "${uboot_stamp}" mode || true)"
    stamp_key="$(secure_boot_stamp_get "${uboot_stamp}" key_id || true)"
    stamp_inputs="$(secure_boot_stamp_get "${uboot_stamp}" uboot_inputs || true)"

    if [ -z "${uboot_deb}" ] || [ ! -f "${uboot_stamp}" ] || \
       [ "${stamp_mode}" != "${expected_mode}" ] || \
       [ "${stamp_key}" != "${expected_key_id}" ] || \
       [ "${stamp_inputs}" != "${uboot_inputs}" ]; then
        ./scripts/build-u-boot.sh
    fi
fi

# Create the root filesystem.
./scripts/build-rootfs.sh

# Create the disk image.
./scripts/config-image.sh

exit 0
