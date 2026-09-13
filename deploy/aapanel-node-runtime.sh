#!/usr/bin/env bash
set -Eeuo pipefail

# Installs an isolated Node.js runtime for SITA. aaPanel's global Node runtime
# remains untouched, so other websites keep their existing version and PATH.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_FILE="${AAPANEL_PROFILE_FILE:-${PROJECT_ROOT}/deploy/aapanel-profile.env}"
NODE_MAJOR="${SITA_NODE_MAJOR:-22}"
INSTALL_ROOT="${SITA_NODE_INSTALL_ROOT:-/opt/sita/node}"

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
}

ok() {
    printf '[OK] %s\n' "$*"
}

for command in curl sha256sum tar awk; do
    command -v "$command" >/dev/null 2>&1 || { fail "Command wajib tidak tersedia: ${command}"; exit 1; }
done

if [ ! -f "$PROFILE_FILE" ]; then
    fail "Profile tidak ditemukan: ${PROFILE_FILE}"
    exit 2
fi

case "$(uname -m)" in
    x86_64) node_arch='x64' ;;
    aarch64|arm64) node_arch='arm64' ;;
    *) fail "Arsitektur server belum didukung untuk Node otomatis: $(uname -m)"; exit 1 ;;
esac

temporary_directory="$(mktemp -d /tmp/sita-node-runtime.XXXXXX)"
cleanup() { rm -rf -- "$temporary_directory"; }
trap cleanup EXIT

printf 'Mencari Node.js %s LTS terbaru dari nodejs.org...\n' "$NODE_MAJOR"
curl -fsSL --retry 3 --connect-timeout 10 https://nodejs.org/dist/index.tab -o "$temporary_directory/index.tab"
node_version="$(awk -F $'\t' -v prefix="v${NODE_MAJOR}." '$1 ~ ("^" prefix) { print $1; exit }' "$temporary_directory/index.tab")"
[ -n "$node_version" ] || { fail "Node.js major ${NODE_MAJOR} tidak ditemukan pada index resmi."; exit 1; }

archive="node-${node_version}-linux-${node_arch}.tar.xz"
base_url="https://nodejs.org/dist/${node_version}"
curl -fsSL --retry 3 --connect-timeout 10 "${base_url}/SHASUMS256.txt" -o "$temporary_directory/SHASUMS256.txt"
expected_checksum="$(awk -v archive="$archive" '$2 == archive { print $1; exit }' "$temporary_directory/SHASUMS256.txt")"
[ -n "$expected_checksum" ] || { fail "Checksum resmi tidak ditemukan untuk ${archive}"; exit 1; }

printf 'Mengunduh %s dan memverifikasi checksum...\n' "$archive"
curl -fsSL --retry 3 --connect-timeout 10 "${base_url}/${archive}" -o "$temporary_directory/$archive"
actual_checksum="$(sha256sum "$temporary_directory/$archive" | awk '{print $1}')"
[ "$actual_checksum" = "$expected_checksum" ] || { fail 'Checksum Node.js tidak sesuai; instalasi dibatalkan.'; exit 1; }

tar -xJf "$temporary_directory/$archive" -C "$temporary_directory"
extracted_directory="$temporary_directory/node-${node_version}-linux-${node_arch}"
[ -x "$extracted_directory/bin/node" ] || { fail 'Arsip Node.js tidak memiliki binary node yang diharapkan.'; exit 1; }

target_directory="${INSTALL_ROOT}/${node_version}"
run_privileged install -d -m 755 -o root -g root "$INSTALL_ROOT"
if [ ! -d "$target_directory" ]; then
    run_privileged mv "$extracted_directory" "$target_directory"
    run_privileged chown -R root:root "$target_directory"
    run_privileged chmod -R a+rX "$target_directory"
fi
run_privileged ln -sfn "$target_directory" "${INSTALL_ROOT}/current"

node_binary="${INSTALL_ROOT}/current/bin/node"
npm_binary="${INSTALL_ROOT}/current/bin/npm"
"$node_binary" -e '
    const [major, minor] = process.versions.node.split(".").map(Number);
    process.exit(major === 22 && minor >= 12 ? 0 : 1);
' || { fail "Node hasil instalasi tidak memenuhi minimal 22.12: $($node_binary --version)"; exit 1; }
"$npm_binary" --version >/dev/null

profile_tmp="$(mktemp "${PROJECT_ROOT}/deploy/.aapanel-profile.tmp.XXXXXX")"
awk -v node_bin="$node_binary" -v npm_bin="$npm_binary" '
    index($0, "NODE_BIN=") == 1 { print "NODE_BIN=" node_bin; node_seen=1; next }
    index($0, "NPM_BIN=") == 1 { print "NPM_BIN=" npm_bin; npm_seen=1; next }
    { print }
    END {
        if (!node_seen) print "NODE_BIN=" node_bin
        if (!npm_seen) print "NPM_BIN=" npm_bin
    }
' "$PROFILE_FILE" > "$profile_tmp"
mv "$profile_tmp" "$PROFILE_FILE"
chmod 600 "$PROFILE_FILE"

ok "Node $($node_binary --version) siap di ${INSTALL_ROOT}/current"
ok 'Profile diperbarui; Check berikutnya otomatis memakai runtime Node khusus SITA.'
