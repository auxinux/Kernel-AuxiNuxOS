#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${SCRIPT_DIR}/build-kernel-core.sh"
CHANNEL="current"
# Série noyau de production d'AuxiNuxOS.
#
# On épingle la SÉRIE, pas la révision: --branch=7.2 suit 7.2.5, puis 7.2.6...
# sans jamais sauter tout seul sur 7.3 le jour où kernel.org la publie. Un
# changement de série change les pilotes et les options de configuration; il
# se décide, il ne s'attrape pas au détour d'un build automatique.
#
# La série 7.1 a été marquée EOL le 2026-09-02: elle ne reçoit plus aucun
# correctif de sécurité. C'est ce qui motive le passage à 7.2.
BRANCH="${AUXINUXOS_KERNEL_BRANCH:-7.2}"
PASSTHROUGH=()
ZFS_OPTION_SET=0

usage() {
  cat <<EOF
AuxiNuxOS Kernel Builder

Builds the dedicated AuxiNuxOS COSMIC/Wayland DESKTOP kernel: office,
multimedia and gaming on one machine, with LXC/Docker and KVM kept intact,
ZRAM, Intel/AMD/NVIDIA GPU support, and the built-ins required by the
AuxiNuxOS BTRFS rollback. On arm64 the same profile adds SoC GPUs (Mali,
Adreno, VideoCore), Energy Aware Scheduling and 4K pages for FEX/Box64, on top
of the GPG-verified Debian arm64 config.

Default: latest non-RC release of the 7.2 series, amd64.

Usage:
  $0 [--channel=current|lts|mainline] [--branch=X.Y] [builder options]
  $0 -h | --help

Kernel series:
  AuxiNuxOS production tracks the 7.2 series by default (--branch=7.2).
  The 7.1 series went EOL on 2026-09-02 and no longer receives security
  fixes. Pinning the SERIES, not the revision, means 7.2.5 -> 7.2.6 -> ...
  happen on their own while a jump to 7.3 stays an explicit decision.

  --branch=X.Y        Pin another series, for example --branch=7.3.
  --branch=any        Follow the latest stable series, whatever it is.

Release channels:
  --channel=current   Latest normal stable kernel.org release (default).
                      Never selects a release candidate.
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
  -arch=arm64         ARM64/aarch64 cross-build. Base config: Debian arm64
                      from trixie-backports, GPG-verified (override with
                      BASE_CONFIG_ARM64=/path).
  KERNEL_VERSION=X.Y.Z[-rcN]
                      Explicit version; bypasses series/channel detection.
  -config-only        Dry run: apply and VERIFY the kernel configuration, then
                      stop before compiling. Step [6a] indexes every Kconfig
                      symbol of the source tree and refuses any option that
                      does not exist in that kernel. Run this first whenever
                      the kernel series changes.
  JOBS=N, BUILD_ROOT=/path, OUTPUT_DIR=/path, -docker, -docker-bg

Examples:
  $0                                        # latest 7.2.x, amd64
  $0 -config-only                           # dry run: verify config only
  $0 --branch=7.3 -arch=amd64               # move the production series
  $0 --channel=lts --branch=6.18 -arch=amd64
  $0 --channel=mainline -arch=amd64
  $0 KERNEL_VERSION=7.2.5 -arch=arm64

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
    # --branch=any (ou vide) délie la série: on suit alors la dernière stable,
    # quelle qu'elle soit. À n'utiliser que sciemment.
    --branch=any|branch=any|--branch=latest|branch=latest) BRANCH="" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    branch=*) BRANCH="${arg#*=}" ;;
    # Uniquement la forme track=... ici: les alias courts -dev/-prod seraient
    # confondus avec --dev, qui designe deja le canal mainline ci-dessous.
    track=*|--track=*|RELEASE_TRACK=*) PASSTHROUGH+=("$arg") ;;
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
# WITH_ZFS fourni par l'environnement compte aussi comme un choix explicite:
# sinon le "no-zfs" implicite ci-dessous l'ecrasait silencieusement.
[[ -n "${WITH_ZFS:-}" ]] && ZFS_OPTION_SET=1
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
    # Une série disparaît de la liste "stable" quand elle passe EOL: le message
    # doit le dire, sinon l'échec ressemble à une panne réseau.
    eol = [r["version"] for r in releases
           if r.get("iseol") and branch and r["version"].startswith(branch)]
    hint = f" La série {branch} est marquée EOL ({', '.join(eol)})." if eol else ""
    raise SystemExit(
        f"No kernel.org release found for channel={channel}, branch={branch or 'auto'}.{hint}")

selected = matches[0]
if selected.get("iseol"):
    print(f"AVERTISSEMENT: {selected['version']} est marquee EOL sur kernel.org "
          "— cette serie ne recoit plus de correctif de securite.",
          file=sys.stderr)
print(selected["version"])
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
