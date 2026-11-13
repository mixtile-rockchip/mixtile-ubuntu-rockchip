#!/bin/bash

# Build and sign the kernel/DTB/initramfs/bootargs FIT.
# bootargs is a signed firmware node consumed by board_fit_image_post_process().

set -eE
trap 'echo "Error: in $0 on line $LINENO" >&2' ERR

usage() {
    cat <<'EOF'
Usage: make-boot-fit.sh --root-uuid UUID --dtb FILE --key-dir DIR --out FILE [options]

Required:
  --root-uuid UUID        Root filesystem UUID (without the UUID= prefix)
  --dtb FILE              Device tree blob
  --key-dir DIR           Directory with dev.key, dev.pubkey and dev.crt
  --out FILE              Output signed FIT (boot.img)

Optional:
  --rootfs DIR            Mounted root filesystem used to locate kernel/initrd
  --kernel FILE           Kernel image (default: newest /boot/vmlinuz-*)
  --initrd FILE           Initramfs (default: newest /boot/initrd.img-*)
  --cmdline-extra STRING  Extra kernel arguments appended to the secure defaults
  --description STRING    FIT description (default: Linux boot FIT)
  --mkimage FILE          mkimage with FIT signing support
  --verify-dtb FILE       control DTB used to verify the signed FIT
  --workdir DIR           Working directory (default: mktemp -d)
  --keep                  Keep the working directory
  -h, --help              Show this help

The generated command line is:
  root=UUID=<UUID> rootwait rw <cmdline-extra>
EOF
}

ROOTFS=
ROOT_UUID=
KEY_DIR=
OUT=
KERNEL=
DTB=
INITRD=
CMDLINE_EXTRA=
DESCRIPTION="${DESCRIPTION:-Linux boot FIT}"
MKIMAGE=${MKIMAGE:-mkimage}
VERIFY_DTB=
WORKDIR=
KEEP=

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)        ROOTFS=$2; shift 2 ;;
        --root-uuid)     ROOT_UUID=$2; shift 2 ;;
        --key-dir)       KEY_DIR=$2; shift 2 ;;
        --out)           OUT=$2; shift 2 ;;
        --kernel)        KERNEL=$2; shift 2 ;;
        --dtb)           DTB=$2; shift 2 ;;
        --initrd)        INITRD=$2; shift 2 ;;
        --cmdline-extra) CMDLINE_EXTRA=$2; shift 2 ;;
        --description)   DESCRIPTION=$2; shift 2 ;;
        --mkimage)       MKIMAGE=$2; shift 2 ;;
        --verify-dtb)    VERIFY_DTB=$2; shift 2 ;;
        --workdir)       WORKDIR=$2; shift 2 ;;
        --keep)          KEEP=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "${ROOT_UUID}" ] || [ -z "${DTB}" ] || [ -z "${KEY_DIR}" ] || [ -z "${OUT}" ]; then
    usage >&2
    exit 1
fi

for f in dev.key dev.pubkey dev.crt; do
    if [ ! -f "${KEY_DIR}/${f}" ]; then
        echo "Missing ${KEY_DIR}/${f}" >&2
        exit 1
    fi
done

if [ ! -x "${MKIMAGE}" ] && ! command -v "${MKIMAGE}" >/dev/null 2>&1; then
    echo "mkimage not executable: ${MKIMAGE}" >&2
    exit 1
fi
MKIMAGE=$(command -v "${MKIMAGE}")
case "${MKIMAGE}" in
    /*) ;;
    *) MKIMAGE="$(cd "$(dirname "${MKIMAGE}")" && pwd)/$(basename "${MKIMAGE}")" ;;
esac

# Resolve paths before changing into the working directory.
case "${KEY_DIR}" in
    /*) ;;
    *) KEY_DIR="$(cd "${KEY_DIR}" && pwd)" ;;
esac
OUT_DIR=$(dirname "${OUT}")
mkdir -p "${OUT_DIR}"
OUT="$(cd "${OUT_DIR}" && pwd)/$(basename "${OUT}")"

find_newest() {
    local dir=$1 pattern=$2
    [ -d "${dir}" ] || return 0
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" 2>/dev/null \
        | sort -V | tail -n 1
}

if [ -z "${KERNEL}" ] && [ -n "${ROOTFS}" ]; then
    KERNEL=$(find_newest "${ROOTFS}/boot" 'vmlinuz-*')
    [ -n "${KERNEL}" ] || KERNEL=$(find_newest "${ROOTFS}/boot" 'Image')
fi

if [ -z "${INITRD}" ] && [ -n "${ROOTFS}" ]; then
    INITRD=$(find_newest "${ROOTFS}/boot" 'initrd.img-*')
fi

for pair in "kernel:${KERNEL}" "dtb:${DTB}" "initrd:${INITRD}"; do
    name=${pair%%:*}
    value=${pair#*:}
    if [ -z "${value}" ] || [ ! -f "${value}" ]; then
        echo "Could not locate ${name}; pass --${name} explicitly" >&2
        exit 1
    fi
done

if [ -z "${WORKDIR}" ]; then
    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/boot-fit.XXXXXX")
    [ -n "${KEEP}" ] || trap 'rm -rf "${WORKDIR}"' EXIT
fi
mkdir -p "${WORKDIR}"

# mkimage resolves /incbin/ paths from the working directory.
cp -f "${KERNEL}" "${WORKDIR}/kernel.bin"
cp -f "${DTB}" "${WORKDIR}/fdt.dtb"
cp -f "${INITRD}" "${WORKDIR}/ramdisk.bin"

CMDLINE="root=UUID=${ROOT_UUID} rootwait rw"
if [ -n "${CMDLINE_EXTRA}" ]; then
    CMDLINE="${CMDLINE} ${CMDLINE_EXTRA}"
fi
# NUL-terminate: board_fit_image_post_process() uses strcat() on the data.
printf '%s\0' "${CMDLINE}" > "${WORKDIR}/cmdline.bin"

KERNEL_MAGIC=$(od -An -tx1 -N2 "${WORKDIR}/kernel.bin" | tr -d ' \n')
case "${KERNEL_MAGIC}" in
    1f8b) KERNEL_COMPRESSION=gzip ;;
    *)    KERNEL_COMPRESSION=none ;;
esac

# bootargs load=0: fit_image_get_load() needs the property, but data must not move.
cat > "${WORKDIR}/boot.its" <<EOF
/dts-v1/;

/ {
    description = "${DESCRIPTION}";
    #address-cells = <1>;

    images {
        kernel {
            data = /incbin/("kernel.bin");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "${KERNEL_COMPRESSION}";
            load = <0x00400000>;
            entry = <0x00400000>;
            hash { algo = "sha256"; };
        };

        fdt {
            data = /incbin/("fdt.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            load = <0x08300000>;
            hash { algo = "sha256"; };
        };

        bootargs {
            data = /incbin/("cmdline.bin");
            type = "firmware";
            arch = "arm64";
            compression = "none";
            load = <0x0>;
            hash { algo = "sha256"; };
        };

        ramdisk {
            data = /incbin/("ramdisk.bin");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x0a200000>;
            hash { algo = "sha256"; };
        };
    };

    configurations {
        default = "conf";
        conf {
            description = "${DESCRIPTION}";
            kernel = "kernel";
            fdt = "fdt";
            ramdisk = "ramdisk";
            loadables = "bootargs";
            signature {
                algo = "sha256,rsa2048";
                key-name-hint = "dev";
                sign-images = "kernel", "fdt", "ramdisk", "loadables";
            };
        };
    };
};
EOF

(
    cd "${WORKDIR}"
    "${MKIMAGE}" -f boot.its -k "${KEY_DIR}" -E -p 0x1000 -r "${OUT}"
)

if [ -n "${VERIFY_DTB}" ]; then
    CHECK_SIGN="$(dirname "${MKIMAGE}")/fit_check_sign"
    if [ ! -x "${CHECK_SIGN}" ]; then
        echo "fit_check_sign not found next to ${MKIMAGE}" >&2
        exit 1
    fi
    "${CHECK_SIGN}" -f "${OUT}" -k "${VERIFY_DTB}"
fi

# Verify bootargs is inside fit_image_load_bootables()'s contiguous read range.
fit_size_hex=$(od -An -tx1 -j4 -N4 "${OUT}" | tr -d ' \n')
fit_size=$((16#${fit_size_hex}))
max_end=0
for img in kernel fdt ramdisk; do
    pos=$(fdtget -t u "${OUT}" "/images/${img}" data-position)
    size=$(fdtget -t u "${OUT}" "/images/${img}" data-size)
    end=$((pos - fit_size + size))
    if [ "${end}" -gt "${max_end}" ]; then max_end=${end}; fi
done
loaded=$(( ((fit_size + 511) / 512) * 512 + max_end ))
bpos=$(fdtget -t u "${OUT}" /images/bootargs data-position)
bsize=$(fdtget -t u "${OUT}" /images/bootargs data-size)
bload=$(fdtget -t u "${OUT}" /images/bootargs load)
if [ "${bload}" -ne 0 ] || [ $((bpos + bsize)) -gt "${loaded}" ]; then
    echo "Error: bootargs is outside the FIT load range" >&2
    exit 1
fi

echo "Signed boot FIT: ${OUT}"
echo "  root UUID:     ${ROOT_UUID}"
echo "  cmdline:       ${CMDLINE}"
echo "  kernel:        ${KERNEL} (compression=${KERNEL_COMPRESSION})"
echo "  dtb:           ${DTB}"
echo "  initrd:        ${INITRD}"
echo "  sha256:        $(sha256sum "${OUT}" | awk '{print $1}')"
