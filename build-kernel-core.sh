#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# AuxiNux Kernel Builder
# profile=auxinuxos : station DESKTOP AuxiNuxOS (COSMIC/Wayland)
#                     + LXC/Docker + KVM, rollback BTRFS, ZRAM,
#                     GPU Intel/AMD/NVIDIA, bureautique/multimédia/jeu
# profile=virtua    : hyperviseur Virtua (KVM/QEMU + LXC + Docker)
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

die() { echo; echo "ERREUR: $*" >&2; exit 1; }

SOURCE="kernelorg"
MODE="build"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-current}"
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

# Canal de publication: "prod" (defaut) ou "dev". Le canal dev produit un
# kernel au suffixe dev-<flavour>, un meta <meta>-dev, et est publie dans une
# suite APT distincte (kernel-dev) par build-depot-kernel-core.sh. Les deux
# canaux peuvent donc etre installes cote a cote et selectionnes au boot.
RELEASE_TRACK="${RELEASE_TRACK:-prod}"

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

# --- OpenZFS: paquet source DKMS (modèle Debian, pas Ubuntu) ---
# On empaquette uniquement la SOURCE OpenZFS + son dkms.conf (openzfs-zfs-dkms,
# arch=all). La compilation du module a lieu chez l'utilisateur final via DKMS,
# jamais sur ce serveur — on ne distribue donc jamais de binaire combinant du
# code CDDL (OpenZFS) et du code GPL-2.0 (Linux), contrairement au modèle
# "module précompilé" (à la Ubuntu/Proxmox) qu'utilisait cette étape avant.
# Contrepartie: la compilation DKMS peut échouer chez l'utilisateur si les
# headers du kernel cible ne sont pas installés — d'où l'appariement strict
# avec linux-headers-<release> côté paquet meta (build-depot-kernel-core.sh).
# OpenZFS 2.4.2+ supporte le kernel 7.0 (range 4.18 -> 7.0).
# Infos de debug. 0 (defaut) = noyau leger, pas de paquet -dbg.
# 1 = DWARF + BTF, requis par l'eBPF CO-RE (bpftrace, Falco, Cilium) mais
# produit un -dbg de ~1.7 Go et rallonge sensiblement la compilation.
WITH_DEBUG_INFO="${WITH_DEBUG_INFO:-0}"

# Build à blanc: applique et VÉRIFIE la configuration, puis s'arrête avant la
# compilation. C'est le mode à utiliser pour valider une nouvelle série de
# noyaux (7.1 -> 7.2) sans payer une heure de compilation pour découvrir
# qu'un symbole a été renommé.
CONFIG_ONLY="${CONFIG_ONLY:-0}"

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
# Le choix du canal mainline force le saut de verification du TARBALL KERNEL
# (snapshot git sans .tar.sign), ce qui ne doit PAS desactiver la verification
# sha256 d'OpenZFS: les deux sources n'ont aucun rapport.
ALLOW_UNVERIFIED_KERNEL_SOURCE="${ALLOW_UNVERIFIED_KERNEL_SOURCE:-$ALLOW_UNVERIFIED_SOURCE}"
ALLOW_UNVERIFIED_ZFS_SOURCE="${ALLOW_UNVERIFIED_ZFS_SOURCE:-$ALLOW_UNVERIFIED_SOURCE}"

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
      AuxiNuxOS DESKTOP workstation kernel: COSMIC/Wayland on bare metal or in
      a VM, tuned for office, multimedia and gaming on the same machine, with
      LXC/Docker and KVM kept intact.
      Includes: Intel/AMD/NVIDIA GPU stack, ZRAM, MGLRU, PSI (systemd-oomd),
      full preemption at 1000 Hz, BFQ, ntsync (Wine/Proton), game controllers,
      SOF audio, and the built-ins required by the AuxiNuxOS BTRFS rollback.
      Produces: X.X.X-auxinuxos-ARCH
      Recommended meta-package: kernel-auxinuxos
      Supported architectures: amd64, arm64.

  profile=all  (alias: PROFILES="virtua desktop", profile=virtua,desktop)
      Build virtua THEN desktop for the same architecture, one after another.
      On non-amd64 targets the virtua profile is skipped automatically.
      Other options (source, arch, KERNEL_VERSION, JOBS...) apply to both.
      Not compatible with -check-* modes (single profile only).

Canal de publication (prod/dev):
  track=prod                 Canal de production (défaut). Suffixe inchangé,
                             meta kernel-<profil>, suite APT "kernel".
  track=dev                  Canal de développement. Produit
                             X.Y.Z-dev-<flavour>-<arch>, meta kernel-<profil>-dev,
                             publié dans la suite APT "kernel-dev".
                             Les deux canaux coexistent installés: on choisit
                             le noyau à tester au boot, rollback immédiat.
  Alias: -dev / -prod

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
  WITH_DEBUG_INFO=0|1        Infos de debug DWARF + BTF. Défaut 0 (noyau léger).
                             Sans effet sur profile=auxinuxos, où BTF est
                             toujours activé (défaut Debian 13, requis par
                             l'eBPF CO-RE des conteneurs). Le paquet -dbg
                             produit au passage n'est jamais publié.
  -config-only               Build à blanc: applique et VÉRIFIE la config
                             ([6a] indexe les symboles Kconfig de l'arbre et
                             refuse tout symbole inexistant), puis s'arrête
                             avant la compilation. À utiliser à chaque
                             changement de série de noyau.
  JOBS=n                     Parallel make jobs. Default: nproc.
  BUILD_ROOT=/path           Build workspace. Default: /usr/src/auxinuxos-kernel-build.
  OUTPUT_DIR=/path           Output directory for generated .deb files.
  CHECK_DIR=/path            Directory inspected by -check-* modes.

OpenZFS (paquet source DKMS, modèle Debian):
  WITH_ZFS=auto|1|0          Build the OpenZFS DKMS source package (openzfs-zfs-dkms,
                             arch=all) alongside this kernel. Default: auto
                             (ON on native amd64, OFF when cross-compiling).
                             The module itself is compiled by DKMS on the
                             end user's machine, never on this build host.
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
  $0 profile=all                       # virtua + desktop (amd64) + paquet DKMS ZFS
  $0 profile=all -arch=arm64           # desktop seul (virtua + ZFS sautés sur arm64)
  $0 -arch=arm64
  $0 KERNEL_VERSION=6.12.31
  $0 profile=desktop -arch=arm64 KERNEL_VERSION=6.12.31 JOBS=8
  $0 source=debian KERNEL_MAJOR=6.12
  $0 profile=auxinuxos KERNEL_VERSION=7.2.5 -config-only   # build à blanc
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
    track=*|--track=*|RELEASE_TRACK=*) RELEASE_TRACK="${arg#*=}" ;;
    -dev|--dev-track) RELEASE_TRACK="dev" ;;
    -prod|--prod-track) RELEASE_TRACK="prod" ;;
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
    -config-only|--config-only|config-only) CONFIG_ONLY=1 ;;
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
  # N'affecte QUE le kernel: la verification sha256 d'OpenZFS reste active.
  ALLOW_UNVERIFIED_KERNEL_SOURCE=1
fi

case "$RELEASE_TRACK" in
  prod|dev) ;;
  *) die "RELEASE_TRACK invalide: ${RELEASE_TRACK}. Valeurs: prod, dev." ;;
esac

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
  # Canal dev: prefixe dev- (minuscule OBLIGATOIRE: la politique Debian
  # interdit les majuscules dans un nom de paquet, dpkg les convertit
  # silencieusement, ce qui desynchroniserait le nom du paquet et le
  # repertoire /lib/modules/<uname -r>) pour que la release complete soit distincte de la
  # prod (ex: 7.2.2-dev-auxinux-virtua-amd64 vs 7.1.12-auxinux-virtua-amd64).
  # Les noms de paquets different donc les deux kernels coexistent installes.
  [[ "$RELEASE_TRACK" == "dev" ]] && KERNEL_FLAVOUR="dev-${KERNEL_FLAVOUR}"
fi

KERNEL_NAME_SUFFIX="${KERNEL_FLAVOUR}-${KERNEL_ARCH_SUFFIX}"

if [[ -z "$META_PACKAGE" ]]; then
  case "$PROFILE" in
    virtua) META_PACKAGE="kernel-virtua" ;;
    desktop) META_PACKAGE="kernel-auxinux-desktop" ;;
    auxinuxos) META_PACKAGE="kernel-auxinuxos" ;;
  esac
  [[ "$RELEASE_TRACK" == "dev" ]] && META_PACKAGE="${META_PACKAGE}-dev"
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

# Table des options demandées par les blocs de configuration plus bas.
# Format: "SYMBOLE<TAB>ACTION<TAB>VALEUR_ATTENDUE". Elle est rejouée par
# l'étape [6a], qui vérifie que CHAQUE option demandée existe réellement dans
# cette version du noyau ET qu'elle a bien été retenue par olddefconfig.
CFG_REQUESTS=()

# NE JAMAIS remettre "|| true" ici.
# scripts/config accepte sans broncher un symbole inexistant: il écrit la ligne
# dans .config, qu'olddefconfig supprime ensuite en silence. Un symbole renommé
# entre deux versions du noyau devenait donc un no-op parfaitement invisible.
# Le passage de 7.1 à 7.2 en a révélé trois dans ce script (CGROUP_NS, MT76,
# ATH12K_PCI), dont deux sur le profil desktop AuxiNuxOS.
cfg() {
  local action="${1:-}" sym="${2:-}" expect
  case "$action" in
    --enable)  expect="y" ;;
    --module)  expect="m" ;;
    --disable) expect="n" ;;
    --set-str) expect="str:${3-}" ;;
    --set-val) expect="val:${3-}" ;;
    *) die "cfg(): action non supportée: '${action}' (symbole ${sym:-?})." ;;
  esac
  [[ -n "$sym" ]] || die "cfg(): symbole manquant pour l'action ${action}."
  CFG_REQUESTS+=("${sym}"$'\t'"${action}"$'\t'"${expect}")
  ./scripts/config "$@" \
    || die "scripts/config a échoué: $* (arbre source incohérent?)"
}

# Valeur réellement présente dans .config pour un symbole (diagnostic).
cfg_actual() {
  local line
  line="$(grep -m1 "^CONFIG_${1}=" .config || true)"
  if [[ -n "$line" ]]; then
    echo "${line#*=}"
  elif grep -q "^# CONFIG_${1} is not set\$" .config; then
    echo "n"
  else
    echo "non défini"
  fi
}

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

# Dépendances de build OpenZFS: native-deb-utils construit le paquetage
# Debian complet (dont openzfs-zfs-dkms), pas seulement le module — ces libs
# de dev restent nécessaires même si seul le paquet DKMS est conservé ensuite.
ZFS_DEPS=(
  autoconf automake libtool gawk
  uuid-dev libblkid-dev libudev-dev
  zlib1g-dev libaio-dev libattr1-dev libffi-dev
  libtirpc-dev                        # XDR/RPC requis par native-deb-utils
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
    [[ "$ALLOW_UNVERIFIED_KERNEL_SOURCE" == "1" ]] || die \
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
  if [[ "$ALLOW_UNVERIFIED_KERNEL_SOURCE" == "1" ]]; then
    echo "AVERTISSEMENT: vérification GPG du source kernel IGNORÉE (déconseillé)."
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
echo " Canal         : ${RELEASE_TRACK}"
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
# SYSTEM_REVOCATION_KEYS dépend de SYSTEM_REVOCATION_LIST, que la base Debian
# laisse à n: le symbole n'est alors pas émis du tout et [6a] le signale comme
# "obtenu=non défini". C'est le résultat voulu (aucune clé de révocation), pas
# une anomalie — on garde la demande au cas où la base changerait.
cfg --set-str SYSTEM_REVOCATION_KEYS ""

# --- Infos de debug et BTF --------------------------------------------------
# Depuis Linux 5.18, CONFIG_DEBUG_INFO n'est PLUS sélectionnable directement:
# c'est un bool "select" par un choice (DEBUG_INFO_NONE vs les variantes DWARF).
# Un `--disable DEBUG_INFO` était donc silencieusement annulé par olddefconfig.
# Il faut passer par l'option NONE.
#
# Sur le profil auxinuxos, BTF est activé d'office: c'est le défaut Debian 13,
# et tout l'outillage eBPF CO-RE d'observation des conteneurs (bpftrace, Docker,
# LXC) en dépend. AuxiNuxOS conserve justement Docker et LXC.
#
# ATTENTION à la contrainte Kconfig (lib/Kconfig.debug):
#     config DEBUG_INFO_BTF
#         depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
# BTF et DEBUG_INFO_REDUCED sont MUTUELLEMENT EXCLUSIFS: il faut du DWARF
# complet. Le surcoût est du temps de build et un gros vmlinux intermédiaire,
# PAS un gros vmlinuz: seul le BTF dédupliqué (~4-6 Mo) part dans l'image.
# Le paquet linux-image-*-dbg produit au passage n'est jamais publié ([8/9]).
if [[ "$PROFILE" == "auxinuxos" || "$WITH_DEBUG_INFO" == "1" ]]; then
  cfg --disable DEBUG_INFO_NONE
  cfg --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
  cfg --disable DEBUG_INFO_REDUCED
  cfg --disable DEBUG_INFO_SPLIT
  cfg --enable DEBUG_INFO_BTF
  cfg --enable DEBUG_INFO_BTF_MODULES
else
  cfg --enable DEBUG_INFO_NONE
  cfg --disable DEBUG_INFO_BTF
fi

# --- Compression: kernel et modules ----------------------------------------
cfg --enable KERNEL_ZSTD
cfg --enable MODULE_COMPRESS

# Compression des modules: xz sur le profil poste de travail, zstd ailleurs.
#
# Le noyau compresse les modules avec `zstd` SANS niveau, donc au niveau 3 par
# défaut (scripts/Makefile.modinst). Mesuré sur 300 modules du build 7.2.5:
# 13,2 Mo en zstd contre 9,4 Mo en xz, soit 29 % de plus. Sur l'arbre complet
# c'est ~60 Mo de téléchargement en plus à chaque mise à jour noyau, sur chaque
# poste — pour un gain de décompression de quelques dizaines de millisecondes
# au démarrage, réparties sur les quelques centaines de modules réellement
# chargés.
#
# Debian 13 livre ses modules en xz (vérifié sur linux-image-6.12.101+deb13:
# arbre de 104 Mo). Un noyau AuxiNuxOS « optimisé pour Debian 13 » suit ce
# réglage. Le profil hyperviseur garde zstd: il a beaucoup moins de modules et
# le compromis ne se pose pas dans les mêmes termes.
# MODULE_COMPRESS_* est un `choice`, comme PREEMPT: activer un membre ne
# désélectionne PAS l'autre, et olddefconfig garde alors celui déjà en place.
# Il faut désélectionner explicitement.
if [[ "$PROFILE" == "auxinuxos" ]]; then
  cfg --disable MODULE_COMPRESS_GZIP
  cfg --disable MODULE_COMPRESS_ZSTD
  cfg --enable MODULE_COMPRESS_XZ
else
  cfg --disable MODULE_COMPRESS_GZIP
  cfg --disable MODULE_COMPRESS_XZ
  cfg --enable MODULE_COMPRESS_ZSTD
fi

# --- Modules hors-arbre (DKMS): gardes OBLIGATOIRES -------------------------
# Sur une station AuxiNuxOS, les modules DKMS ne sont pas une hypothèse: le
# pilote NVIDIA propriétaire, VirtualBox, v4l2loopback et OpenZFS passent tous
# par là.
#
# TRIM_UNUSED_KSYMS élague les symboles exportés non utilisés en interne et
# casse la compilation de TOUT module hors-arbre. Un échec DKMS ne fait PAS
# échouer apt: l'utilisateur se retrouve avec un paquet installé, aucun module,
# et aucun message d'erreur — typiquement un poste NVIDIA qui redémarre en
# 800x600 sans que rien n'ait signalé de panne.
cfg --disable TRIM_UNUSED_KSYMS
# Un module DKMS est non signé: MODULE_SIG_FORCE l'empêcherait de charger.
cfg --disable MODULE_SIG_FORCE
cfg --enable MODVERSIONS
cfg --enable MODULE_UNLOAD

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
# VFIO_MDEV: tristate sans prompt, auto-sélectionné par les pilotes mdev.
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

elif [[ "$PROFILE" == "desktop" ]]; then

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
# DRM_KMS_HELPER suit les pilotes qui le sélectionnent: pas de cfg() dessus.
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

elif [[ "$PROFILE" == "auxinuxos" ]]; then
  # ==========================================================================
  # AuxiNuxOS — station de travail Debian 13 / COSMIC / Wayland
  # ==========================================================================
  # Cahier des charges: bureautique, multimédia et jeu sur le même noyau, sans
  # perdre LXC ni Docker, avec le rollback BTRFS d'AuxiNuxOS comme contrainte
  # de premier ordre. Tout ce qui suit est vérifié par l'étape [6a].

  # --- Affichage: console visible dès la première seconde -------------------
  # Un poste qui démarre sans pilote d'affichage n'est pas "lent", il est NOIR,
  # et c'est rapporté comme un plantage. DRM, simpledrm et le framebuffer
  # console sont donc built-in: l'écran vit avant que le moindre module soit
  # chargé, y compris quand on démarre sur un instantané de restauration.
  cfg --enable VT
  cfg --enable VT_CONSOLE
  cfg --enable FRAMEBUFFER_CONSOLE
  cfg --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
  # Plymouth reprend la main sans faire clignoter la console au passage.
  cfg --enable FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
  cfg --enable SYSFB_SIMPLEFB
  cfg --enable DRM
  cfg --enable DRM_FBDEV_EMULATION
  cfg --enable DRM_SIMPLEDRM
  cfg --enable VGA_ARB
  cfg --enable BACKLIGHT_CLASS_DEVICE
  cfg --module ACPI_VIDEO

  # --- GPU Intel ------------------------------------------------------------
  # i915 couvre de Gen2 à Meteor Lake, xe prend Lunar Lake / Battlemage et la
  # suite. Les deux coexistent: chacun se lie aux PCI ID qu'il revendique.
  # En MODULES, obligatoirement: ces pilotes réclament du firmware dans
  # /lib/firmware à l'initialisation, qu'un pilote built-in ne peut pas
  # attendre. C'est aussi ce que fait Debian.
  cfg --module DRM_I915
  cfg --module DRM_XE

  # --- GPU AMD --------------------------------------------------------------
  # DRM_AMD_DC (Display Core) n'est pas optionnel sur AMD moderne: sans lui,
  # amdgpu se charge mais ne pilote aucun écran sur tout ce qui est postérieur
  # à Vega — écran noir avec le bon pilote en mémoire.
  cfg --module DRM_AMDGPU
  cfg --enable DRM_AMD_DC
  cfg --enable DRM_AMDGPU_USERPTR
  # SI/CIK: GCN 1 et 2 (HD 7000, R7/R9 200/300, APU Kaveri). Sans ces deux
  # options, ces cartes retombent sur radeon — et RADV, le pilote Vulkan de
  # Mesa, ne fonctionne qu'au-dessus d'amdgpu.
  cfg --enable DRM_AMDGPU_SI
  cfg --enable DRM_AMDGPU_CIK
  # radeon reste pour TeraScale (HD 2000-6000), antérieur à GCN.
  cfg --module DRM_RADEON

  # --- GPU NVIDIA -----------------------------------------------------------
  # Deux chemins, tous deux à préserver:
  #  1. nouveau, libre, dans l'arbre — le pilote par défaut à l'installation.
  #  2. le pilote propriétaire NVIDIA, hors arbre, compilé par DKMS chez
  #     l'utilisateur. Il ne dépend d'aucune option DRM_NVIDIA (il n'y en a
  #     pas) mais EXIGE les gardes DKMS du bloc commun plus haut:
  #     TRIM_UNUSED_KSYMS=n, MODULE_SIG_FORCE=n, MODVERSIONS=y, MODULE_UNLOAD=y
  #     — plus DRM_FBDEV_EMULATION pour nvidia-drm.modeset=1.
  cfg --module DRM_NOUVEAU
  cfg --enable DRM_NOUVEAU_BACKLIGHT

  # --- Affichages émulés: AuxiNuxOS testé et installé en machine virtuelle ---
  cfg --module DRM_VIRTIO_GPU
  cfg --module DRM_VMWGFX
  cfg --module DRM_QXL
  cfg --module DRM_BOCHS

  # --- Entrées: clavier, souris, pavé tactile, tablette ---------------------
  # libinput ne lit QUE evdev: c'est la seule interface d'entrée qui compte
  # sous Wayland. INPUT_UINPUT est requis par les outils de remappage et
  # d'accessibilité (ydotool, wlrctl, claviers virtuels COSMIC).
  cfg --enable INPUT_EVDEV
  cfg --enable INPUT_UINPUT
  cfg --module INPUT_FF_MEMLESS
  cfg --enable HID
  cfg --enable HID_GENERIC
  cfg --enable USB_HID
  cfg --module HID_MULTITOUCH
  cfg --module I2C_HID
  cfg --module I2C_HID_ACPI
  cfg --module HID_APPLE
  cfg --module HID_WACOM
  cfg --module HID_LOGITECH
  cfg --module HID_LOGITECH_DJ
  cfg --module HID_LOGITECH_HIDPP
  cfg --module HID_MICROSOFT
  cfg --module HID_ASUS
  cfg --module HID_LENOVO
  cfg --module HID_CORSAIR
  # Clavier PS/2: encore présent sur les tours et les portables d'avant 2013,
  # et seul moyen d'atteindre le menu GRUB de restauration sur ces machines.
  cfg --enable SERIO_I8042
  cfg --enable KEYBOARD_ATKBD
  cfg --module MOUSE_PS2

  # --- Jeu: manettes --------------------------------------------------------
  # INPUT_JOYDEV fournit /dev/input/jsX, encore attendu par une partie du
  # catalogue Proton; evdev seul ne suffit pas pour ces titres.
  cfg --enable INPUT_JOYSTICK
  cfg --module INPUT_JOYDEV
  cfg --module JOYSTICK_XPAD          # Xbox 360 / One / Series
  cfg --enable JOYSTICK_XPAD_FF       # retour de force
  cfg --enable JOYSTICK_XPAD_LEDS
  cfg --module HID_SONY               # DualShock 3/4
  cfg --module HID_PLAYSTATION        # DualSense (PS5)
  cfg --module HID_NINTENDO           # Switch Pro / Joy-Con
  cfg --module HID_STEAM              # manette Steam, Steam Deck

  # --- Jeu: primitives de synchronisation NT (Wine / Proton) ----------------
  # ntsync implémente en noyau les objets de synchronisation Windows
  # (mutex, semaphore, event). Il remplace esync/fsync, qui émulaient ces
  # objets avec des eventfd et des futex: moins d'appels système et surtout
  # plus de plafond de descripteurs de fichiers à relever à la main.
  # C'est l'option "jeu" la plus rentable disponible dans un noyau 7.2.
  cfg --module NTSYNC

  # --- Audio ----------------------------------------------------------------
  # PipeWire ne remplace pas ALSA, il s'appuie dessus: sans le bon codec HDA,
  # il n'y a simplement aucun périphérique à router.
  cfg --enable SOUND
  cfg --enable SND
  cfg --enable SND_DYNAMIC_MINORS
  cfg --enable SND_SEQUENCER
  cfg --module SND_SEQ_DUMMY
  cfg --module SND_HRTIMER
  cfg --module SND_HDA_INTEL
  cfg --module SND_HDA_CODEC_REALTEK
  cfg --module SND_HDA_CODEC_HDMI
  cfg --module SND_HDA_CODEC_ANALOG
  cfg --module SND_HDA_CODEC_SIGMATEL
  cfg --module SND_HDA_CODEC_VIA
  cfg --module SND_HDA_CODEC_CONEXANT
  cfg --module SND_HDA_CODEC_CIRRUS
  cfg --module SND_HDA_CODEC_CS8409
  # Amplificateurs de haut-parleurs des portables récents (Dell, Lenovo, HP):
  # sans ces deux modules le son sort, mais à un volume inaudible.
  cfg --module SND_HDA_SCODEC_CS35L41_I2C
  cfg --module SND_HDA_SCODEC_CS35L56_I2C
  cfg --module SND_USB_AUDIO
  # SOF: toute la génération Intel post-2019 (Tiger Lake et suivants) et les
  # APU AMD récents n'ont plus de codec HDA classique. Sans SOF, ces portables
  # n'ont AUCUNE sortie audio.
  cfg --module SND_SOC
  cfg --enable SND_SOC_SOF_TOPLEVEL
  cfg --enable SND_SOC_SOF_INTEL_TOPLEVEL
  cfg --enable SND_SOC_SOF_HDA_AUDIO_CODEC
  cfg --module SND_SOC_SOF_AMD_TOPLEVEL
  cfg --module SND_SOC_INTEL_SOUNDWIRE_SOF_MACH
  cfg --module SOUNDWIRE
  cfg --module SOUNDWIRE_INTEL

  # --- Multimédia: webcam ---------------------------------------------------
  # Le décodage vidéo matériel (VA-API) passe par i915/amdgpu/nouveau, pas par
  # une option dédiée: il est déjà couvert par les blocs GPU ci-dessus.
  cfg --module MEDIA_SUPPORT
  cfg --enable MEDIA_USB_SUPPORT
  cfg --enable MEDIA_CONTROLLER
  cfg --module USB_VIDEO_CLASS
  cfg --module USB_GSPCA

  # ==========================================================================
  # Fluidité
  # ==========================================================================
  # --- Ordonnancement et préemption -----------------------------------------
  # En 7.2, sur x86, le choix du modèle de préemption a changé: x86 sélectionne
  # ARCH_HAS_PREEMPT_LAZY, ce qui rend PREEMPT_VOLUNTARY *indisponible* et fait
  # de PREEMPT_LAZY le défaut. Le seul autre choix possible est PREEMPT, la
  # préemption complète — décrite par le Kconfig comme "Low-Latency Desktop".
  #
  # On prend PREEMPT: c'est la latence la plus basse, ce qui se voit exactement
  # là où l'utilisateur regarde (pointeur sous charge, absence de coupure audio
  # PipeWire, régularité des images en jeu). Le coût est quelques pourcents de
  # débit sur une compilation.
  # PREEMPT_DYNAMIC garde la porte ouverte: `preempt=lazy` au boot rend le débit
  # sans rebuild, pour une machine qui compile plus qu'elle ne joue.
  # PREEMPT appartient à un `choice`: écrire CONFIG_PREEMPT=y ne suffit pas,
  # olddefconfig garde le membre déjà sélectionné par la config Debian de base
  # (PREEMPT_LAZY) et annule silencieusement la demande. Il faut désélectionner
  # les autres membres d'abord. Constaté au build à blanc 7.2.5:
  # "PREEMPT: demandé=y obtenu=n".
  cfg --disable PREEMPT_NONE
  cfg --disable PREEMPT_VOLUNTARY
  cfg --disable PREEMPT_LAZY
  cfg --enable PREEMPT
  cfg --enable PREEMPT_DYNAMIC
  # 1000 Hz: "the preferred choice for desktop systems" (kernel/Kconfig.hz).
  # Debian livre 250 Hz, un compromis orienté serveur.
  cfg --enable HZ_1000
  cfg --enable HIGH_RES_TIMERS
  # NO_HZ: on garde délibérément le réglage Debian (NO_HZ_FULL). Sans
  # `nohz_full=` sur la ligne de commande, son comportement est celui de
  # NO_HZ_IDLE — le suivi de contexte est derrière une static key inactive.
  # Forcer NO_HZ_IDLE ne gagnerait rien et retirerait une possibilité.
  #
  # SCHED_AUTOGROUP: regroupe les tâches par session. C'est LA fonctionnalité
  # qui empêche un `make -j32` de rendre le bureau inutilisable. Le profil
  # hyperviseur la coupe (elle fausse l'équité entre conteneurs); sur un poste
  # de travail c'est exactement l'inverse.
  cfg --enable SCHED_AUTOGROUP
  cfg --enable SCHED_MC
  cfg --enable SCHED_MC_PRIO          # Turbo Boost Max 3.0: cœurs favoris
  cfg --enable SCHED_SMT
  cfg --enable SCHED_CLUSTER          # chiplets Zen, cœurs E/P Intel
  # uclamp: permet de plancher la fréquence demandée par une tâche. C'est ce
  # qui évite que schedutil laisse un jeu tourner à basse fréquence parce que
  # sa charge CPU paraît modeste.
  cfg --enable UCLAMP_TASK
  cfg --enable UCLAMP_TASK_GROUP

  # --- Fluidité: mémoire ----------------------------------------------------
  # ZRAM — demandé explicitement, et de loin le levier le plus rentable sur
  # une machine à 4-8 Go. Livré en MODULE parce que c'est ce qu'attend
  # zram-tools (paquet Debian) qui le configure via /etc/default/zramswap:
  # son ExecStop réinitialise le périphérique, ce qu'un built-in complique.
  cfg --module ZRAM
  cfg --enable ZRAM_BACKEND_ZSTD
  cfg --enable ZRAM_BACKEND_LZ4
  cfg --enable ZRAM_DEF_COMP_ZSTD     # aligné sur ALGO=zstd d'AuxiNuxOS
  cfg --enable ZRAM_MULTI_COMP
  cfg --enable ZRAM_WRITEBACK         # pages incompressibles renvoyées au disque
  cfg --enable SWAP

  # ZSWAP: compilé mais INERTE par défaut. Empiler zswap devant un swap zram
  # revient à compresser deux fois les mêmes pages, pour un résultat plus lent
  # que sans. On le laisse disponible pour une installation sans zram.
  cfg --enable ZSWAP
  cfg --enable ZSWAP_COMPRESSOR_DEFAULT_ZSTD
  cfg --disable ZSWAP_DEFAULT_ON

  # MGLRU: remplacement de l'algorithme de réclamation de pages. Son gain se
  # voit précisément dans le cas qui exaspère l'utilisateur — la machine qui
  # arrive à saturation mémoire et devient pâteuse au lieu de rester utilisable.
  cfg --enable LRU_GEN
  cfg --enable LRU_GEN_ENABLED

  # PSI: prérequis ABSOLU de systemd-oomd, qui est la deuxième mesure de
  # fluidité d'AuxiNuxOS (docs/performance.md). Sans PSI, le service démarre,
  # ne lit aucune pression et ne tue jamais rien: la machine gèle quand même.
  # PSI_DEFAULT_DISABLED=n pour ne pas dépendre de psi=1 sur la ligne de boot.
  cfg --enable PSI
  cfg --disable PSI_DEFAULT_DISABLED
  cfg --enable MEMCG                  # pression par tranche cgroup, idem oomd

  # THP en madvise et pas en always: en "always", la compaction provoque des
  # à-coups de plusieurs dizaines de millisecondes, exactement le défaut de
  # fluidité qu'on cherche à supprimer. Les moteurs de jeu et les JVM qui
  # veulent des hugepages les demandent explicitement.
  cfg --enable TRANSPARENT_HUGEPAGE
  cfg --enable TRANSPARENT_HUGEPAGE_MADVISE
  cfg --disable TRANSPARENT_HUGEPAGE_ALWAYS
  cfg --enable COMPACTION
  cfg --enable KSM
  cfg --enable HUGETLBFS
  cfg --enable MEMORY_FAILURE
  cfg --enable USERFAULTFD            # CRIU, Wine, gestionnaires mémoire

  # --- Fluidité: entrées/sorties --------------------------------------------
  # BFQ est l'ordonnanceur qui privilégie les tâches interactives: c'est lui
  # qui évite qu'une mise à jour APT fasse bégayer une vidéo. Il est disponible
  # ici; le choix par device revient à une règle udev côté image AuxiNuxOS.
  cfg --enable MQ_IOSCHED_DEADLINE
  cfg --enable MQ_IOSCHED_KYBER
  cfg --enable IOSCHED_BFQ
  cfg --enable BFQ_GROUP_IOSCHED
  cfg --enable BLK_WBT
  cfg --enable BLK_WBT_MQ
  cfg --enable BLK_CGROUP_IOCOST
  cfg --enable IO_URING

  # --- CPU: fréquence et états de repos -------------------------------------
  # X86_NATIVE_CPU compile en -march=native, donc pour le CPU de la MACHINE DE
  # BUILD. Le noyau publié tomberait en #UD sur toute machine plus ancienne.
  # Garde explicite: un noyau de distribution ne peut pas être "natif".
  cfg --disable X86_NATIVE_CPU
  cfg --enable MICROCODE
  # Le chargement de microcode à chaud est une source connue de corruption:
  # on charge par l'initramfs au démarrage, pas sur un système en marche.
  cfg --disable MICROCODE_LATE_LOADING
  # Aucun pilote cpufreq ne couvre seul le parc visé: sans acpi-cpufreq, tout
  # AMD antérieur à Zen 2 reste bloqué à fréquence fixe, ce qui se ressent
  # autant en bureautique (lenteur) qu'en jeu (fréquence plafonnée).
  cfg --enable CPU_FREQ
  cfg --enable X86_ACPI_CPUFREQ
  cfg --module X86_POWERNOW_K8
  cfg --enable X86_INTEL_PSTATE
  cfg --enable X86_AMD_PSTATE
  cfg --set-val X86_AMD_PSTATE_DEFAULT_MODE 3   # actif (EPP), défaut amont
  cfg --enable CPU_FREQ_GOV_SCHEDUTIL
  cfg --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
  cfg --enable CPU_FREQ_GOV_PERFORMANCE
  cfg --enable CPU_FREQ_GOV_POWERSAVE
  cfg --enable CPU_FREQ_GOV_ONDEMAND
  cfg --enable CPU_FREQ_GOV_CONSERVATIVE
  cfg --enable CPU_IDLE
  cfg --enable CPU_IDLE_GOV_MENU
  cfg --enable CPU_IDLE_GOV_TEO
  cfg --enable INTEL_IDLE
  cfg --enable X86_X2APIC

  # ==========================================================================
  # Rollback AuxiNuxOS — prérequis noyau
  # ==========================================================================
  # Le rollback d'AuxiNuxOS repose sur une racine BTRFS en sous-volumes plats
  # (@, @home, @snapshots...), snapper, grub-btrfs, et un hook initramfs
  # (auxinux-snapshot-overlay) qui superpose un tmpfs inscriptible sur un
  # instantané en LECTURE SEULE pour pouvoir démarrer dessus. Trois exigences
  # en découlent, et deux n'étaient pas satisfaites jusqu'ici.
  #
  # 1. BTRFS en BUILT-IN, pas en module. La racine doit pouvoir être montée
  #    même quand l'initramfs est cassé ou périmé — c'est-à-dire précisément
  #    dans la situation où l'on veut restaurer. Un BTRFS en module fait
  #    dépendre le recours de l'objet qu'on soupçonne d'être en panne.
  cfg --enable BTRFS_FS
  cfg --enable BTRFS_FS_POSIX_ACL
  # Debug BTRFS coupé: gain réel et mesurable sur le chemin d'écriture.
  cfg --disable BTRFS_DEBUG
  cfg --disable BTRFS_ASSERT
  cfg --disable BTRFS_FS_RUN_SANITY_TESTS
  # compress=zstd:1 est dans les options de montage de la racine AuxiNuxOS:
  # sans zstd built-in, cette racine ne se monte pas.
  cfg --enable ZSTD_COMPRESS
  cfg --enable ZSTD_DECOMPRESS
  # Sommes de contrôle BTRFS (crc32c par défaut). Les variantes accélérées x86
  # ne sont plus des symboles distincts en 7.x: elles sont tirées par la
  # bibliothèque crypto dès que l'algorithme générique est activé.
  cfg --enable CRYPTO_CRC32C
  cfg --enable CRYPTO_XXHASH
  cfg --enable CRYPTO_BLAKE2B
  cfg --enable CRYPTO_SHA256
  #
  # 2. OverlayFS et tmpfs avec XATTR, en built-in. Le hook initramfs monte un
  #    overlay dont l'upperdir est un tmpfs; OverlayFS REFUSE de se monter si
  #    le système de fichiers supérieur ne gère pas les attributs étendus.
  #    Sans TMPFS_XATTR, le démarrage sur instantané échoue — c'est-à-dire que
  #    le rollback ne marche que lorsqu'on n'en a pas besoin.
  cfg --enable OVERLAY_FS
  cfg --enable TMPFS
  cfg --enable TMPFS_XATTR
  cfg --enable TMPFS_POSIX_ACL
  cfg --enable BLK_DEV_INITRD
  cfg --enable RD_ZSTD
  cfg --enable RD_GZIP
  cfg --enable RD_LZ4
  #
  # 3. Chaîne EFI complète: grub-btrfs régénère des entrées de menu, et
  #    efibootmgr/GRUB ont besoin des variables EFI pour le faire.
  cfg --enable EFI
  cfg --enable EFI_STUB
  cfg --enable EFIVAR_FS
  cfg --enable EFI_VARS_PSTORE
  cfg --enable ACPI
  cfg --enable ACPI_TABLE_UPGRADE

  # --- Systèmes de fichiers d'un poste de travail ---------------------------
  cfg --enable EXT4_FS
  cfg --enable EXT4_FS_POSIX_ACL
  cfg --enable EXT4_FS_SECURITY
  cfg --module XFS_FS
  cfg --module F2FS_FS
  # Partition EFI: built-in, avec ses tables de caractères, sinon /boot/efi ne
  # se monte pas sans initramfs.
  cfg --enable VFAT_FS
  cfg --enable NLS_CODEPAGE_437
  cfg --enable NLS_ISO8859_1
  cfg --enable NLS_UTF8
  cfg --module EXFAT_FS               # cartes SD, clés USB modernes
  # NTFS3: lecture/écriture des partitions Windows. AuxiNuxOS livre une couche
  # windows-support; un double amorçage doit pouvoir lire son autre disque.
  cfg --module NTFS3_FS
  cfg --enable NTFS3_LZX_XPRESS
  cfg --enable NTFS3_FS_POSIX_ACL
  cfg --module ISO9660_FS
  cfg --enable JOLIET
  cfg --enable ZISOFS
  cfg --module UDF_FS
  cfg --module SQUASHFS
  cfg --enable SQUASHFS_XZ
  cfg --enable SQUASHFS_ZSTD
  # FUSE: Flatpak (revokefs), AppImage, fuse-overlayfs, gvfs. Sur une image où
  # "les applications Flatpak sont privilégiées", ce n'est pas optionnel.
  cfg --enable FUSE_FS
  cfg --module CUSE
  cfg --enable BLK_DEV_LOOP
  cfg --module NFS_FS
  cfg --module CIFS
  cfg --module AUTOFS_FS
  # Chiffrement de disque (LUKS) et instantanés LVM pour les installations qui
  # ne sont pas en BTRFS.
  cfg --enable BLK_DEV_DM
  cfg --module DM_CRYPT
  cfg --module DM_SNAPSHOT
  cfg --enable CRYPTO_XTS
  cfg --enable CRYPTO_AES_NI_INTEL
  cfg --enable CRYPTO_USER_API_SKCIPHER
  # Stockage: AHCI et NVMe built-in, la racine monte sans initramfs.
  cfg --enable ATA
  cfg --enable SATA_AHCI
  cfg --enable ATA_PIIX
  cfg --enable BLK_DEV_NVME
  cfg --module USB_STORAGE
  cfg --module USB_UAS
  cfg --module MMC
  cfg --module MMC_BLOCK
  cfg --module MMC_SDHCI
  cfg --module MMC_SDHCI_PCI
  cfg --module MMC_SDHCI_ACPI
  cfg --module MISC_RTSX_PCI          # lecteurs de cartes Realtek (portables)

  # ==========================================================================
  # Virtualisation conservée: LXC, Docker et KVM
  # ==========================================================================
  # --- Conteneurs: cgroups v2, espaces de noms -----------------------------
  cfg --enable CGROUPS
  cfg --enable CGROUP_BPF
  cfg --enable CGROUP_FREEZER
  cfg --enable CGROUP_PIDS
  cfg --enable CGROUP_DEVICE
  cfg --enable CGROUP_SCHED
  cfg --enable CGROUP_MISC
  cfg --enable CGROUP_CPUACCT
  cfg --enable CGROUP_PERF
  cfg --enable CGROUP_HUGETLB
  cfg --enable FAIR_GROUP_SCHED
  cfg --enable CFS_BANDWIDTH
  cfg --enable BLK_CGROUP
  cfg --enable BLK_DEV_THROTTLING
  cfg --enable CPUSETS
  cfg --enable NAMESPACES
  # USER_NS est aussi le prérequis de bubblewrap, donc de TOUT Flatpak non
  # privilégié: le couper pour "durcir" casserait le mode de distribution
  # d'applications par défaut d'AuxiNuxOS.
  cfg --enable USER_NS
  cfg --enable NET_NS
  cfg --enable PID_NS
  cfg --enable IPC_NS
  cfg --enable UTS_NS
  cfg --enable TIME_NS
  cfg --enable SECCOMP
  cfg --enable CHECKPOINT_RESTORE
  cfg --enable POSIX_MQUEUE
  cfg --enable KEYS
  cfg --enable DEVTMPFS
  cfg --enable DEVTMPFS_MOUNT

  # --- Réseau des conteneurs (NAT Docker, bridges LXC) ----------------------
  cfg --enable VETH
  cfg --enable TUN
  cfg --enable BRIDGE
  cfg --enable BRIDGE_VLAN_FILTERING
  cfg --enable BRIDGE_NETFILTER
  cfg --enable MACVLAN
  cfg --enable IPVLAN
  cfg --enable VLAN_8021Q
  cfg --module DUMMY
  cfg --module WIREGUARD
  cfg --enable NETFILTER
  cfg --enable NF_TABLES
  cfg --enable NF_CONNTRACK
  cfg --enable NF_NAT
  cfg --enable NFT_NAT
  cfg --enable NFT_MASQ
  cfg --enable NFT_REJECT
  cfg --enable NETFILTER_XT_MATCH_ADDRTYPE
  cfg --enable NETFILTER_XT_MATCH_CONNTRACK
  # Les cibles IP_NF_* historiques sont encore émises par docker et lxc-net;
  # depuis 7.x elles dépendent explicitement de NETFILTER_XTABLES_LEGACY.
  cfg --enable NETFILTER_XTABLES
  cfg --enable NETFILTER_XTABLES_LEGACY
  cfg --enable IP_NF_IPTABLES
  # En 7.x, IP_NF_FILTER/NAT/TARGET_MASQUERADE dépendent de
  # IP_NF_IPTABLES_LEGACY, un tristate que Debian livre en module: ils ne
  # PEUVENT donc pas être built-in. C'est sans conséquence, docker et lxc-net
  # les chargent à la demande. Demander =y ne produisait qu'un avertissement.
  cfg --module IP_NF_IPTABLES_LEGACY
  cfg --module IP_NF_FILTER
  cfg --module IP_NF_NAT
  cfg --module IP_NF_TARGET_MASQUERADE
  cfg --enable IP6_NF_IPTABLES
  cfg --enable NET_SCHED
  cfg --enable NET_CLS_CGROUP
  cfg --module NET_CLS_BPF
  cfg --module NET_ACT_BPF
  cfg --module NET_SCH_FQ_CODEL
  cfg --module NET_SCH_CAKE           # anti-bufferbloat: latence en jeu en ligne
  cfg --module NET_SCH_FQ             # ordonnanceur attendu par BBR
  cfg --module TCP_CONG_BBR

  # --- KVM: machines virtuelles depuis le bureau (Boxes, virt-manager) ------
  cfg --enable VIRTUALIZATION
  cfg --enable KVM
  cfg --module KVM_INTEL
  cfg --module KVM_AMD
  cfg --module VHOST_NET
  cfg --module VHOST_VSOCK
  cfg --module VSOCKETS
  cfg --module VIRTIO_VSOCKETS
  cfg --enable PARAVIRT
  cfg --enable PARAVIRT_SPINLOCKS
  cfg --enable HYPERVISOR_GUEST
  # AuxiNuxOS s'installe et se valide aussi EN machine virtuelle: les pilotes
  # invités VirtIO de démarrage sont built-in pour ne pas dépendre d'un
  # initramfs correct dans ce cas non plus.
  cfg --enable VIRTIO_PCI
  cfg --enable VIRTIO_BLK
  cfg --enable VIRTIO_NET
  cfg --module VIRTIO_CONSOLE
  cfg --module VIRTIO_BALLOON
  cfg --module VIRTIO_INPUT
  cfg --module VIRTIO_FS
  # IOMMU: passthrough occasionnel (eGPU, carte son USB dédiée, VM GPU).
  # INTEL_IOMMU_DEFAULT_ON reste volontairement à l'écart: l'activer par défaut
  # casse le démarrage de certaines cartes anciennes. Opt-in documenté:
  # intel_iommu=on iommu=pt
  cfg --enable IOMMU_SUPPORT
  cfg --enable INTEL_IOMMU
  cfg --enable AMD_IOMMU
  cfg --enable IRQ_REMAP
  cfg --module VFIO
  cfg --module VFIO_PCI

  # ==========================================================================
  # Portable: alimentation, thermique, touches constructeur
  # ==========================================================================
  # Contrairement au profil hyperviseur, qui coupe SUSPEND et HIBERNATION pour
  # éliminer une classe entière de bugs ACPI, un poste de travail DOIT pouvoir
  # se mettre en veille: rabattre l'écran est le geste le plus courant qui
  # soit.
  cfg --enable SUSPEND
  cfg --enable HIBERNATION
  cfg --module ACPI_AC
  cfg --module ACPI_BATTERY
  cfg --module ACPI_BUTTON
  cfg --module ACPI_FAN
  cfg --module ACPI_THERMAL
  cfg --enable ACPI_DOCK
  cfg --enable ACPI_PROCESSOR
  cfg --module ACPI_WMI
  cfg --enable X86_PLATFORM_DEVICES
  cfg --module THINKPAD_ACPI
  cfg --module ASUS_WMI
  cfg --module ASUS_NB_WMI
  cfg --module DELL_LAPTOP
  cfg --module DELL_WMI
  cfg --module DELL_SMBIOS
  cfg --module HP_WMI
  cfg --module ACER_WMI
  cfg --module MSI_WMI
  cfg --module LENOVO_YMC
  cfg --module INTEL_HID_EVENT
  cfg --module INTEL_VBTN
  cfg --module INTEL_PMC_CORE
  cfg --module AMD_PMC
  cfg --module AMD_PMF                # gestion thermique/plateforme AMD récente
  cfg --enable THERMAL
  cfg --module X86_PKG_TEMP_THERMAL
  cfg --module INT340X_THERMAL
  cfg --enable HWMON
  cfg --module SENSORS_CORETEMP
  cfg --module SENSORS_K10TEMP
  cfg --module SENSORS_NCT6775
  cfg --module SENSORS_DELL_SMM
  cfg --enable PCIEASPM
  cfg --enable PCIEASPM_DEFAULT       # économie d'énergie PCIe par défaut

  # --- Bus et périphériques -------------------------------------------------
  cfg --enable USB_SUPPORT
  cfg --enable USB
  cfg --enable USB_XHCI_HCD
  cfg --module USB_EHCI_HCD
  cfg --module USB_OHCI_HCD
  cfg --module USB_UHCI_HCD
  cfg --module USB_PRINTER
  cfg --module USB_ACM
  cfg --module USB_SERIAL
  cfg --module USB_USBNET
  cfg --module USB_NET_CDCETHER
  cfg --module USB_RTL8152            # adaptateurs Ethernet USB et stations d'accueil
  cfg --module USB4                   # Thunderbolt 3/4 et USB4
  cfg --module USB4_NET
  cfg --enable HOTPLUG_PCI
  cfg --enable HOTPLUG_PCI_PCIE
  cfg --module R8169
  cfg --module E1000
  cfg --module E1000E
  cfg --module IGB
  cfg --module IGC
  cfg --module ALX
  cfg --module ATL1C

  # --- Wi-Fi et Bluetooth ---------------------------------------------------
  # Corrections de noms révélées par le garde-fou au passage en 7.2:
  #   MT76        n'existe pas (bibliothèque interne MT76_CORE, auto-sélectionnée)
  #   ATH12K_PCI  n'existe plus: ATH12K est directement le pilote PCI
  # Les deux étaient des no-op silencieux sur le profil AuxiNuxOS.
  cfg --enable RFKILL
  cfg --enable WLAN
  cfg --module CFG80211
  cfg --enable CFG80211_WEXT
  cfg --module MAC80211
  cfg --module IWLWIFI
  cfg --module IWLDVM                 # Intel 5000/6000 (2009-2012)
  cfg --module IWLMVM                 # Intel 7260 -> AX211
  cfg --module IWLMLD                 # Intel Wi-Fi 7 (BE200/BE201)
  cfg --module ATH9K
  cfg --module ATH10K
  cfg --module ATH10K_PCI
  cfg --module ATH11K
  cfg --module ATH11K_PCI
  cfg --module ATH12K
  cfg --module MT7601U
  cfg --module MT7915E
  cfg --module MT7921E                # Wi-Fi 6E, très répandu depuis 2022
  cfg --module MT7925E                # Wi-Fi 7
  cfg --module RTW88
  cfg --module RTW89
  cfg --module BRCMFMAC
  cfg --enable BRCMFMAC_PCIE
  cfg --enable BRCMFMAC_USB
  cfg --module MWIFIEX
  cfg --module MWIFIEX_PCIE
  cfg --module MWIFIEX_USB
  cfg --module RTL8XXXU
  cfg --module BT
  cfg --module BT_HCIBTUSB
  cfg --module BT_HCIUART
  cfg --module BT_RFCOMM
  cfg --module BT_BNEP
  cfg --module BT_HIDP                # claviers, souris et manettes Bluetooth
  cfg --enable BT_LE

  # ==========================================================================
  # Sécurité
  # ==========================================================================
  # SECURITY_APPARMOR=y ne suffit PAS: si 'apparmor' n'est pas dans CONFIG_LSM,
  # les profils AppArmor de Docker, LXC et snap ne s'appliquent JAMAIS — en
  # silence, sans aucune erreur visible. On reprend la chaîne exacte de
  # Debian 13.
  cfg --enable SECURITY
  cfg --enable SECURITY_APPARMOR
  cfg --enable SECURITY_LANDLOCK      # utilisé par systemd 257 et Flatpak
  cfg --enable SECURITY_YAMA
  cfg --enable SECURITY_SELINUX
  cfg --set-str LSM "landlock,lockdown,yama,integrity,apparmor,bpf"
  cfg --enable BPF_SYSCALL
  cfg --enable BPF_JIT
  cfg --enable BPF_JIT_ALWAYS_ON
  cfg --enable BPF_UNPRIV_DEFAULT_OFF
  cfg --enable RANDOMIZE_BASE
  cfg --enable STACKPROTECTOR_STRONG
  # Mitigations spéculatives: compilées ET actives par défaut. Sur un poste
  # personnel qui exécute du code tiers (navigateur, jeux, Flatpak), les
  # couper est un choix d'exploitation que l'utilisateur peut faire au boot
  # avec mitigations=off — pas un choix de build qu'on impose à tout le parc.
  cfg --enable CPU_MITIGATIONS
  cfg --enable MITIGATION_PAGE_TABLE_ISOLATION
  cfg --enable MITIGATION_RETPOLINE
  cfg --enable MITIGATION_SPECTRE_V1
  cfg --enable MITIGATION_SPECTRE_V2
  cfg --enable MITIGATION_RETHUNK
  cfg --enable MITIGATION_SRSO
  cfg --enable MITIGATION_MDS
  cfg --enable MITIGATION_L1TF
  cfg --enable MITIGATION_VMSCAPE

  # --- Prérequis systemd (fichier REQUIREMENTS amont) -----------------------
  # Jusqu'ici hérités par chance de la config Debian, jamais vérifiés.
  cfg --enable FHANDLE
  cfg --enable DMIID
  cfg --enable INOTIFY_USER
  cfg --enable SIGNALFD
  cfg --enable TIMERFD
  cfg --enable EPOLL
  cfg --enable SYSVIPC
  cfg --enable UNIX98_PTYS
  cfg --enable CRYPTO_USER_API_HASH
  cfg --enable KCMP
  cfg --enable PROC_FS
  cfg --enable SYSFS
  cfg --enable BINFMT_ELF
  cfg --module BINFMT_MISC            # exécution des .exe via la couche Windows
  # Binaires 32 bits: Steam, Wine/Proton, quelques installeurs propriétaires.
  # IA32_EMULATION seul ne suffit plus depuis 6.7: si
  # IA32_EMULATION_DEFAULT_DISABLED est activé, le support est compilé mais
  # inerte tant qu'on ne passe pas ia32_emulation=1 au boot — un Steam qui
  # refuse de démarrer sans le moindre message utile.
  cfg --enable IA32_EMULATION
  cfg --disable IA32_EMULATION_DEFAULT_DISABLED

  # --- Diagnostic et dernier recours ----------------------------------------
  # Alt+SysRq+REISUB permet de redémarrer proprement une session graphique
  # figée au lieu de couper l'alimentation — et une coupure brutale sur BTRFS
  # est exactement ce qu'on veut éviter quand on mise sur les instantanés.
  cfg --enable MAGIC_SYSRQ
  cfg --enable SOFTLOCKUP_DETECTOR
  cfg --enable DETECT_HUNG_TASK
  # BOOTPARAM_*_PANIC sont des ENTIERS (nombre de détections avant panic), pas
  # des booléens: --disable y serait un no-op. 0 = tracer et continuer.
  cfg --set-val BOOTPARAM_SOFTLOCKUP_PANIC 0
  cfg --set-val BOOTPARAM_HUNG_TASK_PANIC 0
  cfg --enable X86_MCE
  cfg --enable X86_MCE_INTEL
  cfg --enable X86_MCE_AMD
  cfg --enable RAS
  cfg --enable PSTORE
  cfg --enable TASK_DELAY_ACCT
  cfg --enable TASKSTATS
  cfg --enable TASK_IO_ACCOUNTING
  cfg --enable PERF_EVENTS

  # --- Firmware -------------------------------------------------------------
  # EXTRA_FIRMWARE reste VIDE: le firmware vient des paquets Debian
  # non-free-firmware (amdgpu, i915, iwlwifi...) via /lib/firmware, pas
  # embarqué dans vmlinuz. L'embarquer figerait des versions et gonflerait
  # l'image pour rien.
  cfg --set-str EXTRA_FIRMWARE ""
  cfg --enable FW_LOADER
  # FW_LOADER_USER_HELPER est sélectionné par plusieurs pilotes: le forcer à n
  # est impossible. Ce n'est pas lui qui pose problème mais FW_LOADER_USER_HELPER_FALLBACK,
  # qui fait attendre 60 s à chaque firmware absent. Debian le laisse à n;
  # on le vérifie au lieu de se battre avec le premier.
  cfg --disable FW_LOADER_USER_HELPER_FALLBACK
  cfg --enable FW_LOADER_COMPRESS
  cfg --enable FW_LOADER_COMPRESS_ZSTD
fi

# Résout les dépendances et fige la config
make "${MAKE_ARCH_ARGS[@]}" olddefconfig

# ============================================================
# [6/9] Vérification de la config finale
# ============================================================
echo
echo "[6/9] Vérification de la config finale..."

# ============================================================
# [6a] Vérification des options RÉELLEMENT demandées
# ============================================================
# Sans ce contrôle, un cfg() sur un symbole renommé ou supprimé upstream est un
# no-op silencieux: scripts/config écrit la ligne, olddefconfig la retire, et
# rien ne le signale.
#
# Deux verdicts distincts:
#   INCONNU  -> le symbole n'existe pas dans CE noyau (renommé/supprimé).
#               Erreur bloquante: l'intention exprimée n'a rien produit.
#   IGNORÉ   -> le symbole existe mais olddefconfig ne l'a pas retenu, presque
#               toujours parce qu'une dépendance manque. Avertissement détaillé.
echo "Indexation des symboles Kconfig de ${KERNEL_VERSION}..."
KCONFIG_SYMBOLS="${BUILD_ROOT}/kconfig-symbols-${KERNEL_VERSION}.txt"
find . -type f -name 'Kconfig*' -print0 \
  | xargs -0 grep -hoE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' \
  | awk '{print $NF}' | sort -u > "$KCONFIG_SYMBOLS"
echo "  $(wc -l < "$KCONFIG_SYMBOLS") symboles connus, ${#CFG_REQUESTS[@]} options demandées."

cfg_unknown=()
cfg_ignored=()
for req in "${CFG_REQUESTS[@]}"; do
  IFS=$'\t' read -r _sym _action _expect <<<"$req"

  if ! grep -qxF "$_sym" "$KCONFIG_SYMBOLS"; then
    cfg_unknown+=("${_sym} (${_action})")
    continue
  fi

  case "$_expect" in
    y|m)
      grep -q "^CONFIG_${_sym}=${_expect}\$" .config \
        || cfg_ignored+=("${_sym}: demandé=${_expect} obtenu=$(cfg_actual "$_sym")")
      ;;
    n)
      grep -q "^CONFIG_${_sym}=[ym]\$" .config \
        && cfg_ignored+=("${_sym}: demandé=n obtenu=$(cfg_actual "$_sym")")
      ;;
    str:*)
      _want="${_expect#str:}"
      grep -q "^CONFIG_${_sym}=\"${_want}\"\$" .config \
        || cfg_ignored+=("${_sym}: demandé=\"${_want}\" obtenu=$(cfg_actual "$_sym")")
      ;;
    val:*)
      _want="${_expect#val:}"
      grep -q "^CONFIG_${_sym}=${_want}\$" .config \
        || cfg_ignored+=("${_sym}: demandé=${_want} obtenu=$(cfg_actual "$_sym")")
      ;;
  esac
done

if (( ${#cfg_ignored[@]} > 0 )); then
  echo
  echo "AVERTISSEMENT: ${#cfg_ignored[@]} option(s) demandée(s) non retenue(s) par olddefconfig"
  echo "  (symbole existant mais dépendance manquante, ou valeur forcée):"
  printf '  - %s\n' "${cfg_ignored[@]}"
fi

if (( ${#cfg_unknown[@]} > 0 )); then
  echo
  echo "Symboles INCONNUS dans Linux ${KERNEL_VERSION}:"
  printf '  - %s\n' "${cfg_unknown[@]}"
  die "${#cfg_unknown[@]} symbole(s) Kconfig inexistant(s) dans ce noyau.
Ils ont été renommés ou supprimés upstream: le cfg() correspondant n'a RIEN fait.
Corrige les noms dans la section de configuration avant de compiler."
fi

echo "Toutes les options demandées existent dans Linux ${KERNEL_VERSION}."

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
  # Sans ces options, le paquet produit n'est pas un noyau AuxiNuxOS utilisable.
  CRITICAL=(
    # Affichage et entrées: sans eux la machine démarre mais reste noire.
    DRM DRM_SIMPLEDRM VT FRAMEBUFFER_CONSOLE
    INPUT_EVDEV HID HID_GENERIC USB_HID USB_SUPPORT
    # Audio et radio.
    SOUND SND RFKILL WLAN CFG80211 MAC80211 BT
    # Racines supportées.
    EXT4_FS BTRFS_FS
    # Rollback: overlay inscriptible sur instantané en lecture seule.
    OVERLAY_FS TMPFS_XATTR
    # Fluidité: PSI est le prérequis dur de systemd-oomd.
    PSI MEMCG ZRAM LRU_GEN
    # Conteneurs LXC/Docker.
    CGROUPS CGROUP_SCHED BLK_CGROUP NAMESPACES USER_NS NET_NS PID_NS
    SECCOMP VETH BRIDGE TUN SECURITY_APPARMOR
    # Modules hors-arbre (NVIDIA propriétaire, VirtualBox, ZFS) via DKMS.
    MODVERSIONS
    # eBPF CO-RE.
    BPF_SYSCALL DEBUG_INFO_BTF
    # Prérequis systemd non négociables.
    FHANDLE INOTIFY_USER SIGNALFD TIMERFD EPOLL
    # Flatpak / AppImage.
    FUSE_FS
    # Plateforme CPU.
    MICROCODE CPU_FREQ
  )

  # Options qui DOIVENT être compilées en dur, pas en module: monter la racine
  # ou démarrer sur un instantané ne doit dépendre d'aucun initramfs.
  # opt_on() accepte 'm', ce qui masquerait précisément la régression que cette
  # liste existe pour attraper.
  CRITICAL_BUILTIN=(
    BTRFS_FS ZSTD_COMPRESS ZSTD_DECOMPRESS
    OVERLAY_FS TMPFS_XATTR
    EXT4_FS VFAT_FS
    ATA SATA_AHCI BLK_DEV_NVME
    DRM DRM_SIMPLEDRM SYSFB_SIMPLEFB FRAMEBUFFER_CONSOLE
    EFIVAR_FS
  )

  RECOMMENDED=(
    # GPU: les trois constructeurs.
    DRM_I915 DRM_XE DRM_AMDGPU DRM_AMD_DC DRM_NOUVEAU DRM_RADEON
    DRM_FBDEV_EMULATION BACKLIGHT_CLASS_DEVICE
    # Audio moderne (SOF) et amplificateurs de portables.
    SND_HDA_INTEL SND_HDA_CODEC_REALTEK SND_HDA_CODEC_HDMI SND_USB_AUDIO
    SND_SOC_SOF_INTEL_TOPLEVEL
    # Jeu.
    NTSYNC JOYSTICK_XPAD HID_PLAYSTATION HID_NINTENDO HID_STEAM INPUT_JOYDEV
    IA32_EMULATION
    # Fluidité.
    PREEMPT_DYNAMIC SCHED_AUTOGROUP UCLAMP_TASK IOSCHED_BFQ BLK_WBT
    ZRAM_WRITEBACK LRU_GEN_ENABLED X86_INTEL_PSTATE X86_AMD_PSTATE
    # Conteneurs et virtualisation.
    KVM KVM_INTEL KVM_AMD NF_TABLES NF_NAT IP_NF_TARGET_MASQUERADE
    CGROUP_HUGETLB CFS_BANDWIDTH CHECKPOINT_RESTORE SECURITY_LANDLOCK
    # Périphériques.
    BT_HCIBTUSB IWLWIFI IWLMVM IWLMLD ATH10K ATH11K ATH12K
    MT7921E MT7925E RTW88 RTW89 BRCMFMAC
    USB4 MMC_SDHCI EXFAT_FS NTFS3_FS XFS_FS
    # Portable.
    SUSPEND HIBERNATION THINKPAD_ACPI THERMAL HWMON
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

# Un pilote de racine en module passerait opt_on() sans que la racine soit
# montable sans initramfs: on contrôle la valeur exacte.
opt_builtin() { grep -q "^CONFIG_${1}=y\$" .config; }
not_builtin=()
for o in ${CRITICAL_BUILTIN[@]+"${CRITICAL_BUILTIN[@]}"}; do
  opt_builtin "$o" || not_builtin+=("${o}=$(cfg_actual "$o")")
done
(( ${#not_builtin[@]} == 0 )) || \
  die "options attendues en BUILT-IN mais qui ne le sont pas: ${not_builtin[*]}
Elles conditionnent le montage de la racine et le démarrage sur un instantané
de restauration, qui ne doivent dépendre d'aucun initramfs. Build interrompu."

(( ${#missing_reco[@]} == 0 )) || \
  echo "AVERTISSEMENT: options recommandées absentes: ${missing_reco[*]}"

(( ${#missing_crit[@]} == 0 )) || \
  die "options CRITIQUES absentes après olddefconfig: ${missing_crit[*]}
Vérifie le .config et les dépendances. Build interrompu."

# cfg() ignore les erreurs: sans ce controle, une option devenue non
# selectionnable retombe silencieusement sur la valeur de la config de base.
# Le profil auxinuxos active BTF d'office (défaut Debian 13), et BTF IMPOSE du
# DWARF complet: CONFIG_DEBUG_INFO=y y est donc attendu, pas une régression.
# Le paquet -dbg produit au passage n'est pas publié ([8/9]).
if [[ "$PROFILE" == "auxinuxos" || "$WITH_DEBUG_INFO" == "1" ]]; then
  opt_on DEBUG_INFO_BTF || echo "AVERTISSEMENT: CONFIG_DEBUG_INFO_BTF absent (eBPF CO-RE indisponible)."
elif grep -q '^CONFIG_DEBUG_INFO=y' .config; then
  die "CONFIG_DEBUG_INFO=y alors que WITH_DEBUG_INFO=0.
La désactivation n'a pas pris: vérifie CONFIG_DEBUG_INFO_NONE dans .config.
Sans ça le build produit un paquet -dbg de ~1.7 Go et dure bien plus longtemps."
fi

echo "Config OK — toutes les options critiques sont présentes."

if [[ "$CONFIG_ONLY" == "1" ]]; then
  cp .config "${BUILD_ROOT}/config-${KERNEL_VERSION}${LOCAL_VERSION}"
  echo
  echo "============================================================"
  echo " Build à blanc (CONFIG_ONLY=1): arrêt avant compilation."
  echo " Config retenue: ${BUILD_ROOT}/config-${KERNEL_VERSION}${LOCAL_VERSION}"
  echo "============================================================"
  exit 0
fi

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
# [7b/9] Paquet source OpenZFS (DKMS) — modèle Debian, pas Ubuntu
# ============================================================
# On empaquette la SOURCE OpenZFS + son dkms.conf (openzfs-zfs-dkms, arch=all),
# jamais un module compilé. La compilation a lieu chez l'utilisateur final via
# DKMS, au moment de l'install/du prochain boot — jamais sur ce serveur. Ça
# évite de distribuer un binaire combinant du code CDDL (OpenZFS) et du code
# GPL-2.0 (Linux), au prix d'un risque d'échec de compilation côté utilisateur
# si les headers du kernel cible ne sont pas installés (voir l'appariement
# strict avec linux-headers-<release> dans build-depot-kernel-core.sh).
if [[ "$WITH_ZFS" == "1" ]]; then
  echo
  echo "[7b/9] Construction du paquet source OpenZFS ${ZFS_VERSION} (DKMS)..."

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
  if [[ "$ALLOW_UNVERIFIED_ZFS_SOURCE" == "1" ]]; then
    echo "AVERTISSEMENT: vérification du source ZFS IGNORÉE (ALLOW_UNVERIFIED_ZFS_SOURCE=1)."
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

  cd "$ZFS_SRC_DIR"

  # Pas de --with-linux/--with-config=kernel ici: le paquet DKMS ne cible
  # aucun kernel précis, contrairement à l'ancien build kmod apparié.
  echo "Configuration OpenZFS (paquetage source, indépendant du kernel)..."
  # --with-config=user: configure UNIQUEMENT la partie userspace/DKMS. Sans ce
  # flag, OpenZFS configure aussi le build du module noyau (--with-config=all
  # par defaut), ce qui exige des headers noyau sur ce serveur et ouvre la porte
  # a ce qu'un objet noyau se retrouve empaquete — l'inverse de l'objectif.
  ./configure --prefix=/usr --with-config=user --with-tirpc

  echo "Construction du paquetage Debian natif OpenZFS (PAS d'alien/rpm)..."
  # native-deb-utils = cible Makefile.am d'OpenZFS lançant dpkg-buildpackage
  # sur contrib/debian; produit openzfs-zfs-dkms (arch=all) ET des paquets
  # userspace (zfsutils, libzfs...). Seul openzfs-zfs-dkms nous intéresse ici:
  # les outils userspace restent fournis par Debian (zfsutils-linux), comme
  # avant. On ne construit PAS le module lui-même (pas native-deb-kmod).
  make -j"$JOBS" native-deb-utils

  cd "$BUILD_ROOT"
  shopt -s nullglob
  zfs_debs=( "$BUILD_ROOT"/openzfs-zfs-dkms_*.deb )
  other_zfs_debs=(
    "$BUILD_ROOT"/openzfs-libnvpair3_*.deb "$BUILD_ROOT"/openzfs-libpam-zfs_*.deb
    "$BUILD_ROOT"/openzfs-libuutil3_*.deb "$BUILD_ROOT"/openzfs-libzfs-dev_*.deb
    "$BUILD_ROOT"/openzfs-libzfs7_*.deb "$BUILD_ROOT"/openzfs-libzfsbootenv1_*.deb
    "$BUILD_ROOT"/openzfs-libzpool7_*.deb "$BUILD_ROOT"/openzfs-python3-pyzfs_*.deb
    "$BUILD_ROOT"/openzfs-pyzfs-doc_*.deb "$BUILD_ROOT"/openzfs-zfs-initramfs_*.deb
    "$BUILD_ROOT"/openzfs-zfs-dracut_*.deb "$BUILD_ROOT"/openzfs-zfsutils_*.deb
    "$BUILD_ROOT"/openzfs-zfs-zed_*.deb "$BUILD_ROOT"/openzfs-zfs-test_*.deb
  )
  shopt -u nullglob
  (( ${#zfs_debs[@]} > 0 )) \
    || die "paquet openzfs-zfs-dkms introuvable dans $BUILD_ROOT après native-deb-utils."

  echo "Paquet source ZFS généré:"
  for z in "${zfs_debs[@]}"; do echo "  $(basename "$z")"; done

  # Les paquets userspace produits en même temps (zfsutils, libzfs...) restent
  # hors scope de ce dépôt kernel: ils ne combinent aucun code GPL et Debian
  # fournit déjà zfsutils-linux. On les jette pour ne pas les publier par erreur.
  (( ${#other_zfs_debs[@]} > 0 )) && rm -f "${other_zfs_debs[@]}"
else
  echo
  echo "[7b/9] Paquet source OpenZFS (DKMS): désactivé (WITH_ZFS=${WITH_ZFS})."
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

  # Les paquets -dbg/-dbgsym pèsent 1 à 2 Go et ne servent qu'au débogage du
  # noyau. DEBUG_INFO_BTF impose du DWARF complet, donc ils existent désormais
  # à chaque build: le meta ne les référence pas, les publier ne ferait que
  # saturer le dépôt et la bande passante des postes.
  case "$pkg_name" in
    *-dbg|*-dbgsym)
      echo "SKIP $(basename "$pkg") (symboles de debug, non publiés)"
      continue
      ;;
  esac

  if [[ "$pkg_name" == "linux-libc-dev" ]]; then
    echo "SKIP $(basename "$pkg") (linux-libc-dev reste fourni par Debian)"
    rm -f "$OUTPUT_DIR/${pkg_name}"_*_"${pkg_arch}".deb \
          "$OUTPUT_DIR/${pkg_name}-${KERNEL_NAME_SUFFIX}.deb"
    continue
  fi

  # linux-image-*/linux-headers-* encodent déjà la release kernel complète
  # (ex: linux-image-7.0.12-auxinuxos-amd64) dans leur nom de paquet: pas
  # besoin de suffixe. openzfs-zfs-dkms est lui indépendant du profil/kernel
  # (un seul paquet source par version d'OpenZFS): même raisonnement, un seul
  # nom de fichier stable. Les autres paquets (ex: un futur meta) n'ont pas
  # cette unicité intégrée et pourraient sinon se recouvrir entre profils.
  case "$pkg_name" in
    linux-image-*|linux-headers-*|openzfs-zfs-dkms)
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
    # Racine APT = REPO_ROOT (qui contient dists/ et le keyring), PAS le
    # sous-dossier KERNEL/ qui ne contient que les .deb. Avec /KERNEL, apt
    # cherchait .../AUXINUXOS/KERNEL/dists/kernel/InRelease -> 404.
    README_APT_URL="https://dep.auxinux.ca/AUXINUXOS"
    README_KEYRING="auxinuxos-archive-keyring"
    ;;
  *)
    README_REPO_LABEL="AuxiNux Kernel Repository"
    README_APT_URL="https://dep.auxinux.ca/VIRTUA"
    README_KEYRING="virtua-archive-keyring"
    ;;
esac

# Suite APT visee par ce build (prod -> kernel, dev -> kernel-dev).
README_SUITE="kernel"
[[ "$RELEASE_TRACK" == "dev" ]] && README_SUITE="kernel-dev"

cat > "$OUTPUT_DIR/README-${KERNEL_NAME_SUFFIX}.txt" <<EOF
${README_REPO_LABEL}
$(printf '=%.0s' $(seq 1 ${#README_REPO_LABEL}))

Kernel    : Linux ${KERNEL_VERSION}${LOCAL_VERSION}
Version   : ${PKG_VERSION}
Source    : ${SOURCE}
Profile   : ${PROFILE}
Arch      : ${TARGET_ARCH} (${KBUILD_DEBARCH})
Base src  : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})
OpenZFS   : $([[ "$WITH_ZFS" == "1" ]] && echo "${ZFS_VERSION} (paquet source DKMS openzfs-zfs-dkms, compilé à l'install)" || echo "non inclus")
Généré    : $(date -Iseconds)

APT source (dépôt signé — ne jamais utiliser trusted=yes):
  sudo wget -O /usr/share/keyrings/${README_KEYRING}.gpg \\
       ${README_APT_URL}/${README_KEYRING}.gpg

deb [signed-by=/usr/share/keyrings/${README_KEYRING}.gpg arch=${KBUILD_DEBARCH}] ${README_APT_URL} ${README_SUITE} main

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
echo "  sudo ./build-depot-kernel-core.sh /tmp/virtua-kernel"
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
