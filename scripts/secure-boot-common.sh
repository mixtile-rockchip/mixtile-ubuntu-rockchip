#!/bin/bash
# Secure boot helpers shared by build.sh, build-u-boot.sh and config-image.sh.
# Sourced, not executed.

secure_boot_die()
{
    echo "Error: $*" >&2
    exit 1
}

secure_boot_validate_keys()
{
    local keydir="$1"
    local repo_root="$2"
    local tmp
    local f

    [ -n "${keydir}" ] || secure_boot_die "secure boot key directory is not set"
    [ -d "${keydir}" ] || secure_boot_die "secure boot key directory not found: ${keydir}"
    keydir="$(readlink -f -- "${keydir}")"

    for f in dev.key dev.pubkey dev.crt; do
        [ -f "${keydir}/${f}" ] || secure_boot_die "missing ${keydir}/${f}"
    done

    if [ -n "${repo_root}" ]; then
        case "${keydir}/" in
            "${repo_root}/"*) secure_boot_die "key directory must be outside the repository" ;;
        esac
    fi

    command -v openssl >/dev/null 2>&1 || secure_boot_die "openssl is required"

    tmp="$(mktemp -d)"
    if ! openssl pkey -in "${keydir}/dev.key" -pubout -out "${tmp}/key.pub" 2>/dev/null; then
        rm -rf "${tmp}"
        secure_boot_die "cannot read private key ${keydir}/dev.key"
    fi
    if ! openssl pkey -pubin -in "${keydir}/dev.pubkey" -out "${tmp}/pub.pub" 2>/dev/null; then
        rm -rf "${tmp}"
        secure_boot_die "cannot read public key ${keydir}/dev.pubkey"
    fi
    if ! cmp -s "${tmp}/key.pub" "${tmp}/pub.pub"; then
        rm -rf "${tmp}"
        secure_boot_die "dev.key and dev.pubkey do not match"
    fi
    if ! openssl x509 -in "${keydir}/dev.crt" -pubkey -noout > "${tmp}/crt.pem" 2>/dev/null; then
        rm -rf "${tmp}"
        secure_boot_die "cannot read certificate ${keydir}/dev.crt"
    fi
    if ! openssl pkey -pubin -in "${tmp}/crt.pem" -out "${tmp}/crt.pub" 2>/dev/null; then
        rm -rf "${tmp}"
        secure_boot_die "cannot parse public key from ${keydir}/dev.crt"
    fi
    if ! cmp -s "${tmp}/key.pub" "${tmp}/crt.pub"; then
        rm -rf "${tmp}"
        secure_boot_die "dev.key and dev.crt do not match"
    fi
    if ! openssl pkey -in "${keydir}/dev.key" -text -noout 2>/dev/null | grep -q '2048 bit'; then
        rm -rf "${tmp}"
        secure_boot_die "dev.key is not an RSA-2048 key"
    fi

    rm -rf "${tmp}"
    SECURE_BOOT_KEY_DIR="${keydir}"
    export SECURE_BOOT_KEY_DIR
}

secure_boot_key_id()
{
    local keydir="$1"

    [ -d "${keydir}" ] || return 1
    (
        cd "${keydir}" || exit 1
        sha256sum dev.key dev.pubkey dev.crt
    ) | sha256sum | awk '{ print $1 }'
}

secure_boot_packaging_hash()
{
    local package_dir="$1"
    local commit="$2"

    {
        find "${package_dir}/debian" -type f -print0 | sort -z | xargs -0 sha256sum
        printf 'upstream-commit=%s\n' "${commit}"
    } | sha256sum | awk '{ print $1 }'
}

secure_boot_otp_hash()
{
    local dtb="$1"
    local node="${2:-hash@np}"
    local raw
    local word
    local out=""

    [ -f "${dtb}" ] || return 1
    raw="$(fdtget -t x "${dtb}" "/signature/key-dev/${node}" value 2>/dev/null)" || return 1
    out="$(python3 -c 'import sys; print("".join("%08x" % int(w, 16) for w in " ".join(sys.argv[1:]).split()))' "${raw}")" || return 1
    [ "${#out}" -eq 64 ] || return 1
    printf '%s\n' "${out}"
}

secure_boot_stamp_get()
{
    local stamp="$1"
    local key="$2"

    [ -f "${stamp}" ] || return 1
    awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${stamp}"
}

secure_boot_stamp_write()
{
    local stamp="$1"
    local mode="$2"
    local key_id="$3"
    local otp_hash="$4"
    local uboot_inputs="$5"
    local uboot_deb="$6"
    local uboot_deb_sha256="$7"
    local idbloader="$8"
    local uboot_itb="$9"
    local mini_loader="${10}"
    local tmp="${stamp}.tmp"

    mkdir -p "$(dirname "${stamp}")"
    {
        echo "mode=${mode}"
        echo "key_id=${key_id}"
        echo "otp_hash=${otp_hash}"
        echo "uboot_inputs=${uboot_inputs}"
        echo "uboot_deb=${uboot_deb}"
        echo "uboot_deb_sha256=${uboot_deb_sha256}"
        echo "idbloader_sha256=${idbloader}"
        echo "uboot_itb_sha256=${uboot_itb}"
        echo "mini_loader_sha256=${mini_loader}"
    } > "${tmp}"
    mv "${tmp}" "${stamp}"
}

secure_boot_file_sha256()
{
    [ -f "$1" ] && sha256sum "$1" | awk '{ print $1 }'
}

# Extract the final SPL control DTB appended to an idblock/loader image.
# The last DTB magic is used, which is the SPL DTB after the SPL payload.
secure_boot_extract_last_dtb()
{
    local image="$1"
    local out="$2"

    [ -f "${image}" ] || return 1
    python3 - "${image}" "${out}" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
magic = b"\xd0\x0d\xfe\xed"
pos = data.rfind(magic)
if pos < 0:
    raise SystemExit(1)
size = int.from_bytes(data[pos + 4:pos + 8], "big")
if size <= 16 or pos + size > len(data):
    raise SystemExit(1)
open(dst, "wb").write(data[pos:pos + size])
PY
    fdtget -l "${out}" /signature >/dev/null 2>&1
}
