#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

# shellcheck source=/dev/null
source ../scripts/secure-boot-common.sh

SECURE="${SECURE_BOOT:-}"
if [ -n "${BURN_KEY_HASH}" ]; then
    echo "Error: BURN_KEY_HASH is not used; use --secure-boot" >&2
    exit 1
fi

if [ "${SECURE}" = "Y" ]; then
    if [ -z "${SECURE_BOOT_KEY_DIR}" ]; then
        echo "Error: SECURE_BOOT_KEY_DIR is not set" >&2
        exit 1
    fi
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    secure_boot_validate_keys "${SECURE_BOOT_KEY_DIR}" "${repo_root}"
    SECURE_BOOT_KEY_DIR="$(readlink -f -- "${SECURE_BOOT_KEY_DIR}")"
    export SECURE_BOOT_KEY_DIR

    if [ -n "${RKBIN_TOOLS_DIR}" ] && \
       [ -f "$(dirname "${RKBIN_TOOLS_DIR}")/RKBOOT/RK3588MINIALL.ini" ]; then
        RKBIN_DIR="$(readlink -f -- "$(dirname "${RKBIN_TOOLS_DIR}")")"
    fi
    if [ -z "${RKBIN_DIR}" ] || \
       [ ! -f "${RKBIN_DIR}/RKBOOT/RK3588MINIALL.ini" ]; then
        RKBIN_COMMIT=3e288fe814e059dd06833495f845cab04ac20a5c
        if [ ! -d rkbin/.git ]; then
            rm -rf rkbin
            git clone --depth 1 https://github.com/rockchip-linux/rkbin.git rkbin
        fi
        git -C rkbin fetch --depth 1 origin "${RKBIN_COMMIT}"
        git -C rkbin checkout -q FETCH_HEAD
        RKBIN_DIR="$(readlink -f rkbin)"
        RKBIN_TOOLS_DIR="${RKBIN_DIR}/tools"
    fi
    export RKBIN_DIR
    if [ -z "${RKBIN_TOOLS_DIR}" ]; then
        RKBIN_TOOLS_DIR="${RKBIN_DIR}/tools"
    fi
    RKBIN_TOOLS_DIR="$(readlink -f -- "${RKBIN_TOOLS_DIR}")"
    export RKBIN_TOOLS_DIR

    if [ ! -x "${RKBIN_TOOLS_DIR}/rk_sign_tool" ]; then
        echo "Error: rk_sign_tool not found in ${RKBIN_TOOLS_DIR}" >&2
        exit 1
    fi
    if [ ! -f "${RKBIN_DIR}/RKBOOT/RK3588MINIALL.ini" ]; then
        echo "Error: full rkbin tree with RKBOOT/RK3588MINIALL.ini is required" >&2
        echo "Set RKBIN_DIR or RKBIN_TOOLS_DIR to a full rkbin checkout" >&2
        exit 1
    fi
    if grep -Eq '^[[:space:]]*sign_flag[[:space:]]*=[[:space:]]*0x20' "${RKBIN_TOOLS_DIR}/setting.ini"; then
        echo "Error: sign_flag=0x20 is enabled in ${RKBIN_TOOLS_DIR}/setting.ini" >&2
        echo "FIT secure boot must not enable the legacy sign_flag" >&2
        exit 1
    fi
else
    unset SECURE_BOOT_KEY_DIR RKBIN_DIR RKBIN_TOOLS_DIR
fi

if [[ -z ${UBOOT_PACKAGE} ]]; then
    echo "Error: UBOOT_PACKAGE is not set"
    exit 1
fi

# Refresh the U-Boot tree from the pinned upstream commit and copy the current
# packaging in.  This removes old patches, old debian/rules and DTBs modified
# by a previous mkimage -K run.
if [ -d "${UBOOT_PACKAGE}" ] && git -C "${UBOOT_PACKAGE}" rev-parse --git-dir >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source ../packages/"${UBOOT_PACKAGE}"/debian/upstream
    git -C "${UBOOT_PACKAGE}" reset --hard "${COMMIT}"
    git -C "${UBOOT_PACKAGE}" clean -fdx
else
    rm -rf "${UBOOT_PACKAGE}"
    # shellcheck source=/dev/null
    source ../packages/"${UBOOT_PACKAGE}"/debian/upstream
    git clone --single-branch --progress -b "${BRANCH}" "${GIT}" "${UBOOT_PACKAGE}"
    git -C "${UBOOT_PACKAGE}" checkout "${COMMIT}"
fi
cp -r ../packages/"${UBOOT_PACKAGE}"/debian "${UBOOT_PACKAGE}"/
cd "${UBOOT_PACKAGE}"

# Target package to build.
rules=${UBOOT_RULES_TARGET},package-${UBOOT_RULES_TARGET}
if [[ -n ${UBOOT_RULES_TARGET_EXTRA} ]]; then
    rules=${UBOOT_RULES_TARGET_EXTRA},${rules}
fi

if [ "${SECURE}" = "Y" ]; then
    export SECURE_BOOT=1
else
    unset SECURE_BOOT
fi

rm -f ../u-boot-"${BOARD:-${UBOOT_PACKAGE}}"_*.deb ../idbloader.img ../u-boot.itb \
      ../rkspi_loader.img ../MiniLoaderAll.signed.bin ../otp-key-hash.txt

dpkg-source --before-build .
dpkg-buildpackage -a "$(cat debian/arch)" -d -b -nc -uc --rules-target="${rules}"
# Keep the patched helper header available for the host-side test even if
# dpkg-source unapplies the patch below.
cp -f include/otp-key-hash.h ../otp-key-hash.h 2>/dev/null || true
dpkg-source --after-build .

rm -f ../*.buildinfo ../*.changes

builddir="debian/build/${UBOOT_RULES_TARGET}"
[ -d "${builddir}" ] || { echo "Error: U-Boot build directory missing: ${builddir}" >&2; exit 1; }

for f in idbloader.img u-boot.itb rkspi_loader.img; do
    [ -f "${builddir}/${f}" ] || { echo "Error: missing ${builddir}/${f}" >&2; exit 1; }
    cp -f "${builddir}/${f}" "../${f}"
done

uboot_deb="$(find .. -maxdepth 1 -name "u-boot-${BOARD:-${UBOOT_PACKAGE}}_*.deb" -type f | sort | tail -n1)"
[ -n "${uboot_deb}" ] || { echo "Error: U-Boot deb was not created" >&2; exit 1; }

if [ "${SECURE}" = "Y" ]; then
    config="${builddir}/.config"
    for opt in CONFIG_FIT_SIGNATURE CONFIG_SPL_FIT_SIGNATURE CONFIG_SPL_ROCKCHIP_SECURE_OTP; do
        grep -q "^${opt}=y" "${config}" || { echo "Error: ${opt} is not enabled" >&2; exit 1; }
    done
    test "$(fdtget -t s "${builddir}/u-boot.dtb" /signature/key-dev required)" = conf
    test "$(fdtget -t s "${builddir}/spl/u-boot-spl.dtb" /signature/key-dev required)" = conf
    if fdtget -t x "${builddir}/u-boot.dtb" /signature/key-dev burn-key-hash >/dev/null 2>&1; then
        echo "Error: burn-key-hash must not be set in u-boot.dtb" >&2
        exit 1
    fi
    test "$(fdtget -t x "${builddir}/spl/u-boot-spl.dtb" /signature/key-dev burn-key-hash)" = 1 || {
        echo "Error: burn-key-hash must be set in the boot SPL DTB" >&2
        exit 1
    }
    "${builddir}/tools/fit_check_sign" -f "${builddir}/u-boot.itb" \
        -k "${builddir}/spl/u-boot-spl.dtb" -s
    # Verify the control DTB that actually shipped inside the final idblock,
    # not only the standalone build-tree DTB.
    secure_boot_extract_last_dtb ../idbloader.img ../idbloader-spl.dtb || {
        echo "Error: cannot extract SPL DTB from final idbloader" >&2; exit 1; }
    cmp -s ../idbloader-spl.dtb "${builddir}/spl/u-boot-spl.dtb" || {
        echo "Error: final idblock SPL DTB differs from the signed SPL DTB" >&2; exit 1; }
    "${builddir}/tools/fit_check_sign" -f ../u-boot.itb \
        -k ../idbloader-spl.dtb -s
    [ -f "${builddir}/MiniLoaderAll.signed.bin" ] || {
        echo "Error: signed USB loader was not generated" >&2; exit 1; }
    cp -f "${builddir}/MiniLoaderAll.signed.bin" ../MiniLoaderAll.signed.bin

    otp_node=hash@np
    if grep -q '^CONFIG_ROCKCHIP_CRYPTO_V1=y' "${builddir}/.config"; then
        otp_node=hash@c
    fi
    otp_hash="$(secure_boot_otp_hash "${builddir}/spl/u-boot-spl.dtb" "${otp_node}")" || {
        echo "Error: cannot read OTP key hash from SPL DTB" >&2; exit 1; }
    printf '%s\n' "${otp_hash}" > ../otp-key-hash.txt
    key_id="$(secure_boot_key_id "${SECURE_BOOT_KEY_DIR}")"
    uboot_inputs="$(secure_boot_packaging_hash "../../packages/${UBOOT_PACKAGE}" "${COMMIT}")"
    secure_boot_stamp_write "../secureboot-${BOARD:-${UBOOT_PACKAGE}}.stamp" secure \
        "${key_id}" "${otp_hash}" "${uboot_inputs}" \
        "$(basename "${uboot_deb}")" "$(secure_boot_file_sha256 "${uboot_deb}")" \
        "$(secure_boot_file_sha256 ../idbloader.img)" \
        "$(secure_boot_file_sha256 ../u-boot.itb)" \
        "$(secure_boot_file_sha256 ../MiniLoaderAll.signed.bin)"
else
    config="${builddir}/.config"
    if grep -q '^CONFIG_FIT_SIGNATURE=y' "${config}"; then
        echo "Error: normal build retained CONFIG_FIT_SIGNATURE" >&2
        exit 1
    fi
    if grep -q '^CONFIG_SPL_FIT_SIGNATURE=y' "${config}"; then
        echo "Error: normal build retained CONFIG_SPL_FIT_SIGNATURE" >&2
        exit 1
    fi
    for dtb in "${builddir}/u-boot.dtb" "${builddir}/spl/u-boot-spl.dtb"; do
        if fdtget -l "${dtb}" /signature >/dev/null 2>&1; then
            echo "Error: normal build DTB has a signature node: ${dtb}" >&2
            exit 1
        fi
    done
    if fdtget -t x "${builddir}/spl/u-boot-spl.dtb" /signature/key-dev burn-key-hash >/dev/null 2>&1; then
        echo "Error: normal build SPL DTB has burn-key-hash" >&2
        exit 1
    fi
    uboot_inputs="$(secure_boot_packaging_hash "../../packages/${UBOOT_PACKAGE}" "${COMMIT}")"
    secure_boot_stamp_write "../secureboot-${BOARD:-${UBOOT_PACKAGE}}.stamp" normal \
        "" "" "${uboot_inputs}" "$(basename "${uboot_deb}")" "$(secure_boot_file_sha256 "${uboot_deb}")" \
        "$(secure_boot_file_sha256 ../idbloader.img)" \
        "$(secure_boot_file_sha256 ../u-boot.itb)" ""
fi
