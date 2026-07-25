#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${SCRIPT_DIR}/build-kernel-core.sh"
CHANNEL="current"
BRANCH=""
PASSTHROUGH=()
ZFS_OPTION_SET=0

usage() {
  cat <<EOF
AuxiNuxOS Kernel Builder

Builds the dedicated AuxiNuxOS COSMIC/Wayland desktop kernel.
Default: latest non-RC stable kernel.org release, amd64.

Usage:
  $0 [--channel=current|lts|mainline] [--branch=X.Y] [builder options]
  $0 -h | --help

Release channels:
  --channel=current   Latest normal stable kernel.org release (default).
                      Never selects a release candidate. Use --branch=X.Y to
                      stay on another stable series, for example 7.0.
  --channel=lts       Latest kernel.org longterm release. Use --branch=X.Y to
                      pin an LTS series, for example --branch=6.18.
  --channel=mainline  Latest mainline/RC release. Explicit opt-in for the
                      AuxiNuxOS development edition only.

Aliases:
  --current, --stable, --latest
  --lts, --longterm
  --mainline, --dev

Architecture and build options are forwarded to the local kernel build engine:
  -arch=amd64         Native x86_64 build (default).
  -arch=arm64         ARM64/aarch64 cross-build.
  KERNEL_VERSION=X.Y.Z[-rcN]
                      Explicit version; bypasses channel detection.
  JOBS=N, BUILD_ROOT=/path, OUTPUT_DIR=/path, -docker, -docker-bg

Examples:
  $0
  $0 --channel=current --branch=7.0 -arch=amd64
  $0 --channel=lts --branch=6.18 -arch=amd64
  $0 --channel=mainline -arch=amd64
  $0 KERNEL_VERSION=7.1.3 -arch=arm64

Output kernel release:
  X.Y.Z-auxinuxos-amd64
  X.Y.Z-auxinuxos-arm64

Repository meta-package:
  kernel-auxinuxos

AuxiNuxOS repository deployment:
  DEPLOY=1 uses this local server directory by default:
    /var/www/dep.auxinux.ca/AUXINUXOS/KERNEL

  Override it with DEPLOY_TARGET=/another/path or an rsync target.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --channel=*) CHANNEL="${arg#*=}" ;;
    channel=*) CHANNEL="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    branch=*) BRANCH="${arg#*=}" ;;
    --current|--stable|--latest) CHANNEL="current" ;;
    --lts|--longterm) CHANNEL="lts" ;;
    --mainline|--dev) CHANNEL="mainline" ;;
    profile=*|PROFILES=*|KERNEL_FLAVOUR=*|META_PACKAGE=*)
      echo "ERROR: $arg is managed by this AuxiNuxOS wrapper." >&2
      exit 1
      ;;
    WITH_ZFS=*|with-zfs|no-zfs|without-zfs)
      ZFS_OPTION_SET=1
      PASSTHROUGH+=("$arg")
      ;;
    *) PASSTHROUGH+=("$arg") ;;
  esac
done

# A workstation kernel does not need kernel-coupled OpenZFS modules by default.
(( ZFS_OPTION_SET == 1 )) || PASSTHROUGH+=("no-zfs")

case "$CHANNEL" in
  current|stable|latest) CHANNEL="current" ;;
  lts|longterm) CHANNEL="lts" ;;
  mainline|dev) CHANNEL="mainline" ;;
  *) echo "ERROR: unsupported channel '$CHANNEL'." >&2; usage; exit 1 ;;
esac

# Si l'appelant fixe déjà KERNEL_VERSION explicitement, on saute entièrement
# la détection de version/canal ci-dessous (et son besoin de python3 +
# accès réseau à kernel.org) et on relaie directement au builder.
for arg in "${PASSTHROUGH[@]}"; do
  [[ "$arg" == KERNEL_VERSION=* ]] && exec "$BUILDER" profile=auxinuxos "${PASSTHROUGH[@]}"
done

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required to read kernel.org release metadata." >&2
  exit 1
}

KERNEL_VERSION="$(python3 - "$CHANNEL" "$BRANCH" <<'PY'
import json
import sys
import urllib.request

channel, branch = sys.argv[1:]
with urllib.request.urlopen("https://www.kernel.org/releases.json", timeout=20) as response:
    releases = json.load(response)["releases"]

if channel == "current":
    matches = [r for r in releases if r.get("moniker") == "stable" and "-rc" not in r["version"]]
    if branch:
        matches = [r for r in matches if r["version"] == branch or r["version"].startswith(branch + ".")]
elif channel == "mainline":
    matches = [r for r in releases if r.get("moniker") == "mainline"]
else:
    matches = [r for r in releases if r.get("moniker") == "longterm"]
    if branch:
        matches = [r for r in matches if r["version"] == branch or r["version"].startswith(branch + ".")]

if not matches:
    raise SystemExit(f"No kernel.org release found for channel={channel}, branch={branch or 'auto'}")
print(matches[0]["version"])
PY
)"

echo "AuxiNuxOS release channel: ${CHANNEL}${BRANCH:+ (branch ${BRANCH})}"
echo "Selected kernel.org version: ${KERNEL_VERSION}"

if [[ "$CHANNEL" == "mainline" ]]; then
  echo "WARNING: mainline uses kernel.org's unsigned git snapshot tarball."
  export ALLOW_UNVERIFIED_SOURCE=1
fi

if [[ "${DEPLOY:-0}" == "1" && -z "${DEPLOY_TARGET:-}" ]]; then
  export DEPLOY_TARGET="/var/www/dep.auxinux.ca/AUXINUXOS/KERNEL"
fi

exec "$BUILDER" \
  profile=auxinuxos \
  source=kernelorg \
  "KERNEL_VERSION=${KERNEL_VERSION}" \
  "${PASSTHROUGH[@]}"
