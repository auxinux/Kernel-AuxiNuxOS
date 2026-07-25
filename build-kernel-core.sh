#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Virtua Kernel Builder
# Hyperviseur Virtua (KVM/QEMU + LXC + Docker)
# Base: Debian 13 / Trixie
# ============================================================
#
# Usage:
#   ./build-kernel-core.sh                        # source=kernelorg (defaut)
#   ./build-kernel-core.sh profile=desktop        # kernel desktop recent
#   ./build-kernel-core.sh -arch=arm64            # ARM64/aarch64 build
#   ./build-kernel-core.sh source=debian
#   ./build-kernel-core.sh source=kernelorg
#   ./build-kernel-core.sh -check-kernelorg       # compare kernel.org vs dernier build
#   ./build-kernel-core.sh -check-debian          # compare Debian backports vs dernier build
#
# Variables optionnelles (toutes ont une valeur par defaut) :
#
#   SOURCE              : "kernelorg" ou "debian" (defaut: kernelorg)
#   PROFILE             : "virtua", "desktop" ou "auxinuxos" (defaut: virtua)
#   TARGET_ARCH         : "amd64", "arm" ou "arm64" (defaut: amd64)
#   KERNEL_MAJOR        : branche kernel ex: "6.12"
#                         "auto" = detecte la plus recente (defaut: auto)
#   KERNEL_VERSION      : version exacte ex: "6.12.31"
#                         auto-detecte si absent
#   VIRTUA_BUILD_NUMBER : incrementer si on rebuild le MEME upstream
#                         avec une config differente (defaut: 1)
#   META_PACKAGE        : paquet meta recommande dans README
#   JOBS                : parallelisme make (defaut: nproc)
#   BUILD_ROOT          : dossier de travail (defaut: /usr/src/auxinuxos-kernel-build)
#   OUTPUT_DIR          : dossier de sortie des .deb (defaut: BUILD_ROOT/output)
#   CHECK_DIR           : dossier inspecte par -check-* (defaut: OUTPUT_DIR)
#   DEPLOY=1            : copie les .deb produits vers DEPLOY_TARGET
#   DEPLOY_TARGET       : cible locale ou rsync distante (optionnel)
#
# Exemples:
#   ./build-kernel-core.sh KERNEL_VERSION=6.12.31
#   JOBS=8 ./build-kernel-core.sh source=debian
# ============================================================

SOURCE="kernelorg"
MODE="build"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-current}"
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

PROFILE="${PROFILE:-virtua}"
PROFILES="${PROFILES:-}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
KERNEL_MAJOR="${KERNEL_MAJOR:-auto}"
KERNEL_FLAVOUR="${KERNEL_FLAVOUR:-}"
META_PACKAGE="${META_PACKAGE:-}"
VIRTUA_BUILD_NUMBER="${VIRTUA_BUILD_NUMBER:-1}"

BUILD_ROOT="${BUILD_ROOT:-/usr/src/auxinuxos-kernel-build}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
CHECK_DIR="${CHECK_DIR:-}"
JOBS="${JOBS:-}"
DEPLOY="${DEPLOY:-0}"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"

KERNELORG_BASE_URL="https://cdn.kernel.org/pub/linux/kernel"

# --- OpenZFS apparié au kernel (modèle Proxmox) ---
# Construit les modules ZFS CONTRE le kernel fraîchement compilé et les empaquette
# (kmod-zfs-<release>), pour éviter tout désappariement DKMS sur kernel récent.
# OpenZFS 2.4.2+ supporte le kernel 7.0 (range 4.18 -> 7.0).
WITH_ZFS="${WITH_ZFS:-auto}"          # auto = activé sur amd64 natif, sinon off
ZFS_VERSION="${ZFS_VERSION:-2.4.2}"   # version OpenZFS qui supporte 7.0
ZFS_BASE_URL="${ZFS_BASE_URL:-https://github.com/openzfs/zfs/releases/download}"
# Vérification d'intégrité de la source ZFS. Renseigne le sha256 du tarball
# zfs-<ZFS_VERSION>.tar.gz (obligatoire sauf ALLOW_UNVERIFIED_SOURCE=1).
ZFS_SHA256="${ZFS_SHA256:-}"

# Empreintes GPG ÉPINGLÉES des mainteneurs kernel.org (vérification du source).
# Source: https://www.kernel.org/signature.html
KERNEL_ORG_KEYS=(
  "ABAF11C65A2970B130ABE3C479BE3E4300411886"  # Linus Torvalds
  "647F28654894E3BD457199BE38DBBDC86092693E"  # Greg Kroah-Hartman
)
KERNEL_ORG_KEYSERVER="${KERNEL_ORG_KEYSERVER:-hkps://keys.openpgp.org}"
# Garde-fou: ne JAMAIS mettre 1 en production. Uniquement build hors-ligne/test.
ALLOW_UNVERIFIED_SOURCE="${ALLOW_UNVERIFIED_SOURCE:-0}"

usage() {
  cat <<EOF
AuxiNux Kernel Builder

Builds custom Debian kernel .deb packages for AuxiNux Virtua.
Default build target: latest stable kernel.org source, profile=virtua.

Usage:
  $0 [options]
  $0 profile=desktop [options]
  $0 profile=all [options]
  $0 -arch=arm64 [options]
  $0 -check-kernelorg [CHECK_DIR=/path/to/debs]
  $0 -check-debian [CHECK_DIR=/path/to/debs]
  $0 -h | --help

Profiles:
  profile=virtua
      Host/hypervisor kernel for Virtua.
      Produces: X.X.X-auxinux-virtua-ARCH
      Recommended meta-package: kernel-virtua
      Supported architecture: amd64 only.
      Includes the Wi-Fi/Bluetooth kernel stack needed for wired or wireless hosts.

  profile=desktop
      Desktop and VM desktop kernel with GPU/DRM support kept enabled.
      Produces: X.X.X-auxinux-desktop-ARCH
      Recommended meta-package: kernel-auxinux-desktop
      Supported architectures: amd64, arm64.

  profile=auxinuxos
      AuxiNuxOS workstation kernel for COSMIC/Wayland on bare metal or in a VM.
      Produces: X.X.X-auxinuxos-ARCH
      Recommended meta-package: kernel-auxinuxos
      Supported architectures: amd64, arm64.

  profile=all  (alias: PROFILES="virtua desktop", profile=virtua,desktop)
      Build virtua THEN desktop for the same architecture, one after another.
      On non-amd64 targets the virtua profile is skipped automatically.
      Other options (source, arch, KERNEL_VERSION, JOBS...) apply to both.
      Not compatible with -check-* modes (single profile only).

Source selection:
  source=kernelorg
      Download the latest stable source from kernel.org. This is the default.

  source=debian
      Build from Debian 13/Trixie linux-source packages.

Kernel.org release channel:
  --channel=current
      Latest normal stable release (default). Never selects an RC.
      Add --branch=X.Y to stay on another stable series.

  --channel=lts
      Latest kernel.org longterm release. Add --branch=X.Y to pin a series.

  --channel=mainline
      Latest mainline/RC snapshot. Explicit development build only.

  KERNEL_VERSION=X.Y.Z[-rcN]
      Build an exact version and bypass channel detection.

Architecture selection:
  -arch=amd64
      Native x86_64/amd64 build. This is the default.
      Produces a kernel release ending with -amd64.

  -arch=arm
      Alias for -arch=arm64. ARM 32-bit is not supported by this script.

  -arch=arm64
      ARM64/aarch64 build using Debian architecture arm64.
      Produces a kernel release ending with -arm64.

  arch=name and TARGET_ARCH=name are accepted aliases for -arch=name.

Check modes:
  -check-kernelorg
      Compare the latest stable kernel.org version with the latest built
      linux-image-* package found in CHECK_DIR.

  -check-debian
      Compare the latest Debian linux-source version with the latest built
      linux-image-* package found in CHECK_DIR.

Options:
  KERNEL_VERSION=x.y.z       Build an exact upstream version.
  KERNEL_MAJOR=x.y           Select a major branch, mainly for Debian source.
  KERNEL_FLAVOUR=name        Override the generated kernel suffix.
  TARGET_ARCH=name           Same as -arch=name.
  CROSS_COMPILE=prefix       Override cross compiler prefix.
  META_PACKAGE=name          Override the meta-package suggested in README.
  VIRTUA_BUILD_NUMBER=n      Increment when rebuilding the same upstream version.
  JOBS=n                     Parallel make jobs. Default: nproc.
  BUILD_ROOT=/path           Build workspace. Default: /usr/src/auxinuxos-kernel-build.
  OUTPUT_DIR=/path           Output directory for generated .deb files.
  CHECK_DIR=/path            Directory inspected by -check-* modes.

OpenZFS apparié au kernel (modèle Proxmox):
  WITH_ZFS=auto|1|0          Build OpenZFS modules against this kernel and ship
                             them as kmod-zfs-<release>. Default: auto
                             (ON on native amd64, OFF when cross-compiling).
                             Aliases: with-zfs / no-zfs.
  ZFS_VERSION=x.y.z          OpenZFS version. Default: 2.4.2 (supporte kernel 7.0).
  ZFS_SHA256=hash            sha256 du tarball zfs-<ZFS_VERSION>.tar.gz.
                             Obligatoire si WITH_ZFS=1 (sauf ALLOW_UNVERIFIED_SOURCE=1).
  ALLOW_UNVERIFIED_SOURCE=1  Désactive la vérif source kernel ET ZFS (DÉCONSEILLÉ).

Examples:
  $0
  $0 --channel=current --branch=7.0
  $0 --channel=lts --branch=6.18
  $0 --channel=mainline profile=desktop
  $0 profile=desktop
  $0 profile=all                       # virtua + desktop (amd64) + ZFS apparié
  $0 profile=all -arch=arm64           # desktop seul (virtua + ZFS sautés sur arm64)
  $0 -arch=arm64
  $0 KERNEL_VERSION=6.12.31
  $0 profile=desktop -arch=arm64 KERNEL_VERSION=6.12.31 JOBS=8
  $0 source=debian KERNEL_MAJOR=6.12
  $0 ZFS_SHA256=<hash>                 # build + modules ZFS 2.4.2 vérifiés
  $0 no-zfs                            # kernel seul, sans modules ZFS
  $0 profile=all -docker               # build dans un conteneur debian:13 amd64

Build dans Docker:
  -docker (ou --docker)      Relance tout le build dans un conteneur debian:13
                             linux/amd64 (utile sur macOS/Windows). Installe les
                             deps, crée un user non-root, monte ./output pour les
                             .deb, et un volume cache 'auxinuxos-kernel-build'.
                             Tous les autres arguments sont transmis tels quels.
                             Foreground: meurt si tu fermes le terminal.
  -docker-bg                 Comme -docker mais DÉTACHÉ: survit à la fermeture du
                             terminal (idéal pour un long build). Journalise dans
                             ./output/auxinuxos-kernel-build.log. Suivi: docker logs -f auxinuxos-kernel-build
  DOCKER_IMAGE=nom           Image de base. Défaut: debian:13.
  DOCKER_NAME=nom            Nom du conteneur. Défaut: auxinuxos-kernel-build.
  $0 -check-kernelorg CHECK_DIR=/var/www/dep.auxinux.ca/VIRTUA/KERNEL

Exit codes for check modes:
  0   already up to date
  10  build required
  1   error
EOF
}

# ============================================================
# Build dans Docker (-docker) : relance TOUT le build dans un conteneur
# debian:13 amd64, installe les deps, et exécute avec les autres arguments.
# Pratique sur macOS/Windows où l'hôte n'est pas Debian.
# ============================================================
run_in_docker() {
  local script_dir image cname inner
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  image="${DOCKER_IMAGE:-debian:13}"
  cname="${DOCKER_NAME:-auxinuxos-kernel-build}"

  command -v docker >/dev/null 2>&1 \
    || { echo "ERREUR: docker introuvable. Installe/ouvre Docker Desktop." >&2; exit 1; }
  docker info >/dev/null 2>&1 \
    || { echo "ERREUR: le démon Docker ne répond pas. Lance Docker Desktop." >&2; exit 1; }

  mkdir -p "$script_dir/output"

  # Script interne du conteneur. En mode détaché, on journalise dans /output
  # (= ./output sur l'hôte) pour garder le log même si le conteneur disparaît.
  inner='
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y sudo ca-certificates rsync
      id builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder
      echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder
      chmod 0440 /etc/sudoers.d/builder
      chown -R builder:builder /work /output /usr/src/auxinuxos-kernel-build
      exec sudo -u builder -H env OUTPUT_DIR=/output DEPLOY="${DEPLOY}" DEPLOY_TARGET="${DEPLOY_TARGET}" ./build-kernel-core.sh "$@"'

  local -a docker_args=(
    --name "$cname"
    --platform linux/amd64
    -v "$script_dir":/work -w /work
    -v "$script_dir/output":/output
    -v auxinuxos-kernel-build:/usr/src/auxinuxos-kernel-build
    -e DEPLOY="${DEPLOY}"
    -e DEPLOY_TARGET="${DEPLOY_TARGET}"
  )

  # Évite un conflit de nom si un run précédent a laissé un conteneur.
  docker rm -f "$cname" >/dev/null 2>&1 || true

  echo "============================================================"
  echo " Build dans Docker $([[ "$DOCKER_DETACH" == "1" ]] && echo '(détaché — survit à la fermeture du terminal)')"
  echo " Image   : ${image} (plateforme linux/amd64)"
  echo " Source  : ${script_dir}  ->  /work"
  echo " Sortie  : ${script_dir}/output  ->  /output"
  echo " Args    : ${DOCKER_PASSTHROUGH[*]:-(aucun)}"
  echo " Cache   : volume docker 'auxinuxos-kernel-build' (sources/tarballs réutilisés)"
  echo "============================================================"

  if [[ "$DOCKER_DETACH" == "1" ]]; then
    # Détaché: journal vers ./output/auxinuxos-kernel-build.log, conteneur conservé.
    docker run -d "${docker_args[@]}" \
      "$image" bash -lc "{ $inner ; } > /output/auxinuxos-kernel-build.log 2>&1" \
      _ ${DOCKER_PASSTHROUGH[@]+"${DOCKER_PASSTHROUGH[@]}"} >/dev/null
    echo
    echo "Build lancé en arrière-plan (conteneur '${cname}'). Tu peux fermer le terminal."
    echo "Suivre en direct :   docker logs -f ${cname}"
    echo "        ou (hôte) :   tail -f \"${script_dir}/output/auxinuxos-kernel-build.log\""
    echo "État              :   docker ps --filter name=${cname}"
    echo "Arrêter           :   docker rm -f ${cname}"
    echo "Résultats         :   ${script_dir}/output/  (.deb à la fin)"
    exit 0
  fi

  # Foreground interactif.
  local tflag
  if [[ -t 0 ]]; then tflag="-it"; else tflag="-i"; fi
  exec docker run --rm $tflag "${docker_args[@]}" \
    "$image" bash -lc "$inner" \
    _ ${DOCKER_PASSTHROUGH[@]+"${DOCKER_PASSTHROUGH[@]}"}
}

# Détecte -docker AVANT toute logique Debian (sinon échoue sur l'hôte macOS).
DOCKER_BUILD=0
DOCKER_DETACH=0
DOCKER_PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    -docker|--docker|docker) DOCKER_BUILD=1 ;;
    -docker-bg|--docker-bg|-docker-detach|--docker-detach|docker-bg)
      DOCKER_BUILD=1; DOCKER_DETACH=1 ;;
    *) DOCKER_PASSTHROUGH+=("$arg") ;;
  esac
done
if (( DOCKER_BUILD == 1 )); then
  run_in_docker
fi

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    -docker|--docker|docker) ;;                         # déjà traité ci-dessus
    -docker-bg|--docker-bg|-docker-detach|--docker-detach|docker-bg) ;;  # idem
    source=debian) SOURCE="debian" ;;
    source=kernelorg) SOURCE="kernelorg" ;;
    --channel=*|channel=*) RELEASE_CHANNEL="${arg#*=}" ;;
    --branch=*|branch=*) RELEASE_BRANCH="${arg#*=}" ;;
    --current|--stable|--latest) RELEASE_CHANNEL="current" ;;
    --lts|--longterm) RELEASE_CHANNEL="lts" ;;
    --mainline|--dev) RELEASE_CHANNEL="mainline" ;;
    profile=all) PROFILES="virtua desktop" ;;
    profile=virtua) PROFILE="virtua" ;;
    profile=desktop) PROFILE="desktop" ;;
    profile=auxinuxos) PROFILE="auxinuxos" ;;
    profile=*) PROFILES="${arg#*=}" ;;   # ex: profile=virtua,desktop
    PROFILES=*) PROFILES="${arg#*=}" ;;
    -arch=*) TARGET_ARCH="${arg#*=}" ;;
    --arch=*) TARGET_ARCH="${arg#*=}" ;;
    arch=*) TARGET_ARCH="${arg#*=}" ;;
    TARGET_ARCH=*) TARGET_ARCH="${arg#*=}" ;;
    -check-debian|--check-debian) MODE="check"; SOURCE="debian" ;;
    -check-kernelorg|--check-kernelorg) MODE="check"; SOURCE="kernelorg" ;;
    KERNEL_MAJOR=*) KERNEL_MAJOR="${arg#*=}" ;;
    KERNEL_FLAVOUR=*) KERNEL_FLAVOUR="${arg#*=}" ;;
    META_PACKAGE=*) META_PACKAGE="${arg#*=}" ;;
    KERNEL_VERSION=*) KERNEL_VERSION="${arg#*=}" ;;
    VIRTUA_BUILD_NUMBER=*) VIRTUA_BUILD_NUMBER="${arg#*=}" ;;
    JOBS=*) JOBS="${arg#*=}" ;;
    WITH_ZFS=*) WITH_ZFS="${arg#*=}" ;;
    with-zfs) WITH_ZFS="1" ;;
    no-zfs|without-zfs) WITH_ZFS="0" ;;
    ZFS_VERSION=*) ZFS_VERSION="${arg#*=}" ;;
    ZFS_SHA256=*) ZFS_SHA256="${arg#*=}" ;;
    CROSS_COMPILE=*) CROSS_COMPILE="${arg#*=}" ;;
    BUILD_ROOT=*) BUILD_ROOT="${arg#*=}" ;;
    OUTPUT_DIR=*) OUTPUT_DIR="${arg#*=}" ;;
    CHECK_DIR=*) CHECK_DIR="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERREUR: argument inconnu: $arg"; usage; exit 1 ;;
  esac
done

case "$RELEASE_CHANNEL" in
  current|stable|latest) RELEASE_CHANNEL="current" ;;
  lts|longterm) RELEASE_CHANNEL="lts" ;;
  mainline|dev) RELEASE_CHANNEL="mainline" ;;
  *) die "release channel invalide: ${RELEASE_CHANNEL}. Valeurs: current, lts, mainline." ;;
esac

if [[ "$RELEASE_CHANNEL" == "mainline" || "${KERNEL_VERSION:-}" == *-rc* ]]; then
  # Choisir mainline est l'opt-in explicite requis pour le snapshot git non signé.
  ALLOW_UNVERIFIED_SOURCE=1
fi

case "$TARGET_ARCH" in
  amd64)
    KERNEL_ARCH_SUFFIX="amd64"
    KBUILD_ARCH="x86_64"
    KBUILD_DEBARCH="amd64"
    DEFAULT_CROSS_COMPILE=""
    ARCH_DEPS=()
    ;;
  arm)
    # "arm" est un alias volontaire de "arm64": le 32-bit n'est pas supporté,
    # cette branche existe seulement pour accepter -arch=arm sans erreur.
    KERNEL_ARCH_SUFFIX="arm64"
    KBUILD_ARCH="arm64"
    KBUILD_DEBARCH="arm64"
    DEFAULT_CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH_DEPS=(gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
    ;;
  arm64)
    KERNEL_ARCH_SUFFIX="arm64"
    KBUILD_ARCH="arm64"
    KBUILD_DEBARCH="arm64"
    DEFAULT_CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH_DEPS=(gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
    ;;
  *)
    echo "ERREUR: architecture invalide: ${TARGET_ARCH}. Valeurs supportées: amd64, arm, arm64." >&2
    exit 1
    ;;
esac

CROSS_COMPILE="${CROSS_COMPILE:-$DEFAULT_CROSS_COMPILE}"

# Résout WITH_ZFS=auto: ON sur amd64 natif, OFF si cross-compilation (arm64).
# Construire OpenZFS en cross-compile est un nid à problèmes; on l'évite.
if [[ "$WITH_ZFS" == "auto" ]]; then
  if [[ "$KBUILD_DEBARCH" == "amd64" && -z "$CROSS_COMPILE" ]]; then
    WITH_ZFS="1"
  else
    WITH_ZFS="0"
  fi
fi
# sha256 ÉPINGLÉ des versions OpenZFS connues (provenance: fichier sha256.asc
# signé GPG par OpenZFS). Évite d'avoir à le fournir pour la version par défaut.
if [[ -z "$ZFS_SHA256" ]]; then
  case "$ZFS_VERSION" in
    2.4.2) ZFS_SHA256="7e260d0e6af295bea4c5e241cac0a1aef07b58d8dd8035f7898ade3b1bbec78f" ;;
  esac
fi

if [[ "$DEPLOY" == "1" ]]; then
  [[ -n "$DEPLOY_TARGET" ]] || die "DEPLOY=1 mais DEPLOY_TARGET est vide."
fi

# Sur macOS / Windows, on bascule automatiquement en Docker.
if [[ "$(uname -s)" != "Linux" && "$DOCKER_BUILD" != "1" ]]; then
  DOCKER_BUILD=1
fi

if (( DOCKER_BUILD == 1 )); then
  run_in_docker
fi

# Propage aux builds enfants (profile=all) même si fourni via l'environnement.
export WITH_ZFS ZFS_VERSION ZFS_SHA256

# ============================================================
# Build multi-profil (profile=all / PROFILES="virtua desktop")
# Enchaîne les profils pour LA MÊME architecture en se relançant
# une fois par profil. La logique de build reste mono-profil.
# ============================================================
if [[ -n "$PROFILES" ]]; then
  read -r -a _profiles <<< "${PROFILES//,/ }"

  if [[ "$MODE" == "check" ]]; then
    die "le mode -check-* ne supporte qu'un seul profil. Utilise profile=virtua ou profile=desktop."
  fi

  # Réinjecte les arguments d'origine sans aucune mention de profil
  # (chaque profil est passé explicitement à l'enfant).
  passthrough=()
  for a in "$@"; do
    case "$a" in
      profile=*|PROFILES=*) ;;
      *) passthrough+=("$a") ;;
    esac
  done

  echo "============================================================"
  echo " Build multi-profil: ${_profiles[*]} (arch=${TARGET_ARCH})"
  echo "============================================================"

  for _p in "${_profiles[@]}"; do
    case "$_p" in
      virtua|desktop|auxinuxos) ;;
      *) die "profil invalide dans PROFILES: '${_p}'. Valeurs: virtua, desktop, auxinuxos." ;;
    esac
    if [[ "$_p" == "virtua" && "$KBUILD_DEBARCH" != "amd64" ]]; then
      echo
      echo ">>> profil 'virtua' ignoré sur ${KBUILD_DEBARCH} (supporté amd64 uniquement)."
      continue
    fi
    echo
    echo ">>> ============================================================"
    echo ">>> Build du profil '${_p}' (arch=${TARGET_ARCH})"
    echo ">>> ============================================================"
    # PROFILES= vide pour l'enfant: évite toute récursion (y compris via env).
    # Expansion protégée: tableau vide toléré sous set -u.
    PROFILES= "$0" "profile=${_p}" ${passthrough[@]+"${passthrough[@]}"}
  done

  echo
  echo "============================================================"
  echo " Build multi-profil terminé (${_profiles[*]})"
  echo "============================================================"
  exit 0
fi

if [[ -z "$KERNEL_FLAVOUR" ]]; then
  case "$PROFILE" in
    virtua) KERNEL_FLAVOUR="auxinux-virtua" ;;
    desktop) KERNEL_FLAVOUR="auxinux-desktop" ;;
    auxinuxos) KERNEL_FLAVOUR="auxinuxos" ;;
  esac
fi

KERNEL_NAME_SUFFIX="${KERNEL_FLAVOUR}-${KERNEL_ARCH_SUFFIX}"

if [[ -z "$META_PACKAGE" ]]; then
  case "$PROFILE" in
    virtua) META_PACKAGE="kernel-virtua" ;;
    desktop) META_PACKAGE="kernel-auxinux-desktop" ;;
    auxinuxos) META_PACKAGE="kernel-auxinuxos" ;;
  esac
fi

OUTPUT_DIR="${OUTPUT_DIR:-${BUILD_ROOT}/output}"
CHECK_DIR="${CHECK_DIR:-${OUTPUT_DIR}}"
if [[ -z "$JOBS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS="1"
  fi
fi

MAKE_ARCH_ARGS=(ARCH="$KBUILD_ARCH" KBUILD_DEBARCH="$KBUILD_DEBARCH")
if [[ -n "$CROSS_COMPILE" ]]; then
  MAKE_ARCH_ARGS+=(CROSS_COMPILE="$CROSS_COMPILE")
fi

# ============================================================
# Helpers
# ============================================================

cfg() { ./scripts/config "$@" || true; }

die() { echo; echo "ERREUR: $*" >&2; exit 1; }

is_supported_debian13_base() {
  case "${ID:-}" in
    debian|virtuaos|auxinux|auxinuxos|auxinux-virtua|virtua) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *) case "${PRETTY_NAME:-} ${NAME:-}" in *VirtuaOS*|*AuxinuxOS*|*AuxiNuxOS*) ;; *) return 1 ;; esac ;;
      esac
      ;;
  esac

  [[ "${VERSION_CODENAME:-}" == "trixie" || "${VERSION_ID:-}" == "13" ]]
}

# Vérifie un tarball kernel.org contre les clés mainteneur épinglées.
# Bloquant: toute erreur interrompt le build (sauf ALLOW_UNVERIFIED_SOURCE=1).
verify_kernel_tarball() {
  local tarball="$1" sig="$2"

  command -v gpg >/dev/null 2>&1 \
    || die "gpg requis pour vérifier la source kernel.org (installe gnupg).
Pour passer outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_SOURCE=1"
  command -v xz >/dev/null 2>&1 || die "xz requis pour vérifier la source."

  local gnupghome
  gnupghome="$(mktemp -d)"
  chmod 700 "$gnupghome"

  # Récupère les clés mainteneur dans un trousseau jetable.
  # 1) WKD de kernel.org = source autoritative pour CES clés.
  # 2) repli keyserver par empreinte si le WKD est injoignable.
  # La validation par empreinte épinglée (plus bas) reste l'autorité finale,
  # donc aucune de ces sources n'affaiblit l'épinglage.
  local key imported=0
  GNUPGHOME="$gnupghome" gpg --batch --quiet --auto-key-locate clear,wkd \
    --locate-keys torvalds@kernel.org gregkh@kernel.org 2>/dev/null && imported=1

  if (( imported == 0 )); then
    for key in "${KERNEL_ORG_KEYS[@]}"; do
      GNUPGHOME="$gnupghome" gpg --batch --quiet \
        --keyserver "$KERNEL_ORG_KEYSERVER" --recv-keys "$key" 2>/dev/null && imported=1
    done
  fi

  local status
  status="$(xz -cd "$tarball" \
    | GNUPGHOME="$gnupghome" gpg --batch --status-fd 1 --verify "$sig" - 2>/dev/null || true)"
  rm -rf "$gnupghome"

  grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status" \
    || die "signature kernel.org INVALIDE ou clé introuvable (${KERNEL_ORG_KEYSERVER}).
Vérifie la connectivité au keyserver. Build interrompu."

  local k matched=0
  for k in "${KERNEL_ORG_KEYS[@]}"; do
    grep -q "VALIDSIG.*${k}" <<<"$status" && matched=1
  done
  (( matched == 1 )) \
    || die "signature VALIDE mais clé NON approuvée (hors liste épinglée). Build interrompu."

  echo "Signature kernel.org vérifiée (clé mainteneur épinglée)."
}

case "$PROFILE" in
  virtua|desktop|auxinuxos) ;;
  *) die "PROFILE invalide: ${PROFILE}. Valeurs supportées: virtua, desktop, auxinuxos." ;;
esac

if [[ "$PROFILE" == "virtua" && "$KBUILD_DEBARCH" != "amd64" ]]; then
  die "profile=virtua is supported only on amd64. Use profile=desktop for arm64 builds."
fi

latest_kernelorg_selected() {
  python3 - "$RELEASE_CHANNEL" "$RELEASE_BRANCH" <<'PY'
import json
import sys
import urllib.request

channel, branch = sys.argv[1:]
with urllib.request.urlopen("https://www.kernel.org/releases.json", timeout=20) as response:
    releases = json.load(response)["releases"]

moniker = {"current": "stable", "lts": "longterm", "mainline": "mainline"}[channel]
matches = [release for release in releases if release.get("moniker") == moniker]
if channel != "mainline":
    matches = [release for release in matches if "-rc" not in release["version"]]
if branch:
    matches = [release for release in matches
               if release["version"] == branch or release["version"].startswith(branch + ".")]
if not matches:
    raise SystemExit(f"no kernel.org release for channel={channel}, branch={branch or 'auto'}")
print(matches[0]["version"])
PY
}

latest_debian_source_version() {
  local major source_pkg_version noepoch

  major="$KERNEL_MAJOR"
  if [[ "$major" == "auto" ]]; then
    major="$(apt-cache pkgnames linux-source- 2>/dev/null \
      | grep -E '^linux-source-[0-9]+\.[0-9]+$' \
      | sed 's/^linux-source-//' \
      | sort -V | tail -n1)"
  fi

  [[ -n "$major" ]] || return 1
  source_pkg_version="$(apt-cache policy "linux-source-${major}" \
    | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$source_pkg_version" && "$source_pkg_version" != "(none)" ]] || return 1

  noepoch="${source_pkg_version#*:}"
  printf '%s\n' "${noepoch%%-*}"
}

# Trouve la version la plus récente déjà construite pour ce profil/arch dans
# CHECK_DIR, en lisant les métadonnées .deb. CHECK_DIR peut être un dossier
# distant monté ou un miroir minimal sans dpkg-deb installé (ex: sur le
# serveur dépôt) ; dans ce cas on retombe sur un parsing du nom de fichier
# canonique (moins fiable mais suffisant pour -check-*).
latest_built_kernel_version() {
  local f pkg version release upstream

  [[ -d "$CHECK_DIR" ]] || return 1

  for f in "$CHECK_DIR"/*.deb; do
    [[ -e "$f" ]] || continue

    if command -v dpkg-deb >/dev/null 2>&1; then
      pkg="$(dpkg-deb -f "$f" Package 2>/dev/null || true)"
      version="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
      case "$pkg" in
        linux-image-*-"${KERNEL_NAME_SUFFIX}")
          release="${pkg#linux-image-}"
          upstream="${release%-${KERNEL_NAME_SUFFIX}}"
          printf '%s\t%s\t%s\n' "$upstream" "$version" "$pkg"
          ;;
      esac
    else
      case "$(basename "$f")" in
        linux-image-*-"${KERNEL_NAME_SUFFIX}"_*.deb)
          release="$(basename "$f")"
          release="${release#linux-image-}"
          release="${release%%_*}"
          upstream="${release%-${KERNEL_NAME_SUFFIX}}"
          printf '%s\t%s\t%s\n' "$upstream" "inconnu" "linux-image-${release}"
          ;;
      esac
    fi
  done | sort -V | tail -n1
}

# true si $1 > $2. dpkg --compare-versions comprend la syntaxe des versions
# Debian (epoch, ~, etc.) ; en son absence (ex: exécution hors Debian), on
# retombe sur un tri naturel `sort -V`, moins précis mais correct pour de
# simples versions X.Y.Z.
version_gt() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$1" gt "$2"
  else
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
  fi
}

run_check() {
  local latest built built_upstream built_pkg_version built_pkg

  if [[ "$SOURCE" == "kernelorg" ]]; then
    echo "Vérification kernel.org (${RELEASE_CHANNEL}${RELEASE_BRANCH:+, branche ${RELEASE_BRANCH}})..."
    latest="$(latest_kernelorg_selected)"
  else
    echo "Vérification Debian linux-source..."
    latest="$(latest_debian_source_version)"
  fi
  [[ -n "$latest" ]] || die "impossible de détecter la dernière version source (${SOURCE})."

  built="$(latest_built_kernel_version || true)"
  if [[ -n "$built" ]]; then
    IFS=$'\t' read -r built_upstream built_pkg_version built_pkg <<< "$built"
  else
    built_upstream="aucun"
    built_pkg_version="aucun"
    built_pkg="aucun"
  fi

  echo
  echo "Source          : ${SOURCE}"
  echo "Dernière source : ${latest}"
  echo "Dernier build   : ${built_upstream}"
  echo "Paquet build    : ${built_pkg}"
  echo "Version paquet  : ${built_pkg_version}"
  echo "Dossier vérifié : ${CHECK_DIR}"
  echo

  if [[ "$built_upstream" == "aucun" ]]; then
    echo "Résultat: BUILD_REQUIS (aucun kernel ${KERNEL_NAME_SUFFIX} trouvé)"
    exit 10
  fi

  if version_gt "$latest" "$built_upstream"; then
    echo "Résultat: BUILD_REQUIS (${latest} > ${built_upstream})"
    exit 10
  fi

  echo "Résultat: À_JOUR (${built_upstream} >= ${latest})"
  exit 0
}

# ============================================================
# Garde-fous
# ============================================================

[[ "$(uname -s)" == "Linux" ]] || die "build natif réservé à Linux; utilise Docker sur macOS/Windows."
[[ "$EUID" -ne 0 ]] || die "ne lance pas ce script en root. Utilise ton utilisateur normal avec sudo."
[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
. /etc/os-release
is_supported_debian13_base || \
  die "prévu pour Debian 13 / VirtuaOS / AuxinuxOS Trixie. Détecté: ${PRETTY_NAME:-inconnu}"

if [[ "$MODE" == "check" && "$SOURCE" == "kernelorg" ]]; then
  run_check
fi

# ============================================================
# [1/9] Dépôt backports
# ============================================================
echo
echo "[1/9] Ajout trixie-backports si absent..."

sudo mkdir -p /etc/apt/sources.list.d

if [[ ! -f /etc/apt/sources.list.d/trixie-backports.sources ]]; then
  sudo tee /etc/apt/sources.list.d/trixie-backports.sources > /dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi

sudo apt update

if [[ "$MODE" == "check" ]]; then
  run_check
fi

# ============================================================
# [2/9] Dépendances
# ============================================================
echo
echo "[2/9] Installation des dépendances..."

COMMON_DEPS=(
  build-essential fakeroot bc bison flex
  libssl-dev libelf-dev libdw-dev dwarves
  cpio rsync xz-utils kmod zstd
  debhelper dpkg-dev python3 tar gzip wget
  gnupg dirmngr ca-certificates   # vérification GPG du source kernel.org
)

# Dépendances de build OpenZFS (modules uniquement, --with-config=kernel,
# empaquetage NATIF Debian via native-deb-kmod / dpkg-buildpackage).
ZFS_DEPS=(
  autoconf automake libtool gawk
  uuid-dev libblkid-dev libudev-dev
  zlib1g-dev libaio-dev libattr1-dev libffi-dev
  python3-dev python3-setuptools
  debhelper dh-python po-debconf      # packaging .deb natif (pas d'alien/rpm)
)
if [[ "$WITH_ZFS" == "1" ]]; then
  COMMON_DEPS+=("${ZFS_DEPS[@]}")
fi

if [[ "$SOURCE" == "debian" ]]; then
  # Détection de KERNEL_MAJOR si auto
  if [[ "${KERNEL_MAJOR}" == "auto" ]]; then
    echo "Détection de la dernière linux-source disponible dans backports..."
    KERNEL_MAJOR="$(apt-cache pkgnames linux-source- 2>/dev/null \
        | grep -E '^linux-source-[0-9]+\.[0-9]+$' \
        | sed 's/^linux-source-//' \
        | sort -V | tail -n1)"
    [[ -n "$KERNEL_MAJOR" ]] || \
      die "impossible de détecter linux-source. Définis KERNEL_MAJOR (ex: KERNEL_MAJOR=6.12)."
    echo "Source détectée: linux-source-${KERNEL_MAJOR}"
  fi

  sudo apt install -y "${COMMON_DEPS[@]}" \
    "${ARCH_DEPS[@]}" \
    "linux-source-${KERNEL_MAJOR}/trixie-backports"

else
  # kernelorg: pas besoin du paquet linux-source, juste les outils
  sudo apt install -y "${COMMON_DEPS[@]}" "${ARCH_DEPS[@]}"
fi

# ============================================================
# [3/9] Récupération du source kernel
# ============================================================
echo
echo "[3/9] Récupération du source kernel (source=${SOURCE})..."

sudo mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$BUILD_ROOT"
cd "$BUILD_ROOT"

if [[ "$SOURCE" == "debian" ]]; then
  # --- Source Debian ---
  SOURCE_TAR="/usr/src/linux-source-${KERNEL_MAJOR}.tar.xz"
  [[ -f "$SOURCE_TAR" ]] || die "source introuvable: $SOURCE_TAR"

  SOURCE_PKG_VERSION="$(dpkg-query -W -f='${Version}' "linux-source-${KERNEL_MAJOR}")"
  _noepoch="${SOURCE_PKG_VERSION#*:}"
  KERNEL_VERSION="${KERNEL_VERSION:-${_noepoch%%-*}}"

  echo "Source paquet : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})"
  echo "Version kernel: ${KERNEL_VERSION}"

  rm -rf "linux-source-${KERNEL_MAJOR}"
  rm -f ./*.deb ./*.changes ./*.buildinfo
  echo "Extraction de $SOURCE_TAR..."
  tar -xf "$SOURCE_TAR"
  SOURCE_DIR="${BUILD_ROOT}/linux-source-${KERNEL_MAJOR}"

else
  # --- Source kernel.org ---

  # Détermine KERNEL_MAJOR et KERNEL_VERSION
  if [[ "${KERNEL_MAJOR}" == "auto" && -z "${KERNEL_VERSION:-}" ]]; then
    echo "Détection kernel.org (${RELEASE_CHANNEL}${RELEASE_BRANCH:+, branche ${RELEASE_BRANCH}})..."
    LATEST="$(latest_kernelorg_selected)"
    [[ -n "$LATEST" ]] || \
      die "impossible de détecter la version sur kernel.org. Définis KERNEL_VERSION (ex: KERNEL_VERSION=6.12.31)."
    KERNEL_VERSION="$LATEST"
    echo "Version détectée: ${KERNEL_VERSION}"
  elif [[ -z "${KERNEL_VERSION:-}" ]]; then
    die "KERNEL_VERSION requis avec source=kernelorg quand KERNEL_MAJOR est défini. Ex: KERNEL_VERSION=6.12.31"
  fi

  # Déduit KERNEL_MAJOR depuis KERNEL_VERSION si besoin (ex: 6.12.31 -> 6.12)
  KERNEL_MAJOR="${KERNEL_MAJOR:-$(echo "$KERNEL_VERSION" | cut -d. -f1,2)}"
  [[ "${KERNEL_MAJOR}" != "auto" ]] || \
    KERNEL_MAJOR="$(echo "$KERNEL_VERSION" | cut -d. -f1,2)"

  MAJOR_NUM="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
  if [[ "$KERNEL_VERSION" == *-rc* ]]; then
    # kernel.org publie les RC de Linus comme snapshots git, sans .tar.sign.
    TARBALL="linux-${KERNEL_VERSION}.tar.gz"
    TARBALL_SIG=""
    DOWNLOAD_URL="https://git.kernel.org/torvalds/t/${TARBALL}"
    SIG_URL=""
    [[ "$ALLOW_UNVERIFIED_SOURCE" == "1" ]] || die \
      "mainline ${KERNEL_VERSION} est un snapshot git sans signature tarball. Relance avec ALLOW_UNVERIFIED_SOURCE=1 pour un build de développement explicite."
  else
    TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    TARBALL_SIG="linux-${KERNEL_VERSION}.tar.sign"
    KERNELORG_SERIES_URL="${KERNELORG_BASE_URL}/v${MAJOR_NUM}.x"
    DOWNLOAD_URL="${KERNELORG_SERIES_URL}/${TARBALL}"
    SIG_URL="${KERNELORG_SERIES_URL}/${TARBALL_SIG}"
  fi

  echo "Téléchargement: ${DOWNLOAD_URL}"

  rm -rf "linux-${KERNEL_VERSION}"
  rm -f ./*.deb ./*.changes ./*.buildinfo

  # Télécharge seulement si pas déjà là (pratique pour relancer)
  if [[ ! -f "${TARBALL}" ]]; then
    wget -c --show-progress "${DOWNLOAD_URL}" -O "${TARBALL}"
  else
    echo "Tarball déjà présent, réutilisation: ${TARBALL}"
  fi

  # Vérification de signature OBLIGATOIRE du tarball kernel.org.
  if [[ "$ALLOW_UNVERIFIED_SOURCE" == "1" ]]; then
    echo "AVERTISSEMENT: ALLOW_UNVERIFIED_SOURCE=1 — vérification GPG de la source IGNORÉE (déconseillé)."
  else
    echo "Vérification de la signature du source kernel.org..."
    if [[ ! -f "${TARBALL_SIG}" ]]; then
      wget -q "${SIG_URL}" -O "${TARBALL_SIG}" \
        || die "impossible de télécharger la signature ${SIG_URL}.
Le source ne peut pas être vérifié. Pour passer outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_SOURCE=1"
    fi
    verify_kernel_tarball "${TARBALL}" "${TARBALL_SIG}"
  fi

  echo "Extraction..."
  tar -xf "${TARBALL}"
  SOURCE_DIR="${BUILD_ROOT}/linux-${KERNEL_VERSION}"
  SOURCE_PKG_VERSION="kernel.org"
fi

# ============================================================
# [4/9] Config de base
# ============================================================
echo
echo "[4/9] Sélection de la config de base..."

cd "$SOURCE_DIR"

pick_base_config() {
  local c
  # 1) config Debian dont le nom contient la version detectee
  for c in /boot/config-"${KERNEL_VERSION}"*-amd64; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  # 2) la config amd64 la plus recente presente
  c="$(ls -1 /boot/config-*-amd64 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
  # 3) le kernel courant
  [[ -f "/boot/config-$(uname -r)" ]] && { echo "/boot/config-$(uname -r)"; return 0; }
  return 1
}

BASE_CONFIG="$(pick_base_config || true)"

if [[ "$KBUILD_DEBARCH" != "amd64" ]]; then
  echo "Architecture cible non-amd64 (${KBUILD_DEBARCH}); utilisation de make defconfig."
  make "${MAKE_ARCH_ARGS[@]}" defconfig
elif [[ -n "${BASE_CONFIG}" ]]; then
  cp "$BASE_CONFIG" .config
  echo "Config de base: $BASE_CONFIG"
else
  # Pas de config Debian dans /boot (cas typique en conteneur Docker).
  # On installe le kernel de référence Debian pour obtenir une VRAIE config
  # amd64. IMPORTANT: on n'utilise PAS /proc/config.gz en priorité — dans un
  # conteneur c'est la config de l'hôte (LinuxKit/Docker Desktop), sans
  # VIRTUALIZATION ni KVM, ce qui casse le build hyperviseur.
  echo "Aucune config Debian dans /boot; installation du kernel de référence..."
  sudo apt install -y linux-image-amd64 linux-headers-amd64 \
    || sudo apt install -y -t trixie-backports linux-image-amd64 linux-headers-amd64 \
    || true
  BASE_CONFIG="$(pick_base_config || true)"
  if [[ -n "${BASE_CONFIG}" ]]; then
    cp "$BASE_CONFIG" .config
    echo "Config de base: $BASE_CONFIG"
  elif [[ -f /proc/config.gz ]]; then
    echo "AVERTISSEMENT: aucune config Debian; repli sur /proc/config.gz (config hôte,"
    echo "  potentiellement incomplète). Les options critiques seront re-forcées ensuite."
    zcat /proc/config.gz > .config
  else
    die "impossible de trouver une config kernel de base (ni /boot, ni paquet Debian, ni /proc/config.gz)."
  fi
fi

LOCAL_VERSION="-${KERNEL_NAME_SUFFIX}"
PKG_VERSION="${KERNEL_VERSION}-${KERNEL_NAME_SUFFIX}.${VIRTUA_BUILD_NUMBER}"

echo
echo "============================================================"
echo " Virtua Kernel Builder"
echo " Source        : ${SOURCE}"
echo " Profile       : ${PROFILE}"
echo " Target arch   : ${TARGET_ARCH} (kernel ARCH=${KBUILD_ARCH}, deb=${KBUILD_DEBARCH})"
echo " Cross compile : ${CROSS_COMPILE:-none}"
echo " Source pkg    : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})"
echo " Kernel cible  : ${KERNEL_VERSION}${LOCAL_VERSION}"
echo " Version dpkg  : ${PKG_VERSION}"
echo " Meta paquet   : ${META_PACKAGE}"
echo " Build root    : ${BUILD_ROOT}"
echo " Output dir    : ${OUTPUT_DIR}"
echo " Jobs          : ${JOBS}"
echo "============================================================"

# Adapte la config empruntee a CETTE version du source
make "${MAKE_ARCH_ARGS[@]}" olddefconfig

# ============================================================
# [5/9] Configuration AuxiNux
# ============================================================
echo
echo "[5/9] Application de la configuration AuxiNux (${PROFILE})..."

# --- Nom du kernel ---
# CONFIG_LOCALVERSION fournit le suffixe.
# LOCALVERSION="" vide passé à make évite:
#   - le doublement du suffixe custom
#   - le "+" parasite sur arbres type git
cfg --set-str LOCALVERSION "$LOCAL_VERSION"
cfg --disable LOCALVERSION_AUTO

# --- Pas de clés de signature hors infra Debian ---
cfg --set-str SYSTEM_TRUSTED_KEYS ""
cfg --set-str SYSTEM_REVOCATION_KEYS ""

# --- Réduction de taille (gain principal) ---
cfg --disable DEBUG_INFO
cfg --disable DEBUG_INFO_BTF

if [[ "$PROFILE" == "virtua" ]]; then

# --- KVM / QEMU / virtualisation ---
cfg --enable VIRTUALIZATION     # porte menu x86: sans elle, KVM est ignore
cfg --enable KVM
cfg --module KVM_INTEL          # module: ne charge que sur hote Intel
cfg --module KVM_AMD            # module: ne charge que sur hote AMD
cfg --enable KVM_XEN
cfg --enable VFIO
cfg --enable VFIO_PCI
cfg --enable VFIO_IOMMU_TYPE1
cfg --enable VFIO_MDEV
cfg --enable IOMMUFD           # interface moderne QEMU/VFIO
cfg --enable VFIO_DEVICE_CDEV  # exposition VFIO via iommufd
cfg --enable PCI_STUB           # bind device pour passthrough
cfg --enable IOMMU_SUPPORT
cfg --enable INTEL_IOMMU
cfg --enable AMD_IOMMU
cfg --enable IRQ_REMAP

# --- Perf hyperviseur ---
cfg --enable KSM                # dedup memoire entre VMs
cfg --enable TRANSPARENT_HUGEPAGE
cfg --enable HUGETLBFS
cfg --enable HUGETLB_PAGE

# --- VirtIO / vhost ---
cfg --enable VIRTIO
cfg --enable VIRTIO_PCI
cfg --enable VIRTIO_BLK
cfg --enable VIRTIO_NET
cfg --enable VIRTIO_CONSOLE
cfg --enable VIRTIO_BALLOON
cfg --enable VIRTIO_INPUT
cfg --enable VIRTIO_FS
cfg --enable VIRTIO_MEM        # hotplug mémoire des VMs
cfg --module VIRTIO_PMEM       # mémoire persistante VirtIO
cfg --enable VHOST
cfg --enable VHOST_NET
cfg --enable VHOST_VSOCK
cfg --enable VHOST_SCSI
cfg --enable VHOST_IOTLB
cfg --module VHOST_VDPA
cfg --enable VSOCKETS
cfg --enable VIRTIO_VSOCKETS

# --- Réseau hyperviseur ---
cfg --enable TUN
cfg --enable TAP
cfg --enable MACVLAN
cfg --enable MACVTAP             # interfaces macvtap pour VMs
cfg --enable IPVLAN
cfg --enable BRIDGE
cfg --enable VLAN_8021Q
cfg --module VXLAN
cfg --module GENEVE
cfg --enable BONDING
cfg --module OPENVSWITCH
cfg --enable NETFILTER
cfg --enable NF_TABLES
cfg --enable NET_SCHED
cfg --enable NET_CLS_CGROUP

# --- LXC / Docker / containers ---
cfg --enable CGROUPS
cfg --enable CGROUP_BPF
cfg --enable CGROUP_FREEZER
cfg --enable CGROUP_PIDS
cfg --enable CGROUP_DEVICE
cfg --enable CGROUP_SCHED
cfg --enable FAIR_GROUP_SCHED
cfg --enable CFS_BANDWIDTH
cfg --enable CGROUP_CPUACCT
cfg --enable CGROUP_PERF
cfg --enable CGROUP_HUGETLB
cfg --enable BLK_CGROUP
cfg --enable BLK_CGROUP_IOCOST
cfg --enable CPUSETS
cfg --enable MEMCG
cfg --enable PSI
cfg --enable NAMESPACES
cfg --enable USER_NS
cfg --enable NET_NS
cfg --enable PID_NS
cfg --enable IPC_NS
cfg --enable UTS_NS
cfg --enable CGROUP_NS
cfg --enable TIME_NS
cfg --enable OVERLAY_FS
cfg --enable SECCOMP
cfg --enable SECCOMP_FILTER
cfg --enable VETH               # paires veth: indispensable Docker/LXC
cfg --enable CHECKPOINT_RESTORE # migration et restauration CRIU/LXC
cfg --enable POSIX_MQUEUE
cfg --enable KEYS
cfg --enable DEVTMPFS
cfg --enable BPF_SYSCALL
cfg --enable BPF_JIT
cfg --enable SECURITY_APPARMOR

# --- Réseau containers (NAT Docker) ---
cfg --enable BRIDGE_NETFILTER
cfg --enable NF_CONNTRACK
cfg --enable NF_NAT
cfg --enable NETFILTER_XT_MATCH_ADDRTYPE
cfg --enable NETFILTER_XT_MATCH_CONNTRACK
cfg --enable IP_NF_IPTABLES
cfg --enable IP_NF_FILTER
cfg --enable IP_NF_NAT
cfg --enable IP_NF_TARGET_MASQUERADE
cfg --enable NFT_NAT
cfg --enable NFT_MASQ

# --- Wi-Fi / Bluetooth pour hosts Virtua raccordés en sans-fil ---
# Le host doit rester capable de monter un lien radio même s'il n'est pas filaire.
cfg --enable RFKILL
cfg --module CFG80211
cfg --module MAC80211
cfg --module BT

# --- Stockage hyperviseur ---
cfg --enable BLK_DEV_DM
cfg --enable DM_THIN_PROVISIONING
cfg --enable DM_SNAPSHOT
cfg --enable DM_CACHE
cfg --enable MD
cfg --enable BLK_DEV_NVME
cfg --enable NVME_CORE
cfg --module NFS_FS
cfg --module CIFS
cfg --enable FUSE_FS
cfg --module SQUASHFS
cfg --module AUTOFS_FS

# --- Filesystems ---
cfg --enable EXT4_FS            # frequent comme racine -> built-in
cfg --module BTRFS_FS
cfg --module XFS_FS
cfg --module F2FS_FS

# --- GPU lourds inutiles pour hyperviseur headless ---
cfg --disable DRM_AMDGPU
cfg --disable DRM_NOUVEAU
cfg --disable DRM_RADEON
cfg --disable DRM_XE
cfg --disable DRM_I915

else

# --- Desktop / VM desktop ---
# Le profil desktop reste proche de la config Debian et ne retire pas les GPU.
cfg --enable VIRTIO
cfg --enable VIRTIO_PCI
cfg --enable VIRTIO_BLK
cfg --enable VIRTIO_NET
cfg --enable VIRTIO_CONSOLE
cfg --enable VIRTIO_BALLOON
cfg --enable VIRTIO_INPUT
cfg --enable VIRTIO_FS
cfg --enable VSOCKETS
cfg --enable VIRTIO_VSOCKETS

cfg --enable VIRTUALIZATION
cfg --enable KVM
cfg --module KVM_INTEL
cfg --module KVM_AMD

cfg --enable DRM
cfg --enable DRM_KMS_HELPER
cfg --module DRM_I915
cfg --module DRM_XE
cfg --module DRM_AMDGPU
cfg --module DRM_RADEON
cfg --module DRM_NOUVEAU

cfg --enable INPUT_EVDEV
cfg --enable HID
cfg --enable HID_GENERIC
cfg --enable USB_SUPPORT
cfg --enable USB_XHCI_HCD
cfg --enable SOUND
cfg --enable SND
cfg --module SND_HDA_INTEL
cfg --module BT
cfg --module CFG80211
cfg --module MAC80211

cfg --enable CGROUPS
cfg --enable NAMESPACES
cfg --enable USER_NS
cfg --enable NET_NS
cfg --enable PID_NS
cfg --enable OVERLAY_FS
cfg --enable SECCOMP
cfg --enable SECCOMP_FILTER
cfg --enable EXT4_FS
cfg --module BTRFS_FS
cfg --module XFS_FS
cfg --module F2FS_FS

if [[ "$PROFILE" == "auxinuxos" ]]; then
  # COSMIC et Wayland sont en espace utilisateur; leur prérequis noyau est un
  # chemin DRM/KMS, input, audio et radio complet.
  cfg --enable VT
  cfg --enable VT_CONSOLE
  cfg --enable FRAMEBUFFER_CONSOLE
  cfg --enable DRM_DISPLAY_HELPER
  cfg --enable DRM_FBDEV_EMULATION
  cfg --enable DRM_SIMPLEDRM
  cfg --enable BACKLIGHT_CLASS_DEVICE
  cfg --enable RFKILL
  cfg --enable WLAN

  # Principales familles Wi-Fi Intel, Qualcomm, MediaTek, Realtek et Broadcom.
  cfg --module IWLWIFI
  cfg --module IWLMVM
  cfg --module ATH10K
  cfg --module ATH10K_PCI
  cfg --module ATH11K
  cfg --module ATH11K_PCI
  cfg --module ATH12K
  cfg --module ATH12K_PCI
  cfg --module MT76
  cfg --module MT76_USB
  cfg --module MT76_CONNAC_LIB
  cfg --module RTW88
  cfg --module RTW88_PCI
  cfg --module RTW88_USB
  cfg --module RTW89
  cfg --module RTW89_PCI
  cfg --module BRCMFMAC
  cfg --module BRCMFMAC_PCIE
  cfg --module BRCMFMAC_USB
  cfg --module MWIFIEX
  cfg --module MWIFIEX_PCIE
  cfg --module MWIFIEX_USB
  cfg --module RTL8XXXU

  cfg --module BT_HCIBTUSB
  cfg --module BT_HCIUART
  cfg --enable INPUT_UINPUT
  cfg --enable INPUT_JOYDEV
  cfg --module HID_MULTITOUCH
fi

fi

# Résout les dépendances et fige la config
make "${MAKE_ARCH_ARGS[@]}" olddefconfig

# ============================================================
# [6/9] Vérification de la config finale
# ============================================================
echo
echo "[6/9] Vérification de la config finale..."

opt_on() { grep -q "^CONFIG_${1}=[ym]" .config; }

if [[ "$PROFILE" == "virtua" ]]; then
  # Sans ces options le kernel n'est pas un kernel Virtua valable.
  CRITICAL=(
    KVM VIRTIO VIRTIO_PCI VHOST_NET
    NAMESPACES USER_NS NET_NS PID_NS
    CGROUPS CGROUP_SCHED MEMCG BLK_CGROUP OVERLAY_FS SECCOMP
    BRIDGE VETH TUN EXT4_FS
    RFKILL CFG80211 MAC80211 BT
  )

  # Fortement souhaitées, on avertit seulement.
  RECOMMENDED=(
    KVM_INTEL KVM_AMD VFIO_PCI IOMMU_SUPPORT IOMMUFD VFIO_DEVICE_CDEV
    VIRTIO_NET VIRTIO_BLK VIRTIO_FS VIRTIO_MEM VHOST_VSOCK VHOST_IOTLB MACVTAP
    NF_TABLES NF_NAT IP_NF_TARGET_MASQUERADE
    CGROUP_CPUACCT CGROUP_HUGETLB CFS_BANDWIDTH PSI CHECKPOINT_RESTORE
    SECURITY_APPARMOR BTRFS_FS XFS_FS KSM TRANSPARENT_HUGEPAGE HUGETLBFS
  )
elif [[ "$PROFILE" == "desktop" ]]; then
  # Desktop: le minimum attendu est de booter correctement en bare metal ou VM.
  CRITICAL=(
    VIRTIO VIRTIO_PCI VIRTIO_NET VIRTIO_BLK
    DRM INPUT_EVDEV HID USB_SUPPORT EXT4_FS
  )

  RECOMMENDED=(
    DRM_I915 DRM_XE DRM_AMDGPU DRM_NOUVEAU DRM_RADEON
    SOUND SND SND_HDA_INTEL BT CFG80211 MAC80211
    BTRFS_FS XFS_FS OVERLAY_FS SECCOMP
  )
else
  CRITICAL=(
    DRM DRM_KMS_HELPER INPUT_EVDEV HID USB_SUPPORT
    SOUND SND RFKILL WLAN CFG80211 MAC80211 BT EXT4_FS
  )

  RECOMMENDED=(
    DRM_I915 DRM_XE DRM_AMDGPU DRM_NOUVEAU DRM_RADEON
    DRM_SIMPLEDRM DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE
    SND_HDA_INTEL BT_HCIBTUSB
    IWLWIFI ATH10K ATH11K ATH12K MT76 RTW88 RTW89 BRCMFMAC
    BTRFS_FS XFS_FS OVERLAY_FS SECCOMP
  )
fi

missing_crit=()
for o in "${CRITICAL[@]}"; do
  opt_on "$o" || missing_crit+=("$o")
done

missing_reco=()
for o in "${RECOMMENDED[@]}"; do
  opt_on "$o" || missing_reco+=("$o")
done

(( ${#missing_reco[@]} == 0 )) || \
  echo "AVERTISSEMENT: options recommandées absentes: ${missing_reco[*]}"

(( ${#missing_crit[@]} == 0 )) || \
  die "options CRITIQUES absentes après olddefconfig: ${missing_crit[*]}
Vérifie le .config et les dépendances. Build interrompu."

echo "Config OK — toutes les options critiques sont présentes."

# ============================================================
# [7/9] Compilation
# ============================================================
echo
echo "[7/9] Compilation du kernel (peut être long)..."
echo "Log conseillé: ./build-kernel-core.sh 2>&1 | tee ~/virtua-kernel.log"

# BUILD_ROOT est réutilisé entre profils. Supprime uniquement les artefacts de
# packaging à sa racine pour empêcher un ancien build d'être recopié/publié.
rm -f "$BUILD_ROOT"/*.deb "$BUILD_ROOT"/*.buildinfo "$BUILD_ROOT"/*.changes

# LOCALVERSION="" (vide mais défini):
#   - suffixe vient de CONFIG_LOCALVERSION uniquement -> pas de doublement
#   - supprime le "+" parasite sur arbres git
make "${MAKE_ARCH_ARGS[@]}" -j"$JOBS" bindeb-pkg \
  LOCALVERSION="" \
  KDEB_PKGVERSION="$PKG_VERSION" \
  KDEB_COMPRESS="zstd"

# ============================================================
# [7b/9] Modules OpenZFS appariés au kernel (modèle Proxmox)
# ============================================================
# On compile OpenZFS CONTRE l'arbre kernel qu'on vient de builder, puis on
# empaquette les modules en kmod-zfs-<release>. Plus de DKMS à l'install,
# plus de désappariement: ZFS et kernel voyagent ensemble.
if [[ "$WITH_ZFS" == "1" ]]; then
  echo
  echo "[7b/9] Construction des modules OpenZFS ${ZFS_VERSION} contre le kernel..."

  ZFS_TARBALL="zfs-${ZFS_VERSION}.tar.gz"
  ZFS_URL="${ZFS_BASE_URL}/zfs-${ZFS_VERSION}/${ZFS_TARBALL}"
  ZFS_SRC_DIR="${BUILD_ROOT}/zfs-${ZFS_VERSION}"

  cd "$BUILD_ROOT"

  if [[ ! -f "$ZFS_TARBALL" ]]; then
    echo "Téléchargement: ${ZFS_URL}"
    wget -c --show-progress "$ZFS_URL" -O "$ZFS_TARBALL"
  else
    echo "Tarball ZFS déjà présent, réutilisation: ${ZFS_TARBALL}"
  fi

  # Vérification d'intégrité de la source ZFS (sha256 épinglé, OBLIGATOIRE).
  if [[ "$ALLOW_UNVERIFIED_SOURCE" == "1" ]]; then
    echo "AVERTISSEMENT: vérification du source ZFS IGNORÉE (ALLOW_UNVERIFIED_SOURCE=1)."
  elif [[ -n "$ZFS_SHA256" ]]; then
    echo "Vérification sha256 du source ZFS..."
    echo "${ZFS_SHA256}  ${ZFS_TARBALL}" | sha256sum -c - \
      || die "sha256 du tarball ZFS invalide. Source corrompue ou ZFS_SHA256 erroné."
  else
    die "ZFS_SHA256 non défini.
Fournis le sha256 de ${ZFS_TARBALL} (page de release OpenZFS), ex:
  ZFS_SHA256=<hash> ./build-kernel-core.sh ...
Ou passe outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_SOURCE=1"
  fi

  rm -rf "$ZFS_SRC_DIR"
  tar -xf "$ZFS_TARBALL"
  [[ -d "$ZFS_SRC_DIR" ]] || die "extraction ZFS échouée: $ZFS_SRC_DIR introuvable."

  # Le packaging natif OpenZFS (debian/rules) RE-configure et cherche le kernel
  # dans /lib/modules/<KVERS>/build. On installe donc nos propres headers (déjà
  # buildés) pour exposer cet arbre, puis on cible explicitement notre version
  # via KVERS — sinon il prend `uname -r` (le kernel de l'hôte LXC, absent).
  ZFS_KVERS="${KERNEL_VERSION}${LOCAL_VERSION}"   # ex: 7.0.12-auxinux-virtua-amd64
  ZFS_HDR_DEB="$(ls "$BUILD_ROOT"/linux-headers-"${ZFS_KVERS}"_*.deb 2>/dev/null | head -n1 || true)"
  [[ -n "$ZFS_HDR_DEB" ]] \
    || die "headers .deb introuvable pour ZFS (linux-headers-${ZFS_KVERS}_*.deb dans $BUILD_ROOT)."
  echo "Installation des headers du kernel cible pour ZFS: $(basename "$ZFS_HDR_DEB")"
  sudo dpkg -i "$ZFS_HDR_DEB" || sudo apt-get -f install -y
  [[ -d "/lib/modules/${ZFS_KVERS}/build" ]] \
    || die "/lib/modules/${ZFS_KVERS}/build absent après install des headers."

  cd "$ZFS_SRC_DIR"

  # configure initial: génère contrib/debian/rules, ciblé sur notre kernel.
  echo "Configuration OpenZFS contre /lib/modules/${ZFS_KVERS}/build..."
  ./configure \
    --with-config=kernel \
    --with-linux="/lib/modules/${ZFS_KVERS}/build" \
    --with-linux-obj="/lib/modules/${ZFS_KVERS}/build" \
    --prefix=/usr

  echo "Compilation des paquets kmod ZFS (natif Debian, KVERS=${ZFS_KVERS})..."
  # native-deb-kmod = paquets .deb NATIFS via dpkg-buildpackage (PAS alien/rpm).
  # KVERS/KSRC exportés ET passés à make pour que debian/rules cible NOTRE kernel.
  export KVERS="$ZFS_KVERS" KSRC="/lib/modules/${ZFS_KVERS}/build"
  make -j"$JOBS" native-deb-kmod \
    KVERS="$ZFS_KVERS" \
    KSRC="/lib/modules/${ZFS_KVERS}/build"

  # dpkg-buildpackage écrit les .deb dans le dossier PARENT (= BUILD_ROOT),
  # donc ils sont déjà au bon endroit pour l'étape [8/9]. On valide juste.
  cd "$BUILD_ROOT"
  shopt -s nullglob
  zfs_debs=( "$BUILD_ROOT"/*zfs-modules*.deb "$BUILD_ROOT"/kmod-zfs*.deb )
  shopt -u nullglob
  (( ${#zfs_debs[@]} > 0 )) \
    || die "aucun paquet .deb module ZFS trouvé dans $BUILD_ROOT après native-deb-kmod."

  echo "Modules ZFS générés:"
  for z in "${zfs_debs[@]}"; do echo "  $(basename "$z")"; done
else
  echo
  echo "[7b/9] Modules OpenZFS: désactivé (WITH_ZFS=${WITH_ZFS})."
fi

# ============================================================
# [8/9] Validation et copie
# ============================================================
echo
echo "[8/9] Validation et copie des paquets..."

cd "$BUILD_ROOT"

shopt -s nullglob
debs=( ./*.deb )
shopt -u nullglob

(( ${#debs[@]} > 0 )) || die "aucun paquet .deb généré dans $BUILD_ROOT"

# OUTPUT_DIR peut contenir plusieurs profils/architectures. On conserve les
# autres builds pour pouvoir publier virtua + desktop ensemble.

echo
echo "Noms internes des paquets générés:"
for pkg in "${debs[@]}"; do
  echo "------------------------------------------------------------"
  echo "$(basename "$pkg")"
  dpkg-deb -f "$pkg" Package Version Architecture
done

echo
echo "Copie vers OUTPUT_DIR..."
for pkg in "${debs[@]}"; do
  pkg_name="$(dpkg-deb -f "$pkg" Package)"
  pkg_arch="$(dpkg-deb -f "$pkg" Architecture)"
  pkg_version="$(dpkg-deb -f "$pkg" Version)"

  if [[ "$pkg_name" == "linux-libc-dev" ]]; then
    echo "SKIP $(basename "$pkg") (linux-libc-dev reste fourni par Debian)"
    rm -f "$OUTPUT_DIR/${pkg_name}"_*_"${pkg_arch}".deb \
          "$OUTPUT_DIR/${pkg_name}-${KERNEL_NAME_SUFFIX}.deb"
    continue
  fi

  # linux-image-*/linux-headers-*/les modules ZFS encodent déjà la release
  # kernel complète (ex: linux-image-7.0.12-auxinuxos-amd64) dans leur nom de
  # paquet: pas besoin de suffixe. Les autres paquets (ex: un futur meta) n'ont
  # pas cette unicité intégrée et pourraient sinon se recouvrir entre profils.
  case "$pkg_name" in
    linux-image-*|linux-headers-*|openzfs-zfs-modules-*|zfs-modules-*|kmod-zfs-*)
      dest_name="${pkg_name}.deb"
      ;;
    *)
      dest_name="${pkg_name}-${KERNEL_NAME_SUFFIX}-${pkg_arch}.deb"
      ;;
  esac

  # Nettoie les anciens noms canoniques longs et l'ancien nom court.
  rm -f "$OUTPUT_DIR/${pkg_name}"_*_"${pkg_arch}".deb "$OUTPUT_DIR/${dest_name}"
  cp -v "$pkg" "$OUTPUT_DIR/${dest_name}"
done

# Le label et l'URL APT dépendent du profil: virtua/desktop sont publiés sous
# le dépôt VIRTUA (voir build-depot-kernel-core.sh), auxinuxos a son propre
# dépôt dédié (voir build-depot-AuxiNuxOS.sh).
case "$PROFILE" in
  auxinuxos)
    README_REPO_LABEL="AuxiNuxOS Kernel Repository"
    README_APT_URL="https://dep.auxinux.ca/AUXINUXOS/KERNEL"
    ;;
  *)
    README_REPO_LABEL="AuxiNux Kernel Repository"
    README_APT_URL="https://dep.auxinux.ca/VIRTUA"
    ;;
esac

cat > "$OUTPUT_DIR/README-${KERNEL_NAME_SUFFIX}.txt" <<EOF
${README_REPO_LABEL}
$(printf '=%.0s' $(seq 1 ${#README_REPO_LABEL}))

Kernel    : Linux ${KERNEL_VERSION}${LOCAL_VERSION}
Version   : ${PKG_VERSION}
Source    : ${SOURCE}
Profile   : ${PROFILE}
Arch      : ${TARGET_ARCH} (${KBUILD_DEBARCH})
Base src  : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})
OpenZFS   : $([[ "$WITH_ZFS" == "1" ]] && echo "${ZFS_VERSION} (modules appariés kmod-zfs)" || echo "non inclus")
Généré    : $(date -Iseconds)

APT source:
deb [trusted=yes arch=${KBUILD_DEBARCH}] ${README_APT_URL} kernel main

Installation:
  sudo apt update
  sudo apt install ${META_PACKAGE}

Installation directe sans paquet meta:
  sudo apt install linux-image-${KERNEL_VERSION}${LOCAL_VERSION} linux-headers-${KERNEL_VERSION}${LOCAL_VERSION}

Après reboot:
  uname -r   # attendu: ${KERNEL_VERSION}${LOCAL_VERSION}
EOF

# ============================================================
# [9/9] Terminé
# ============================================================
echo
echo "[9/9] Terminé."
echo
echo "Paquets générés:"
ls -lh "$OUTPUT_DIR"
echo
echo "Envoi vers le serveur dépôt:"
echo "  rsync -avz --progress ${OUTPUT_DIR}/ debian@dep.auxinux.ca:/tmp/virtua-kernel/"
echo "Puis sur dep.auxinux.ca:"
echo "  sudo ./build-depot-kernel.sh /tmp/virtua-kernel"
echo
echo "Kernel attendu après install: ${KERNEL_VERSION}${LOCAL_VERSION}"
echo "============================================================"

if [[ "$DEPLOY" == "1" ]]; then
  echo
  echo "Déploiement vers ${DEPLOY_TARGET}..."
  if [[ "$DEPLOY_TARGET" == *:* ]]; then
    rsync -a "${OUTPUT_DIR}/" "${DEPLOY_TARGET%/}/"
  else
    mkdir -p "$DEPLOY_TARGET"
    rsync -a "${OUTPUT_DIR}/" "${DEPLOY_TARGET%/}/"
  fi
  echo "  OK"
fi
