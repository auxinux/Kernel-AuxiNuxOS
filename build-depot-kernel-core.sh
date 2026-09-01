#!/usr/bin/env bash
set -Eeuo pipefail

############################################################
# Virtua Kernel Repository Builder
#
# Usage:
#   sudo ./build-depot-kernel-core.sh [IMPORT_DIR]
#
# Variables optionnelles:
#   REPO_ROOT      : racine du depot (defaut: /var/www/dep.auxinux.ca/VIRTUA)
#   KERNEL_DIR     : dossier des .deb (defaut: REPO_ROOT/KERNEL)
#   SIGN           : 1 = signe le depot avec GPG, 0 = trusted=yes (defaut: 1)
#   GPG_KEY        : id/email de la cle de signature (requis si SIGN=1)
#   KEEP_VERSIONS  : nb de versions a garder par paquet, 0 = tout garder (defaut: 3)
#   ZFS_META_DEP    : depends, recommends ou none (defaut: recommends)
#   ARCHES         : architectures APT publiees (defaut: "amd64 arm64")
#   KERNEL_FLAVOUR : suffixe kernel suivi par le paquet meta (optionnel)
#   META_PACKAGE   : paquet meta installe par les clients (optionnel)
#   DEPLOY=1       : copie le dépôt final vers DEPLOY_TARGET (optionnel)
#   DEPLOY_TARGET  : cible locale ou rsync distante pour la publication
#                    si aucun des deux n'est defini, genere:
#                      auxinux-virtua  -> kernel-virtua            [amd64]
#                      auxinux-desktop -> kernel-auxinux-desktop   [amd64 arm64]
############################################################

usage() {
  cat <<EOF
AuxiNux Kernel Repository Builder

Imports kernel .deb packages, generates meta-packages, rebuilds the APT
repository metadata, and optionally signs the repository.

Usage:
  sudo $0 [IMPORT_DIR]
  sudo $0 -h | --help

Arguments:
  IMPORT_DIR
      Directory containing .deb files to import into the repository.
      If omitted, KERNEL_DIR is used and no import copy is performed.

Default repository layout:
  REPO_ROOT/dists/kernel/main/binary-amd64/Packages
  REPO_ROOT/dists/kernel/main/binary-arm64/Packages
  REPO_ROOT/KERNEL/*.deb

Environment options:
  REPO_ROOT=/path
      Repository root. Default: /var/www/dep.auxinux.ca/VIRTUA

  KERNEL_DIR=/path
      Directory that stores kernel .deb packages.
      Default: REPO_ROOT/KERNEL

  SIGN=1|0
      Sign Release/InRelease with GPG. Default: 1.
      Use SIGN=0 only for trusted=yes/internal testing.

  GPG_KEY=id-or-email
      GPG signing key used when SIGN=1.

  KEEP_VERSIONS=n
      Number of versions to keep per package name.
      Default: 3. Use 0 to keep everything.

  ZFS_META_DEP=depends|recommends|none
      How kernel meta-packages reference the openzfs-zfs-dkms source package
      (compiled by DKMS on the end user's machine, not shipped precompiled).
      Default: recommends.

  ARCHES="amd64 arm64"
      Debian package architectures published by the repository.

  KERNEL_FLAVOUR=name
  META_PACKAGE=name
      When both are omitted, the script automatically generates:
        auxinux-virtua   -> kernel-virtua           [amd64 only]
        auxinux-desktop  -> kernel-auxinux-desktop  [amd64 + arm64]

      When either is set, only one meta-package is generated.

Examples:
  sudo GPG_KEY='repo@auxinux.ca' $0 /tmp/virtua-kernel

  sudo SIGN=0 $0 .

  sudo KERNEL_FLAVOUR=auxinux-desktop \\
       META_PACKAGE=kernel-auxinux-desktop \\
       GPG_KEY='repo@auxinux.ca' $0 /tmp/desktop-kernel

Client setup for a signed repository:
  sudo wget -O /usr/share/keyrings/virtua-archive-keyring.gpg \\
    https://dep.auxinux.ca/VIRTUA/virtua-archive-keyring.gpg

  echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64,arm64] https://dep.auxinux.ca/VIRTUA kernel main' \\
    | sudo tee /etc/apt/sources.list.d/virtua-kernel.list

Client install examples:
  sudo apt update
  sudo apt install kernel-virtua
  sudo apt install kernel-auxinux-desktop
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

if (( $# > 1 )); then
  echo "ERROR: too many arguments." >&2
  usage
  exit 1
fi

die() { echo; echo "ERREUR: $*" >&2; exit 1; }

# Canal de publication: prod -> suite APT "kernel" + KERNEL/
#                       dev  -> suite APT "kernel-dev" + KERNEL-DEV/
# Les deux canaux sont physiquement separes: un kernel DEV ne peut pas fuiter
# dans l'index de prod, et chaque canal a sa propre retention.
RELEASE_TRACK="${RELEASE_TRACK:-prod}"
case "$RELEASE_TRACK" in
  prod) _TRACK_DIST="kernel";     _TRACK_SUBDIR="KERNEL" ;;
  dev)  _TRACK_DIST="kernel-dev"; _TRACK_SUBDIR="KERNEL-DEV" ;;
  *) die "RELEASE_TRACK invalide: ${RELEASE_TRACK}. Valeurs: prod, dev." ;;
esac

REPO_ROOT="${REPO_ROOT:-/var/www/dep.auxinux.ca/VIRTUA}"
KERNEL_DIR="${KERNEL_DIR:-${REPO_ROOT}/${_TRACK_SUBDIR}}"
REPO_LABEL="${REPO_LABEL:-Virtua Kernel Repository}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-Virtua Custom Kernel Repository}"
PUBLIC_REPO_URL="${PUBLIC_REPO_URL:-https://dep.auxinux.ca/VIRTUA}"
KEYRING_BASENAME="${KEYRING_BASENAME:-virtua-archive-keyring}"
SOURCES_LIST_NAME="${SOURCES_LIST_NAME:-virtua-kernel}"
IMPORT_DIR="${1:-$KERNEL_DIR}"
DEPLOY="${DEPLOY:-0}"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"

DIST="${DIST:-$_TRACK_DIST}"
COMPONENT="main"
ARCHES="${ARCHES:-amd64 arm64}"

SIGN="${SIGN:-1}"
GPG_KEY="${GPG_KEY:-}"
KEEP_VERSIONS="${KEEP_VERSIONS:-2}"
# "none" par defaut: le meta kernel ne tire PAS automatiquement openzfs-zfs-dkms.
# APT installe les Recommends par defaut, ce qui reviendrait a declencher la
# compilation CDDL+GPL chez l'utilisateur sans qu'il l'ait demandee. Debian ne
# fait jamais ca: l'utilisateur tape explicitement `apt install openzfs-zfs-dkms`.
ZFS_META_DEP="${ZFS_META_DEP:-none}"
FORBIDDEN_PACKAGE_PATTERNS="${FORBIDDEN_PACKAGE_PATTERNS:-auxinuxos}"

# Le script tourne en root (sudo), mais la clé GPG vit en général dans le
# trousseau de l'utilisateur qui a lancé sudo, pas dans /root/.gnupg.
# On pointe GNUPGHOME dessus, sauf si déjà défini explicitement.
if [[ -z "${GNUPGHOME:-}" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  _sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n "$_sudo_home" && -d "$_sudo_home/.gnupg" ]] && GNUPGHOME="$_sudo_home/.gnupg"
fi
[[ -n "${GNUPGHOME:-}" ]] && export GNUPGHOME
CUSTOM_META_CONFIG=0
if [[ -n "${KERNEL_FLAVOUR+x}" || -n "${META_PACKAGE+x}" ]]; then
  CUSTOM_META_CONFIG=1
fi
KERNEL_FLAVOUR="${KERNEL_FLAVOUR:-auxinux-virtua}"
META_PACKAGE="${META_PACKAGE:-kernel-virtua}"

if (( CUSTOM_META_CONFIG == 1 )); then
  META_PROFILES=("${KERNEL_FLAVOUR}:${META_PACKAGE}:${ARCHES}")
else
  META_PROFILES=(
    "auxinux-virtua:kernel-virtua:amd64"
    "auxinux-desktop:kernel-auxinux-desktop:${ARCHES}"
  )
fi

KEYRING_ASC="${REPO_ROOT}/${KEYRING_BASENAME}.asc"
KEYRING_GPG="${REPO_ROOT}/${KEYRING_BASENAME}.gpg"

echo "=================================================="
echo " Virtua Repository Builder"
echo "=================================================="
echo "Canal         : $RELEASE_TRACK (suite APT: $DIST)"
echo "Repo root     : $REPO_ROOT"
echo "Kernel dir    : $KERNEL_DIR"
echo "Import dir    : $IMPORT_DIR"
echo "Architectures : $ARCHES"
echo "Signature GPG : $([[ "$SIGN" == "1" ]] && echo "oui ($GPG_KEY)" || echo "non (trusted=yes)")"
echo "Versions gard.: $([[ "$KEEP_VERSIONS" -eq 0 ]] && echo "toutes" || echo "$KEEP_VERSIONS")"
echo "ZFS meta dep. : $ZFS_META_DEP"
echo "Profils meta  : ${META_PROFILES[*]}"
echo "Deploy        : $([[ "$DEPLOY" == "1" ]] && echo "oui -> ${DEPLOY_TARGET:-<non défini>}" || echo "non")"
echo

[[ $EUID -eq 0 ]] || die "lance ce script avec sudo."

# Prépare les répertoires de travail/publikation manquants pour éviter une
# création manuelle préalable sur un serveur dépôt neuf.
mkdir -p "$REPO_ROOT" "$KERNEL_DIR" "$IMPORT_DIR"

# Comparaison par chemin canonique: "/x/KERNEL/" et "/x/KERNEL" sont le meme
# dossier. Sans ca, la branche d'import etait prise et `cp` refusait de copier
# un fichier sur lui-meme -> publication entierement avortee.
IMPORT_DIR="$(realpath "$IMPORT_DIR")"
KERNEL_DIR="$(realpath "$KERNEL_DIR")"

if [[ "$SIGN" == "1" && -z "$GPG_KEY" ]]; then
  die "SIGN=1 mais GPG_KEY non défini.
Crée une clé dédiée puis relance avec GPG_KEY=...:
  gpg --quick-generate-key 'Virtua Kernel Repository <repo@auxinux.ca>' rsa4096 sign 0
  gpg --list-secret-keys --keyid-format=long
  sudo GPG_KEY='repo@auxinux.ca' ./build-depot-kernel-core.sh
Ou désactive la signature (déconseillé pour un dépôt public): SIGN=0"
fi

# Vérifie tôt que la clé secrète est accessible (évite d'échouer à l'étape [8/9]).
if [[ "$SIGN" == "1" ]]; then
  if ! gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1; then
    die "clé secrète GPG introuvable pour '${GPG_KEY}' (GNUPGHOME=${GNUPGHOME:-/root/.gnupg}).
La clé a probablement été créée par un autre utilisateur que root.
Relance en pointant le bon trousseau, ex:
  sudo GNUPGHOME=/home/${SUDO_USER:-debian}/.gnupg GPG_KEY='${GPG_KEY}' ./build-depot-kernel-core.sh
Ou crée la clé directement dans ce trousseau (en root)."
  fi
fi

# Un dépôt non signé (trusted=yes) ne doit pas être publié par accident.
if [[ "$SIGN" != "1" && "${ALLOW_UNSIGNED:-0}" != "1" ]]; then
  die "SIGN=0 publie un dépôt NON signé (trusted=yes), dangereux en production.
Confirme explicitement avec ALLOW_UNSIGNED=1 si c'est volontaire (test/interne)."
fi

apt-get update
DEPS=(apt-utils dpkg-dev xz-utils)
[[ "$SIGN" == "1" ]] && DEPS+=(gnupg)
apt-get install -y "${DEPS[@]}"

############################################################
# [1/9] Import des paquets
############################################################
echo "[1/9] Import des paquets..."

if [[ "$IMPORT_DIR" != "$KERNEL_DIR" ]]; then
  found=0
  while IFS= read -r -d '' f; do
    cp -fv "$f" "$KERNEL_DIR"/
    found=1
  done < <(find "$IMPORT_DIR" -maxdepth 1 -name '*.deb' -print0)
  (( found == 1 )) || echo "  (aucun .deb dans $IMPORT_DIR)"
else
  echo "  (import_dir = kernel_dir, rien à copier)"
fi

# Validation appliquee a TOUT le contenu de KERNEL_DIR, pas seulement aux
# fichiers importes: sans import (le cas par defaut, IMPORT_DIR=KERNEL_DIR),
# l'ancienne version n'inspectait rien et signait tel quel ce qui trainait,
# y compris un paquet etranger a ce depot depose lors d'un run precedent.
echo "  Validation du contenu de KERNEL_DIR..."
for f in "$KERNEL_DIR"/*.deb; do
  [[ -e "$f" ]] || continue
  dpkg-deb -I "$f" >/dev/null 2>&1 || die "fichier .deb invalide ou corrompu: $f"
  pkg_name="$(dpkg-deb -f "$f" Package)"
  for forbidden_pattern in $FORBIDDEN_PACKAGE_PATTERNS; do
    if [[ "$pkg_name" == *"$forbidden_pattern"* ]]; then
      die "paquet '${pkg_name}' refusé dans ce dépôt (${REPO_ROOT}).
Fichier: $f
Utilise le générateur de dépôt correspondant; pour AuxiNuxOS:
  sudo GPG_KEY='repo@auxinux.ca' ./build-depot-AuxiNuxOS.sh ${IMPORT_DIR}"
    fi
  done
done

# Normalise TOUS les .deb au format APT canonique <Package>_<Version>_<Arch>.deb.
# dpkg-scanpackages n'indexe de façon fiable que les fichiers nommés ainsi:
# des noms personnalisés (sans version/arch) sont ignorés -> meta non installable.
# Corrige aussi en place les fichiers déjà présents (pas besoin de recompiler).
echo "  Normalisation des noms de fichiers..."
for f in "$KERNEL_DIR"/*.deb; do
  [[ -e "$f" ]] || continue
  p="$(dpkg-deb -f "$f" Package)"
  v="$(dpkg-deb -f "$f" Version)"
  a="$(dpkg-deb -f "$f" Architecture)"
  [[ -n "$p" && -n "$v" && -n "$a" ]] || continue
  canonical="${p}_${v//:/%3a}_${a}.deb"   # ':' (epoch) interdit dans un nom de fichier
  if [[ "$(basename "$f")" != "$canonical" ]]; then
    echo "    $(basename "$f") -> $canonical"
    mv -f "$f" "$KERNEL_DIR/$canonical"
  fi
done

############################################################
# [2/9] Purge des anciennes versions
############################################################
echo "[2/9] Purge des anciennes versions..."

# Garde au plus $n versions par couple (Package, Architecture) dans KERNEL_DIR.
# Étape 1: liste les couples (package, arch) distincts réellement présents.
# Étape 2: pour chaque couple, retrouve tous ses fichiers, triés par version
# croissante (sort -V sur la Version dpkg, chemin extrait ensuite via cut) ;
# les plus anciens en excédent de $n sont supprimés.
# Regroupe les paquets par SERIE plutot que par nom exact. Un noyau porte la
# release complete dans son nom (linux-image-7.1.10-auxinux-virtua-amd64), donc
# chaque release est un nom de paquet UNIQUE: grouper par nom laissait toujours
# une seule version par groupe et la purge ne supprimait jamais rien.
# On extrait donc (prefixe, flavour-arch) comme cle de serie et la version
# upstream comme cle de tri.
#   linux-image-7.1.10-auxinux-virtua-amd64      -> serie "linux-image-|-auxinux-virtua-amd64"      v=7.1.10
#   linux-image-7.1.3-auxinux-virtua-amd64-dbg   -> serie "linux-image-|-auxinux-virtua-amd64-dbg"  v=7.1.3
#   linux-headers-7.1.10-auxinux-virtua-amd64    -> serie "linux-headers-|-auxinux-virtua-amd64"    v=7.1.10
# Les paquets non-noyau (meta, openzfs-zfs-dkms) gardent le tri par version dpkg.
KVER_RE='^(linux-(image|headers)-)([0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?)(-.+)$'

series_key() {
  if [[ "$1" =~ $KVER_RE ]]; then
    printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[6]}"
  else
    printf '%s\n' "$1"
  fi
}

sort_key() {
  # Version upstream pour un noyau, version dpkg sinon.
  if [[ "$1" =~ $KVER_RE ]]; then
    printf '%s\n' "${BASH_REMATCH[3]}"
  else
    printf '%s\n' "$2"
  fi
}

prune_old() {
  local n="$1"
  if (( n <= 0 )); then
    echo "  Purge désactivée (KEEP_VERSIONS=0)."
    return 0
  fi

  # Index unique: serie <TAB> arch <TAB> cle-de-tri <TAB> chemin
  local index
  index="$(for f in "$KERNEL_DIR"/*.deb; do
             [[ -e "$f" ]] || continue
             local pk vr ar
             pk="$(dpkg-deb -f "$f" Package)"; vr="$(dpkg-deb -f "$f" Version)"
             ar="$(dpkg-deb -f "$f" Architecture)"
             [[ -n "$pk" && -n "$ar" ]] || continue
             printf '%s\t%s\t%s\t%s\n' "$(series_key "$pk")" "$ar" "$(sort_key "$pk" "$vr")" "$f"
           done)"
  [[ -n "$index" ]] || { echo "  (aucun paquet à purger)"; return 0; }

  local serie arch
  while IFS=$'\t' read -r serie arch; do
    [[ -n "$serie" ]] || continue
    local files=()
    mapfile -t files < <(
      awk -F'\t' -v s="$serie" -v a="$arch" '$1==s && $2==a {print $3"\t"$4}' <<< "$index" \
        | sort -V | cut -f2-
    )
    local count=${#files[@]}
    if (( count > n )); then
      local remove=$(( count - n )) i
      echo "  ${serie/|/*} [$arch]: $count versions -> suppression des $remove plus anciennes"
      for ((i=0; i<remove; i++)); do
        echo "    rm $(basename "${files[$i]}")"
        rm -f "${files[$i]}"
      done
    fi
  done < <(cut -f1,2 <<< "$index" | sort -u)
}

prune_old "$KEEP_VERSIONS"

############################################################
# [3/9] Génération du paquet meta
############################################################
echo "[3/9] Génération du paquet meta..."

generate_meta_package() {
  local kernel_flavour="$1"
  local meta_package="$2"
  local deb_arch="$3"
  local record image_version image_pkg image_file kernel_release
  local header_pkg header_version deps recommends tmp safe_version pkg version pkg_arch

  record="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      pkg="$(dpkg-deb -f "$f" Package)"
      version="$(dpkg-deb -f "$f" Version)"
      pkg_arch="$(dpkg-deb -f "$f" Architecture)"
      [[ "$pkg_arch" == "$deb_arch" ]] || continue
      case "$pkg" in
        # Ignore les paquets de symboles de debug: le meta doit dépendre
        # du vrai noyau, pas de linux-image-...-dbg / -dbgsym.
        linux-image-*-"${kernel_flavour}"-*-dbg) ;;
        linux-image-*-"${kernel_flavour}"-*-dbgsym) ;;
        linux-image-*-"${kernel_flavour}"-*)
          # Anti-fuite entre canaux: le glob "*" qui precede le flavour
          # matcherait aussi "7.2.2-dev-auxinux-virtua". En canal prod on
          # ignore donc explicitement tout paquet portant le marqueur dev.
          if [[ "$kernel_flavour" != dev-* && "$pkg" == *-dev-* ]]; then
            continue
          fi
          printf '%s\t%s\t%s\n' "$version" "$pkg" "$f"
          ;;
      esac
    done | sort -V | tail -n1
  )"

  if [[ -z "$record" ]]; then
    echo "  Aucun paquet linux-image-*-${kernel_flavour}-* [$deb_arch] trouvé, meta ${meta_package} non généré."
    return 0
  fi

  IFS=$'\t' read -r image_version image_pkg image_file <<< "$record"
  kernel_release="${image_pkg#linux-image-}"
  header_pkg="linux-headers-${kernel_release}"
  deps="${image_pkg} (= ${image_version})"
  recommends=""

  header_version="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      if [[ "$(dpkg-deb -f "$f" Package)" == "$header_pkg" ]]; then
        pkg_arch="$(dpkg-deb -f "$f" Architecture)"
        [[ "$pkg_arch" == "$deb_arch" || "$pkg_arch" == "all" ]] || continue
        dpkg-deb -f "$f" Version
        break
      fi
    done
  )"

  if [[ -n "$header_version" ]]; then
    deps="${deps}, ${header_pkg} (= ${header_version})"
  else
    echo "  AVERTISSEMENT: headers absents pour ${kernel_release}; meta image seulement."
  fi

  # Paquet source OpenZFS (DKMS) présent dans le dépôt, le cas échéant. Contrairement
  # à l'ancien module précompilé (nommé par release kernel), openzfs-zfs-dkms est un
  # paquet source unique (arch=all, un par version d'OpenZFS) qui se compile chez
  # l'utilisateur via DKMS: sans les headers du kernel cible (Depends ci-dessus),
  # cette compilation échoue à l'install plutôt qu'au build — d'où l'importance de
  # header_pkg en Depends dès que ZFS est apparié. Par défaut le paquet ZFS lui-même
  # reste en Recommends: le paquet kernel reste installable même si DKMS échoue.
  local zfs_pkg zfs_version
  zfs_pkg="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      pkg="$(dpkg-deb -f "$f" Package)"
      pkg_arch="$(dpkg-deb -f "$f" Architecture)"
      [[ "$pkg_arch" == "$deb_arch" || "$pkg_arch" == "all" ]] || continue
      [[ "$pkg" == "openzfs-zfs-dkms" ]] && { echo "$pkg"; break; }
    done
  )"
  if [[ -n "$zfs_pkg" && "$ZFS_META_DEP" != "none" && -z "$header_version" ]]; then
    die "openzfs-zfs-dkms trouvé mais ${header_pkg} absent du dépôt.
DKMS échouera à l'install sans les headers exacts du kernel cible: publie
${header_pkg} avant de republier ce dépôt, ou ZFS_META_DEP=none pour ignorer
explicitement l'appariement ZFS de ce build."
  fi

  if [[ -n "$zfs_pkg" ]]; then
    zfs_version="$(
      for f in "$KERNEL_DIR"/*.deb; do
        [[ -e "$f" ]] || continue
        [[ "$(dpkg-deb -f "$f" Package)" == "$zfs_pkg" ]] || continue
        dpkg-deb -f "$f" Version; break
      done
    )"
    case "$ZFS_META_DEP" in
      depends)
        deps="${deps}, ${zfs_pkg} (= ${zfs_version})"
        echo "  + ZFS apparié en Depends: ${zfs_pkg} (${zfs_version})"
        ;;
      recommends)
        recommends="${zfs_pkg} (= ${zfs_version})"
        echo "  + ZFS apparié en Recommends: ${zfs_pkg} (${zfs_version})"
        ;;
      none)
        echo "  + ZFS apparié détecté mais ignoré par le meta: ${zfs_pkg} (${zfs_version})"
        ;;
      *)
        die "ZFS_META_DEP invalide: ${ZFS_META_DEP}. Valeurs: depends, recommends, none."
        ;;
    esac
  fi

  rm -f "$KERNEL_DIR/${meta_package}"_*_"${deb_arch}".deb

  tmp="$(mktemp -d)"
  mkdir -p "$tmp/DEBIAN" "$tmp/usr/share/doc/$meta_package"
  cat > "$tmp/DEBIAN/control" <<EOF
Package: ${meta_package}
Version: ${image_version}
Architecture: ${deb_arch}
Section: kernel
Priority: optional
Maintainer: AuxiNux <repo@auxinux.ca>
Depends: ${deps}
EOF
  [[ -n "$recommends" ]] && printf 'Recommends: %s\n' "$recommends" >> "$tmp/DEBIAN/control"
  cat >> "$tmp/DEBIAN/control" <<EOF
Description: AuxiNux kernel meta-package
 This package depends on the latest AuxiNux ${kernel_flavour} kernel image and headers.
EOF
  printf 'AuxiNux %s kernel meta-package\n' "$kernel_flavour" > "$tmp/usr/share/doc/$meta_package/README"
  gzip -9n "$tmp/usr/share/doc/$meta_package/README"

  safe_version="${image_version//:/_}"
  dpkg-deb --build "$tmp" "$KERNEL_DIR/${meta_package}_${safe_version}_${deb_arch}.deb" >/dev/null
  rm -rf "$tmp"

  echo "  ${meta_package} [$deb_arch] -> ${image_pkg} (${image_version})"
}

for meta_profile in "${META_PROFILES[@]}"; do
  IFS=':' read -r meta_flavour meta_package meta_arches <<< "$meta_profile"
  for deb_arch in $meta_arches; do
    generate_meta_package "$meta_flavour" "$meta_package" "$deb_arch"
  done
done

############################################################
# [4/9] Création arborescence
############################################################
echo "[4/9] Création arborescence..."

for deb_arch in $ARCHES; do
  mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/binary-${deb_arch}"
done
mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/binary-all"
mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/i18n"

############################################################
# [5/9] Génération Packages
############################################################
echo "[5/9] Génération Packages..."

# IMPORTANT: on scanne un chemin RELATIF à la racine du dépôt pour que
# le champ Filename soit "KERNEL/xxx.deb" et non un chemin absolu
# (sinon apt construit une URL invalide et apt install échoue).
cd "$REPO_ROOT"
REL_KERNEL="$(realpath --relative-to="$REPO_ROOT" "$KERNEL_DIR")"

case "$REL_KERNEL" in
  ../*|/*) die "KERNEL_DIR doit être à l'intérieur de REPO_ROOT pour générer un Filename valide." ;;
esac

for deb_arch in $ARCHES; do
  pkg_file="$REPO_ROOT/dists/$DIST/$COMPONENT/binary-${deb_arch}/Packages"
  # --multiversion: KEEP_VERSIONS peut laisser plusieurs versions du même
  # paquet côte à côte dans KERNEL_DIR ; sans ce flag, dpkg-scanpackages
  # n'indexerait que la plus récente et les anciennes deviendraient
  # ininstallables via apt bien que présentes sur disque.
  dpkg-scanpackages --multiversion --arch "$deb_arch" "$REL_KERNEL" /dev/null > "$pkg_file"
  gzip -9fk "$pkg_file"
  xz   -9fk "$pkg_file"
done

############################################################
# [6/9] binary-all + i18n (vides)
############################################################
echo "[6/9] Génération binary-all et i18n..."

PKG_ALL="$REPO_ROOT/dists/$DIST/$COMPONENT/binary-all/Packages"
: > "$PKG_ALL"
gzip -9fk "$PKG_ALL"
xz   -9fk "$PKG_ALL"

I18N="$REPO_ROOT/dists/$DIST/$COMPONENT/i18n/Translation-en"
: > "$I18N"
gzip -9fk "$I18N"
xz   -9fk "$I18N"

############################################################
# [7/9] Génération Release
############################################################
echo "[7/9] Génération Release..."

cd "$REPO_ROOT/dists/$DIST"

apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="AuxiNux" \
  -o APT::FTPArchive::Release::Label="$REPO_LABEL" \
  -o APT::FTPArchive::Release::Suite="$DIST" \
  -o APT::FTPArchive::Release::Codename="$DIST" \
  -o APT::FTPArchive::Release::Architectures="${ARCHES} all" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="$REPO_DESCRIPTION" \
  release . > Release

############################################################
# [8/9] Signature GPG
############################################################
echo "[8/9] Signature..."

rm -f Release.gpg InRelease

if [[ "$SIGN" == "1" ]]; then
  # Release.gpg = signature détachée ; InRelease = Release signé inline.
  gpg --batch --yes --default-key "$GPG_KEY" -abs -o Release.gpg Release
  gpg --batch --yes --default-key "$GPG_KEY" --clearsign -o InRelease Release

  # Publie la clé publique pour les utilisateurs (format .asc et .gpg).
  gpg --armor --export "$GPG_KEY" > "$KEYRING_ASC"
  gpg --export "$GPG_KEY"          > "$KEYRING_GPG"
  echo "  Clé publique publiée: $KEYRING_GPG"
else
  echo "  Signature désactivée (SIGN=0) — dépôt en trusted=yes."
fi

############################################################
# [9/9] Permissions
############################################################
echo "[9/9] Permissions..."

# Ne rend lisibles que les éléments réellement publiés (pas tout REPO_ROOT,
# qui peut contenir d'autres fichiers/clés privées hors de ce dépôt).
chmod a+rX "$REPO_ROOT"
chmod -R a+rX "$KERNEL_DIR" "$REPO_ROOT/dists"
[[ -f "$KEYRING_ASC" ]] && chmod a+r "$KEYRING_ASC"
[[ -f "$KEYRING_GPG" ]] && chmod a+r "$KEYRING_GPG"

if [[ "$DEPLOY" == "1" ]]; then
  [[ -n "$DEPLOY_TARGET" ]] || die "DEPLOY=1 mais DEPLOY_TARGET est vide."
  echo
  echo "[10/10] Déploiement vers ${DEPLOY_TARGET}..."
  if [[ "$DEPLOY_TARGET" == *:* ]]; then
    rsync -a --delete "$REPO_ROOT/" "${DEPLOY_TARGET%/}/"
  else
    mkdir -p "$DEPLOY_TARGET"
    rsync -a --delete "$REPO_ROOT/" "${DEPLOY_TARGET%/}/"
  fi
fi

############################################################
# Fin
############################################################
echo
echo "=================================================="
echo " Dépôt généré avec succès"
echo "=================================================="
echo
echo "Paquets actuellement dans le dépôt:"
ls -1 "$KERNEL_DIR"/*.deb 2>/dev/null | sed 's/^/  /' || echo "  (aucun)"
echo

if [[ "$SIGN" == "1" ]]; then
  echo "Configuration côté client (dépôt signé):"
  echo
  echo "  sudo wget -O /usr/share/keyrings/${KEYRING_BASENAME}.gpg \\"
  echo "       ${PUBLIC_REPO_URL}/${KEYRING_BASENAME}.gpg"
  echo
  echo "  echo 'deb [signed-by=/usr/share/keyrings/${KEYRING_BASENAME}.gpg arch=amd64,arm64] ${PUBLIC_REPO_URL} ${DIST} main' \\"
  echo "       | sudo tee /etc/apt/sources.list.d/${SOURCES_LIST_NAME}.list"
  echo
else
  echo "Configuration côté client (non signé):"
  echo "  deb [trusted=yes arch=amd64,arm64] ${PUBLIC_REPO_URL} ${DIST} main"
  echo
fi

echo "Test:"
echo "  sudo apt update"
for meta_profile in "${META_PROFILES[@]}"; do
  IFS=':' read -r _meta_flavour meta_package _meta_arches <<< "$meta_profile"
  echo "  apt-cache policy ${meta_package}"
done
echo
