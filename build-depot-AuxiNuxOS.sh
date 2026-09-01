#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_BUILDER="${SCRIPT_DIR}/build-depot-kernel-core.sh"

usage() {
  cat <<EOF
AuxiNuxOS Kernel Repository Builder

Publishes the dedicated AuxiNuxOS kernel repository. It does not generate
Virtua or auxinux-desktop meta-packages.

Server layout:
  /var/www/dep.auxinux.ca/AUXINUXOS/
    KERNEL/   AuxiNuxOS kernel .deb packages
    EN/       AuxiNuxOS Normal Edition .deb packages (reserved)
    ES/       AuxiNuxOS Security Edition .deb packages (reserved)

Usage:
  sudo $0 [IMPORT_DIR]
  sudo $0 -h | --help

Defaults:
  REPO_ROOT=/var/www/dep.auxinux.ca/AUXINUXOS
  KERNEL_DIR=REPO_ROOT/KERNEL
  KERNEL_FLAVOUR=auxinuxos
  META_PACKAGE=kernel-auxinuxos
  ARCHES="amd64 arm64"

Examples:
  sudo GPG_KEY='repo@auxinux.ca' $0 /tmp/auxinuxos-kernel
  sudo GPG_KEY='repo@auxinux.ca' $0 /var/www/dep.auxinux.ca/AUXINUXOS/KERNEL

Client installation:
  sudo apt update
  sudo apt install kernel-auxinuxos

All signing, retention and architecture options accepted by
the local repository engine remain available as environment variables.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

export RELEASE_TRACK="${RELEASE_TRACK:-prod}"
case "$RELEASE_TRACK" in
  prod) _SUBDIR="KERNEL" ;;
  dev)  _SUBDIR="KERNEL-DEV" ;;
  *) echo "ERREUR: RELEASE_TRACK invalide: ${RELEASE_TRACK}. Valeurs: prod, dev." >&2; exit 1 ;;
esac

export REPO_ROOT="${REPO_ROOT:-/var/www/dep.auxinux.ca/AUXINUXOS}"
export KERNEL_DIR="${KERNEL_DIR:-${REPO_ROOT}/${_SUBDIR}}"
if [[ "$RELEASE_TRACK" == "dev" ]]; then
  export KERNEL_FLAVOUR="dev-auxinuxos"
  export META_PACKAGE="kernel-auxinuxos-dev"
else
  export KERNEL_FLAVOUR="auxinuxos"
  export META_PACKAGE="kernel-auxinuxos"
fi
export ARCHES="${ARCHES:-amd64 arm64}"
export REPO_LABEL="AuxiNuxOS Kernel Repository"
export REPO_DESCRIPTION="AuxiNuxOS custom kernel repository"
export PUBLIC_REPO_URL="${PUBLIC_REPO_URL:-https://dep.auxinux.ca/AUXINUXOS}"
export KEYRING_BASENAME="${KEYRING_BASENAME:-auxinuxos-archive-keyring}"
export SOURCES_LIST_NAME="${SOURCES_LIST_NAME:-auxinuxos-kernel}"
export FORBIDDEN_PACKAGE_PATTERNS="auxinux-virtua auxinux-desktop kernel-virtua kernel-auxinux-desktop"

# Contrôle root ici: sinon le mkdir ci-dessous échouait sur un "Permission
# denied" opaque avant que le moteur n'affiche son message "lance avec sudo".
[[ $EUID -eq 0 ]] || { echo "ERREUR: lance ce script avec sudo." >&2; exit 1; }

# Reserve the edition directories now without mixing their packages into the
# kernel APT index. Their repository metadata will be handled independently.
mkdir -p "${REPO_ROOT}/KERNEL" "${REPO_ROOT}/KERNEL-DEV" "${REPO_ROOT}/EN" "${REPO_ROOT}/ES"

exec "$REPOSITORY_BUILDER" "$@"
