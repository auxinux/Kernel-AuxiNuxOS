# AuxiNuxOS Kernel

Noyau dédié aux éditions poste de travail d'AuxiNuxOS (Debian 13 / Trixie,
bureau COSMIC sur Wayland).

Le wrapper cible le profil `auxinuxos` et publie vers le dépôt de noyaux
AuxiNuxOS. Les moteurs de build et de dépôt sont inclus localement : ce dépôt
peut être cloné et utilisé sans Kernel/VirtuaOS.

```bash
./build-AuxiNuxOS-kernel.sh -config-only      # build à blanc: vérifie la config
./build-AuxiNuxOS-kernel.sh                   # build complet amd64
./build-AuxiNuxOS-kernel.sh -arch=arm64       # build complet arm64 (croisé)
sudo GPG_KEY=repo@auxinux.ca ./build-depot-AuxiNuxOS.sh ./output
```

| | |
|---|---|
| Série noyau | **7.2.x** (`--branch=7.2` par défaut) |
| Architectures | **amd64** et **arm64** |
| Release produite | `X.Y.Z-auxinuxos-amd64`, `X.Y.Z-auxinuxos-arm64` |
| Paquet meta | `kernel-auxinuxos` |
| Suite APT | `kernel` — `https://dep.auxinux.ca/AUXINUXOS` |

## Orientation : poste de travail

Ce noyau vise une seule machine qui doit faire de la **bureautique**, du
**multimédia** et du **jeu**, sans perdre **LXC**, **Docker** ni **KVM**. Les
choix de configuration et leur justification sont dans
[PLAN-7.2-DESKTOP.md](PLAN-7.2-DESKTOP.md). En résumé :

* **GPU Intel, AMD et NVIDIA** — `i915` + `xe`, `amdgpu` avec Display Core et
  le support GCN 1/2, `nouveau`. Le pilote NVIDIA propriétaire compile via DKMS
  grâce aux gardes `TRIM_UNUSED_KSYMS=n` / `MODULE_SIG_FORCE=n` / `MODVERSIONS=y`.
* **Fluidité** — préemption complète à 1000 Hz, `SCHED_AUTOGROUP`, MGLRU,
  `UCLAMP_TASK`, BFQ, `schedutil` avec intel-pstate et amd-pstate.
* **ZRAM** — module + backend zstd, `ZRAM_WRITEBACK`, aligné sur `zram-tools`.
  `ZSWAP` est compilé mais **inerte** : l'empiler devant un swap zram
  compresserait deux fois les mêmes pages.
* **`PSI`** — prérequis dur de `systemd-oomd`, qui sans lui démarre et ne fait
  rien. Avec `MEMCG` pour la pression par tranche cgroup.
* **Jeu** — `ntsync` (Wine/Proton), `IA32_EMULATION` réellement actif, manettes
  Xbox / DualSense / Switch Pro / Steam, `NET_SCH_CAKE`.
* **Rollback** — voir ci-dessous.
* **Conteneurs** — pile cgroups v2 complète, `NETFILTER_XTABLES_LEGACY` (requis
  par `docker` et `lxc-net` depuis 7.x), et la chaîne LSM exacte de Debian 13.

## ARM64

Le même profil `auxinuxos` produit un noyau arm64, compilé en croisé depuis le
serveur de build amd64 (`gcc-aarch64-linux-gnu`). Tout le cahier des charges du
poste de travail est conservé — préemption complète à 1000 Hz, MGLRU, PSI,
ZRAM, BTF, rollback BTRFS, LXC/Docker/KVM, modules en xz — et chaque section
spécifique à x86 a son équivalent ARM.

**Config de base.** C'est la config du noyau **Debian arm64** de
`trixie-backports`, téléchargée et vérifiée à chaque build (InRelease par
`gpgv` contre `debian-archive-keyring`, puis SHA256 de `Packages.xz` et du
`.deb`) — l'exact pendant de `/boot/config-*-amd64` côté x86. L'ancien repli
`make defconfig` donnait un noyau de carte d'évaluation sans rapport avec
Debian. `BASE_CONFIG_ARM64=/chemin` force une config précise (build hors ligne).

| Côté x86 | Équivalent arm64 |
|---|---|
| i915, SOF Intel/AMD | Panthor, Panfrost, Lima, MSM (Adreno), V3D/VC4, Rockchip, Tegra, Etnaviv ; cartes son DT, Snapdragon X |
| VA-API par le GPU | décodeurs V4L2 dédiés : Hantro, rkvdec, Venus |
| intel/amd-pstate, acpi-cpufreq | cpufreq-dt, SCMI, CPPC, Qualcomm, Raspberry Pi ; cpuidle PSCI |
| Turbo Boost Max (`SCHED_MC_PRIO`) | **Energy Aware Scheduling** (`ENERGY_MODEL`) + AMU pour big.LITTLE |
| — | pages **4 Ko** obligatoires (FEX-Emu, Box64, Wine, Chromium), `ARM64_CONTPTE` |
| `IA32_EMULATION` | `COMPAT` (armhf) ; les binaires x86-64 passent par FEX/Box64 via `BINFMT_MISC` |
| AES-NI | extensions Crypto ARMv8 |
| KVM Intel/AMD, VT-d/AMD-Vi | KVM arm64, SMMUv2/v3 |
| WMI constructeurs | EC des portables Snapdragon X, batterie `pmic_glink`, `pwm-fan` |
| Mitigations x86 | KPTI, Spectre-BHB, PAC, BTI, E0PD, MTE, GCS |
| `vmlinuz` zstd | `Image.gz`, comme Debian : `EFI_ZBOOT` n'est pas lisible par U-Boot `booti` |

Machines visées : VM arm64 (QEMU/UTM/Parallels/VMware Fusion sur Mac Apple
Silicon — virtio-PCI et virtio-MMIO en built-in), Raspberry Pi 4/5, cartes
RK3588 (Orange Pi 5, Rock 5), portables Snapdragon X, stations Ampere/CIX.
Les Mac Apple Silicon **en natif** ne sont pas visés : leur support amont est
incomplet et suppose des pages de 16 Ko.

Le contrôle « racine montable sans initramfs » ajoute sur arm64
`PCI_HOST_GENERIC`, `VIRTIO_MMIO`, `MMC` et `MMC_BLOCK` à la liste
`CRITICAL_BUILTIN`. Sur les cartes ARM, le contrôleur SD/eMMC lui-même reste en
module (horloges et régulateurs le sont aussi) : la garantie complète vaut pour
les VM et les machines UEFI/ACPI.

## Rollback : ce que le noyau doit garantir

Le [rollback d'AuxiNuxOS](https://git.auxinux.ca/Auxinux/AuxinuxOS) démarre sur
un instantané BTRFS **en lecture seule** via `grub-btrfs`, en superposant un
tmpfs inscriptible par un hook initramfs. Trois options sont donc vérifiées
comme **built-in obligatoires**, pas seulement « présentes » :

| Option | Pourquoi built-in |
|---|---|
| `BTRFS_FS=y` | la racine doit monter même avec un initramfs cassé — c'est-à-dire précisément dans la situation où l'on veut restaurer |
| `ZSTD_COMPRESS`/`ZSTD_DECOMPRESS=y` | la racine est montée `compress=zstd:1` |
| `TMPFS_XATTR=y` | OverlayFS **refuse** de se monter si l'`upperdir` ne gère pas les attributs étendus |

Le build échoue si l'une d'elles retombe en module (liste `CRITICAL_BUILTIN`).

## Garde-fou de configuration

`scripts/config` accepte sans broncher un symbole inexistant : il écrit la
ligne dans `.config`, qu'`olddefconfig` supprime ensuite en silence. Un symbole
renommé entre deux versions du noyau était donc un **no-op parfaitement
invisible**.

L'étape `[6a]` indexe tous les symboles Kconfig de l'arbre source et contrôle
que **chaque** option demandée par `cfg()` existe réellement dans cette version
(erreur bloquante) et qu'elle a bien été retenue par `olddefconfig`
(avertissement détaillé).

```bash
./build-AuxiNuxOS-kernel.sh -config-only
```

Le passage de 7.1 à 7.2 a révélé trois symboles morts dans ce script, dont deux
sur le profil AuxiNuxOS : `MT76` et `ATH12K_PCI` — c'est-à-dire aucun Wi-Fi
MediaTek ni Wi-Fi 7 Qualcomm garanti, sans qu'aucune étape ne le signale.

**À lancer à chaque changement de série de noyau, avant toute compilation.**

## Séries et canaux

La **série** est épinglée, pas la révision : `--branch=7.2` suit 7.2.5, puis
7.2.6… sans jamais sauter tout seul sur 7.3. Un changement de série change les
pilotes et les options ; il se décide.

```bash
./build-AuxiNuxOS-kernel.sh                    # dernière 7.2.x
./build-AuxiNuxOS-kernel.sh --branch=7.3       # changer de série, sciemment
./build-AuxiNuxOS-kernel.sh --branch=any       # suivre la dernière stable
```

> La série **7.1 est EOL depuis le 2026-09-02** et ne reçoit plus de correctif
> de sécurité. Le wrapper avertit si la version résolue est marquée EOL.

Deux canaux de publication coexistent, physiquement séparés côté dépôt :

| Canal | Release noyau | Meta-paquet | Suite APT | Dossier |
|---|---|---|---|---|
| `prod` (défaut) | `X.Y.Z-auxinuxos-amd64` | `kernel-auxinuxos` | `kernel` | `KERNEL/` |
| `dev` | `X.Y.Z-dev-auxinuxos-amd64` | `kernel-auxinuxos-dev` | `kernel-dev` | `KERNEL-DEV/` |

```bash
./build-AuxiNuxOS-kernel.sh                          # prod
./build-AuxiNuxOS-kernel.sh track=dev                # dev
sudo RELEASE_TRACK=dev GPG_KEY=repo@auxinux.ca ./build-depot-AuxiNuxOS.sh /tmp/dev
```

Les noms de paquets diffèrent, donc les deux noyaux **coexistent installés** :
on choisit celui à tester au démarrage via GRUB, et le retour arrière est
immédiat.

Le marqueur `dev` est en **minuscules** par obligation : la politique Debian
interdit les majuscules dans un nom de paquet et `dpkg` les convertit
silencieusement, ce qui désynchroniserait le nom du paquet du répertoire
`/lib/modules/$(uname -r)`.

Rétention par défaut : `KEEP_VERSIONS=2` par série et par architecture.

## Configuration client

```bash
sudo wget -O /usr/share/keyrings/auxinuxos-archive-keyring.gpg \
  https://dep.auxinux.ca/AUXINUXOS/auxinuxos-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/auxinuxos-archive-keyring.gpg arch=$(dpkg --print-architecture)] https://dep.auxinux.ca/AUXINUXOS kernel main" \
  | sudo tee /etc/apt/sources.list.d/auxinuxos-kernel.list

sudo apt update && sudo apt install kernel-auxinuxos
```

Ne jamais utiliser `[trusted=yes]` : le dépôt est signé GPG, et `trusted=yes`
dit à APT de sauter entièrement la vérification de signature.

## OpenZFS

Un poste de travail n'a pas besoin de modules OpenZFS couplés au noyau : le
wrapper impose `no-zfs` sauf choix explicite (`WITH_ZFS=1`).

Quand ZFS est activé, ce projet livre OpenZFS en paquet **source** DKMS
(`openzfs-zfs-dkms`), jamais un module précompilé. Linux est GPL-2.0-only et
OpenZFS est CDDL ; distribuer un binaire combinant les deux est une zone grise
juridique (Ubuntu accepte ce risque, Debian non). Ce projet suit l'approche
Debian : le module est compilé par DKMS sur la machine de l'utilisateur, contre
son paquet `linux-headers-*` installé, jamais sur ce serveur de build.

Le meta-paquet ne tire **pas** automatiquement `openzfs-zfs-dkms`
(`ZFS_META_DEP=none` par défaut) : APT installant les `Recommends` par défaut,
l'ancien réglage déclenchait la compilation CDDL+GPL chez l'utilisateur sans
qu'il l'ait demandée.

```bash
sudo apt install openzfs-zfs-dkms
```

## Licence

GPL-2.0-only, voir [LICENSE](LICENSE).

Les binaires publiés dans le dépôt APT sont une œuvre dérivée de Linux et
portent donc l'obligation de la section 3 de la GPL-2.0 : ils doivent être
accompagnés soit de la source complète correspondante, soit d'une offre écrite
de la fournir. « Source complète correspondante » inclut le tarball amont
exact, le `.config` utilisé et les scripts qui pilotent la compilation —
c'est-à-dire ce dépôt plus la version amont épinglée.
