#!/usr/bin/env bash
# Package one verified AArch64 Chromium binary at the guest path used by the
# T490 runner. The base image supplies the shared resources and libraries; this
# archive replaces only /usr/lib/chromium/chromium.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/t490/package_chromium_binary.sh SOURCE OUTPUT_TAR [MANIFEST]

SOURCE       executable AArch64 Chromium binary from a completed Chromium build
OUTPUT_TAR   new tar.gz archive; existing files are never overwritten
MANIFEST     optional new text manifest (default: OUTPUT_TAR.manifest.txt)

The archive contains exactly usr/lib/chromium/chromium so it can be passed as
PKG_TARBALL to t490_round.sh. The manifest records file type, binary SHA-256,
archive SHA-256, size, and the archive member list.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage >&2
    exit 64
fi

source_path="$1"
output_tar="$2"
manifest_path="${3:-${output_tar}.manifest.txt}"

[[ -f "$source_path" ]] || { echo "SOURCE does not exist: $source_path" >&2; exit 66; }
[[ -x "$source_path" ]] || { echo "SOURCE is not executable: $source_path" >&2; exit 66; }
[[ ! -e "$output_tar" ]] || { echo "refusing to overwrite OUTPUT_TAR: $output_tar" >&2; exit 73; }
[[ ! -e "$manifest_path" ]] || { echo "refusing to overwrite MANIFEST: $manifest_path" >&2; exit 73; }

source_type="$(file -b "$source_path")"
case "$source_type" in
    *aarch64*|*AArch64*) ;;
    *) echo "SOURCE is not identified as AArch64: $source_type" >&2; exit 65 ;;
esac

output_dir="$(dirname "$output_tar")"
manifest_dir="$(dirname "$manifest_path")"
mkdir -p "$output_dir" "$manifest_dir"
temp_dir="$(mktemp -d)"
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

install -d -m 0755 "$temp_dir/usr/lib/chromium"
install -m 0755 "$source_path" "$temp_dir/usr/lib/chromium/chromium"
tar -czf "$output_tar" -C "$temp_dir" usr/lib/chromium/chromium
tar -tzf "$output_tar" | grep -qxF 'usr/lib/chromium/chromium'

source_sha="$(sha256sum "$source_path" | awk '{print $1}')"
archive_sha="$(sha256sum "$output_tar" | awk '{print $1}')"
archive_size="$(wc -c < "$output_tar" | tr -d '[:space:]')"
temp_manifest="${manifest_path}.tmp.$$"
{
    echo 'schema=xkernel.chromium-binary-package.v1'
    echo "source=$source_path"
    echo "source_type=$source_type"
    echo "source_sha256=$source_sha"
    echo "guest_path=/usr/lib/chromium/chromium"
    echo "output_tar=$output_tar"
    echo "output_tar_bytes=$archive_size"
    echo "output_tar_sha256=$archive_sha"
    echo 'members_begin'
    tar -tzf "$output_tar"
    echo 'members_end'
} > "$temp_manifest"
mv "$temp_manifest" "$manifest_path"
echo "CHROMIUM_BINARY_PACKAGE_PASS source_sha256=$source_sha archive_sha256=$archive_sha bytes=$archive_size"
