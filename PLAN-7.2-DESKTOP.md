# Plan — Kernel AuxiNuxOS `7.2.5-auxinuxos-amd64`

**Profil :** `auxinuxos` · **Meta :** `kernel-auxinuxos` · **Suite APT :** `kernel`
**Dépôt :** `https://dep.auxinux.ca/AUXINUXOS` · **Date :** 12 septembre 2026
**Statut :** configuration écrite et vérifiée symbole par symbole, aucun build lancé

---

## 0. Constat vérifié avant proposition

| Point | Vérification |
|---|---|
| 7.2 existe | kernel.org `releases.json` : stable **7.2.5**, publiée le **2026-09-11** |
| 7.1 est morte | **7.1.13 marquée EOL le 2026-09-02** — plus aucun correctif de sécurité |
| 7.3 | mainline `7.3-rc2` — hors périmètre |
| Symboles | l'arbre `linux-7.2.5` a été téléchargé et indexé : **21 721 symboles Kconfig**. Les **516 couples (symbole, action)** demandés par le script — dont **456 pour le seul profil `auxinuxos`** — ont été confrontés à cet index |
| Nom du noyau | `KERNEL_FLAVOUR=auxinuxos` → release `7.2.5-auxinuxos-amd64`. Inchangé |

### Trois options du script actuel ne faisaient rien

En confrontant le script 7.1 à l'arbre 7.2.5, trois symboles se révèlent inexistants — donc trois `cfg()` qui n'ont jamais rien produit, **sans le moindre message** :

| Symbole | Réalité en 7.2 | Conséquence |
|---|---|---|
| `CGROUP_NS` | supprimé upstream | aucune (le namespace cgroup existe toujours) |
| `MT76` | n'existe pas ; la bibliothèque interne est `MT76_CORE`, auto-sélectionnée | **aucun Wi-Fi MediaTek** n'était garanti, alors que `MT7921E` équipe une large part des portables depuis 2022 |
| `ATH12K_PCI` | supprimé ; `ATH12K` **est** le pilote PCI | aucun Wi-Fi 7 Qualcomm garanti |

Deux des trois concernent le profil AuxiNuxOS. C'est la démonstration directe du problème traité au §1.

---

## 1. Prérequis : le garde-fou de configuration

Le script reposait sur :

```bash
cfg() { ./scripts/config "$@" || true; }
```

Ce `|| true` avale toute erreur. Pire, `scripts/config` **accepte sans broncher un symbole inexistant** : il écrit la ligne dans `.config`, qu'`olddefconfig` supprime ensuite en silence. Un symbole renommé entre deux versions devenait un no-op parfaitement invisible — exactement les trois cas ci-dessus.

Ce plan ajoute environ **450 options** au profil AuxiNuxOS. En l'état, une part inconnue d'entre elles n'aurait rien fait, et personne ne l'aurait su avant qu'un utilisateur signale un portable sans Wi-Fi.

**Correctif appliqué en premier**, repris de Kernel/VirtuaOS 7.2.4 :

1. `cfg()` est strict (plus de `|| true`) et journalise chaque couple *(symbole, valeur attendue)* dans `CFG_REQUESTS`.
2. Une étape **`[6a]`** indexe tous les `Kconfig` de l'arbre source, puis vérifie chaque option demandée :
   * **INCONNU** — le symbole n'existe pas dans ce noyau → **erreur bloquante** ;
   * **IGNORÉ** — le symbole existe mais `olddefconfig` ne l'a pas retenu → avertissement nommant la valeur obtenue.
3. Un mode **`-config-only`** applique et vérifie la configuration puis s'arrête avant la compilation.

```bash
./build-AuxiNuxOS-kernel.sh -config-only
```

Sans cette étape, le reste de ce plan serait un pari.

### Contrôle supplémentaire : `CRITICAL_BUILTIN`

`opt_on()` accepte `y` **ou** `m`. Or plusieurs options doivent être compilées **en dur**, sous peine de casser précisément le scénario de secours (§4). Un `BTRFS_FS=m` passerait `opt_on` sans que la racine soit montable sans initramfs. Une liste `CRITICAL_BUILTIN` vérifie donc la valeur exacte et interrompt le build sinon.

---

## 2. Ce qui change par rapport à Kernel/VirtuaOS

Le noyau VirtuaOS et le noyau AuxiNuxOS partagent le même moteur de build et la même base Debian 13, mais leurs cibles sont opposées sur plusieurs points. Les reprendre tels quels serait une erreur :

| Sujet | VirtuaOS (hyperviseur) | AuxiNuxOS (poste de travail) | Pourquoi |
|---|---|---|---|
| GPU | `DRM_I915`, `AMDGPU`, `NOUVEAU`, `RADEON`, `XE` **désactivés** | **tous activés** | un pilote hôte lié au GPU empêche le passthrough VFIO ; sur un poste, c'est l'écran |
| `SCHED_AUTOGROUP` | **coupé** (fausse l'équité entre conteneurs) | **activé** | c'est ce qui empêche un `make -j32` de rendre le bureau inutilisable |
| Préemption | `PREEMPT_LAZY` (débit) | **`PREEMPT`** complète (latence) | pointeur, audio PipeWire, régularité des images |
| `HZ` | 250 | **1000** | « the preferred choice for desktop systems » (`kernel/Kconfig.hz`) |
| `SUSPEND` / `HIBERNATION` | **coupés** (classe entière de bugs ACPI en moins) | **activés** | rabattre l'écran est le geste le plus courant qui soit |
| `SOUND`, `MEDIA_SUPPORT` | **retirés** | **complets** (HDA + SOF + UVC) | multimédia demandé |
| Mémoire | ZSWAP actif, ZRAM en module | **ZRAM actif, ZSWAP inerte** | empiler zswap devant un swap zram compresse deux fois les mêmes pages |
| Racine | ext4 **et** BTRFS built-in | **BTRFS built-in** + chaîne rollback | AuxiNuxOS installe en BTRFS par défaut |
| OpenZFS | publié en DKMS | **non publié** (`no-zfs` par le wrapper) | un poste n'en a pas besoin ; les gardes DKMS restent en place pour NVIDIA |

Ce qui est repris **à l'identique** : le garde-fou `[6a]`, `X86_NATIVE_CPU=n`, la chaîne `CONFIG_LSM`, les gardes DKMS, la couverture cpufreq multi-générations, les mitigations spéculatives actives.

---

## 3. Fluidité — les leviers retenus

`docs/performance.md` d'AuxiNuxOS repose sur trois mesures en espace utilisateur : zram, `systemd-oomd`, et l'entretien du stockage. **Deux d'entre elles ont un prérequis noyau qui n'était pas satisfait.**

### 3.1 ZRAM — demandé explicitement

`ZRAM` en **module** (c'est ce qu'attend `zram-tools`, qui le configure via `/etc/default/zramswap` et réinitialise le périphérique à l'arrêt), avec :

* `ZRAM_BACKEND_ZSTD` + `ZRAM_DEF_COMP_ZSTD` — aligné sur `ALGO=zstd` d'AuxiNuxOS ;
* `ZRAM_BACKEND_LZ4` — repli ;
* `ZRAM_WRITEBACK` — les pages incompressibles repartent sur le disque au lieu d'occuper la RAM ;
* `ZRAM_MULTI_COMP`.

**`ZSWAP_DEFAULT_ON=n`.** Empiler zswap devant un swap zram compresse deux fois les mêmes pages, pour un résultat **plus lent** que sans. ZSWAP reste compilé, disponible pour une installation sans zram.

### 3.2 PSI — le prérequis manquant de `systemd-oomd`

`systemd-oomd` est décrit dans `docs/performance.md` comme la mesure « contre le gel total ». **Il ne fonctionne pas sans `CONFIG_PSI`** : le service démarre, ne lit aucune pression, et ne tue jamais rien. La machine gèle exactement comme avant, sans qu'aucun message n'indique pourquoi.

`PSI=y` **et** `PSI_DEFAULT_DISABLED=n` (sinon il faut `psi=1` sur la ligne de commande du noyau), plus `MEMCG=y` pour la pression par tranche cgroup — c'est-à-dire pour que `ManagedOOMMemoryPressure=kill` sur `user@.service` ait un signal à lire.

### 3.3 MGLRU

`LRU_GEN` + `LRU_GEN_ENABLED`. Le gain se voit précisément dans le cas qui exaspère l'utilisateur : la machine qui arrive à saturation mémoire et devient pâteuse au lieu de rester utilisable.

### 3.4 Ordonnancement

En 7.2, sur x86, le choix du modèle de préemption a changé : x86 sélectionne `ARCH_HAS_PREEMPT_LAZY`, ce qui rend **`PREEMPT_VOLUNTARY` indisponible** et fait de `PREEMPT_LAZY` le défaut. Le seul autre choix possible est `PREEMPT`, la préemption complète, décrite par le Kconfig comme *« Low-Latency Desktop »*.

On prend **`PREEMPT`** : latence minimale, là où l'utilisateur regarde. `PREEMPT_DYNAMIC` garde la porte ouverte — `preempt=lazy` au boot rend le débit, sans recompiler, pour une machine qui compile plus qu'elle ne joue.

* `HZ_1000`, `HIGH_RES_TIMERS`
* `SCHED_AUTOGROUP` — **activé**, à l'inverse du profil hyperviseur
* `SCHED_MC_PRIO` (Turbo Boost Max 3.0), `SCHED_CLUSTER` (chiplets Zen, cœurs E/P Intel)
* `UCLAMP_TASK` / `UCLAMP_TASK_GROUP` — évite que schedutil laisse un jeu tourner à basse fréquence parce que sa charge paraît modeste
* **`NO_HZ` : réglage Debian conservé.** Sans `nohz_full=` sur la ligne de commande, `NO_HZ_FULL` se comporte comme `NO_HZ_IDLE` (le suivi de contexte est derrière une *static key* inactive). Forcer `NO_HZ_IDLE` ne gagnerait rien et retirerait une possibilité.

### 3.5 Entrées/sorties

`IOSCHED_BFQ` + `BFQ_GROUP_IOSCHED` (l'ordonnanceur qui évite qu'une mise à jour APT fasse bégayer une vidéo), `MQ_IOSCHED_KYBER`, `BLK_WBT`, `BLK_CGROUP_IOCOST`, `IO_URING`. Le choix par périphérique reste une règle udev côté image.

### 3.6 Fréquence CPU

Aucun pilote ne couvre seul le parc : sans `acpi-cpufreq`, **tout AMD antérieur à Zen 2 reste bloqué à fréquence fixe**.

`X86_ACPI_CPUFREQ` + `X86_POWERNOW_K8` + `X86_INTEL_PSTATE` + `X86_AMD_PSTATE` (mode actif/EPP), gouverneur `schedutil` par défaut, `CPU_IDLE_GOV_TEO`, `INTEL_IDLE`.

**`X86_NATIVE_CPU=n`** — garde explicite. Cette option compile en `-march=native`, produisant un noyau accordé au CPU *de la machine de build* : il tombe en `#UD` sur toute machine plus ancienne. Un noyau de distribution ne peut pas être « natif ».

---

## 4. Rollback — ce que le noyau doit fournir

Le rollback d'AuxiNuxOS (`docs/rollback.md`) repose sur une racine BTRFS en sous-volumes plats, snapper, `grub-btrfs`, et un hook initramfs `auxinux-snapshot-overlay` qui superpose un tmpfs inscriptible sur un instantané **en lecture seule** pour pouvoir démarrer dessus.

Trois exigences en découlent. **Deux n'étaient pas satisfaites.**

| # | Exigence | Avant | Après |
|---|---|---|---|
| 1 | `BTRFS_FS` **built-in** | `=m` | `=y` + `CRITICAL_BUILTIN` |
| 2 | `TMPFS_XATTR` | non demandé | `=y` + `CRITICAL_BUILTIN` |
| 3 | Chaîne EFI (`EFIVAR_FS`) | non demandée | `=y` |

**Point 1.** La racine doit pouvoir être montée même quand l'initramfs est cassé ou périmé — c'est-à-dire **précisément dans la situation où l'on veut restaurer**. Un BTRFS en module fait dépendre le recours de l'objet qu'on soupçonne d'être en panne. Dans la même logique : `ZSTD_COMPRESS`/`ZSTD_DECOMPRESS` built-in (la racine est montée `compress=zstd:1`, sinon elle ne monte pas), `ATA`/`SATA_AHCI`/`BLK_DEV_NVME` built-in, `VFAT_FS` + ses tables `NLS` built-in pour `/boot/efi`.

**Point 2.** Le hook monte un overlay dont l'`upperdir` est un tmpfs. **OverlayFS refuse de se monter si le système de fichiers supérieur ne gère pas les attributs étendus.** Sans `TMPFS_XATTR`, le démarrage sur instantané échoue — autrement dit, le rollback ne marche que lorsqu'on n'en a pas besoin.

**Point 3.** `grub-btrfs` régénère des entrées de menu ; `efibootmgr` et GRUB ont besoin des variables EFI pour cela.

Accessoirement : `MAGIC_SYSRQ` (Alt+SysRq+REISUB) permet de redémarrer proprement une session graphique figée au lieu de couper l'alimentation — et une coupure brutale est exactement ce qu'on veut éviter quand on mise sur des instantanés.

---

## 5. GPU — Intel, AMD, NVIDIA

Tous les pilotes GPU sont en **modules**, jamais en built-in : ils réclament du firmware dans `/lib/firmware` à l'initialisation, qu'un pilote compilé en dur ne peut pas attendre. C'est aussi ce que fait Debian. `EXTRA_FIRMWARE` reste **vide** : le firmware vient des paquets `non-free-firmware`, l'embarquer figerait des versions.

**Intel** — `DRM_I915` (Gen2 → Meteor Lake) et `DRM_XE` (Lunar Lake, Battlemage et suivants). Les deux coexistent, chacun se lie aux PCI ID qu'il revendique.

**AMD** — `DRM_AMDGPU` + **`DRM_AMD_DC`**. Display Core n'est pas optionnel : sans lui, amdgpu se charge mais ne pilote **aucun écran** sur tout ce qui est postérieur à Vega — écran noir avec le bon pilote en mémoire. Plus `DRM_AMDGPU_SI` et `DRM_AMDGPU_CIK` : sans ces deux options, les cartes GCN 1 et 2 (HD 7000, R7/R9 200/300, APU Kaveri) retombent sur `radeon`, qui n'a pas de RADV utilisable. `DRM_RADEON` reste pour TeraScale.

**NVIDIA** — deux chemins, tous deux préservés :

1. `DRM_NOUVEAU` (+ `DRM_NOUVEAU_BACKLIGHT`), le pilote libre, par défaut à l'installation.
2. Le pilote **propriétaire**, hors arbre, compilé par DKMS chez l'utilisateur. Il ne dépend d'aucune option `DRM_NVIDIA` — il n'y en a pas — mais **exige les gardes DKMS** :
   * `TRIM_UNUSED_KSYMS=n` — cette option élague les symboles exportés non utilisés en interne et **casse la compilation de tout module hors-arbre** ;
   * `MODULE_SIG_FORCE=n` — un module DKMS n'est pas signé ;
   * `MODVERSIONS=y`, `MODULE_UNLOAD=y` ;
   * `DRM_FBDEV_EMULATION=y` pour `nvidia-drm.modeset=1`.

   **Un échec DKMS ne fait pas échouer `apt`.** Sans ces gardes, l'utilisateur obtient un paquet installé, aucun module, aucun message d'erreur — concrètement un poste NVIDIA qui redémarre en 800×600 sans que rien n'ait signalé de panne. Les mêmes gardes couvrent VirtualBox, `v4l2loopback` et OpenZFS.

**Console dès la première seconde** — `VT`, `FRAMEBUFFER_CONSOLE`, `SYSFB_SIMPLEFB`, `DRM` et `DRM_SIMPLEDRM` en **built-in**. Un poste qui démarre sans pilote d'affichage n'est pas « lent », il est **noir**, et c'est rapporté comme un plantage. `FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER` évite le clignotement au passage de main à Plymouth.

---

## 6. Jeu

| Option | Apport |
|---|---|
| **`NTSYNC`** | implémente en noyau les objets de synchronisation Windows (mutex, sémaphore, event). Remplace esync/fsync, qui les émulaient avec des eventfd et des futex : moins d'appels système, et surtout plus de plafond de descripteurs à relever à la main. **L'option « jeu » la plus rentable d'un noyau 7.2.** |
| `IA32_EMULATION` + `IA32_EMULATION_DEFAULT_DISABLED=n` | Steam, Wine, Proton. Depuis 6.7, `IA32_EMULATION` seul ne suffit plus : si le second symbole est actif, le support est compilé mais **inerte** tant qu'on ne passe pas `ia32_emulation=1` au boot. Un Steam qui refuse de démarrer sans message utile. |
| `JOYSTICK_XPAD` (+ `_FF`, `_LEDS`) | Xbox 360 / One / Series, retour de force |
| `HID_PLAYSTATION`, `HID_SONY` | DualSense, DualShock 3/4 |
| `HID_NINTENDO`, `HID_STEAM` | Switch Pro, manette Steam / Steam Deck |
| `INPUT_JOYDEV` | `/dev/input/jsX`, encore attendu par une partie du catalogue Proton |
| `HZ_1000` + `PREEMPT` + `UCLAMP_TASK` | régularité des images |
| `NET_SCH_CAKE` | anti-bufferbloat : latence en jeu en ligne |
| `TRANSPARENT_HUGEPAGE_MADVISE` | en `always`, la compaction provoque des à-coups de plusieurs dizaines de millisecondes. Les moteurs qui veulent des hugepages les demandent explicitement. |

---

## 7. Multimédia

`SND_HDA_INTEL` et la série de codecs (Realtek, HDMI, Analog, Sigmatel, VIA, Conexant, Cirrus, CS8409), `SND_USB_AUDIO`, `SND_SEQUENCER`.

**SOF** (`SND_SOC_SOF_INTEL_TOPLEVEL`, `SND_SOC_SOF_HDA_AUDIO_CODEC`, `SND_SOC_SOF_AMD_TOPLEVEL`, `SOUNDWIRE_INTEL`) : toute la génération Intel post-2019 (Tiger Lake et suivants) et les APU AMD récents n'ont plus de codec HDA classique. **Sans SOF, ces portables n'ont aucune sortie audio.**

`SND_HDA_SCODEC_CS35L41_I2C` et `CS35L56_I2C` : amplificateurs de haut-parleurs des portables Dell/Lenovo/HP récents. Sans eux le son sort, mais à un volume inaudible.

Webcam : `MEDIA_SUPPORT`, `USB_VIDEO_CLASS` (UVC), `USB_GSPCA`. Le décodage vidéo matériel (VA-API) passe par i915/amdgpu/nouveau — il est déjà couvert par le §5, il n'y a pas d'option dédiée.

---

## 8. Virtualisation conservée : LXC, Docker, KVM

**Conteneurs** — pile cgroups v2 et espaces de noms complète : `CGROUP_BPF`, `CGROUP_MISC`, `CGROUP_HUGETLB`, `CFS_BANDWIDTH`, `BLK_DEV_THROTTLING`, `CPUSETS`, `NAMESPACES`, `USER_NS`, `SECCOMP`, `CHECKPOINT_RESTORE`, `OVERLAY_FS`.

`USER_NS` est aussi le prérequis de **bubblewrap**, donc de tout Flatpak non privilégié. Le couper pour « durcir » casserait le mode de distribution d'applications par défaut d'AuxiNuxOS.

**Réseau** — `VETH`, `BRIDGE` + `BRIDGE_NETFILTER` + `BRIDGE_VLAN_FILTERING`, `NF_TABLES`, `NF_NAT`, `IP_NF_TARGET_MASQUERADE`, `WIREGUARD`, `NET_CLS_BPF`. Avec **`NETFILTER_XTABLES_LEGACY`** : depuis 7.x, les cibles `IP_NF_*` historiques — encore émises par `docker` et `lxc-net` — en dépendent explicitement.

**LSM** — `SECURITY_APPARMOR=y` **ne suffit pas** : si `apparmor` n'est pas dans `CONFIG_LSM`, les profils AppArmor de Docker et LXC ne s'appliquent **jamais**, en silence, sans aucune erreur visible. On reprend la chaîne exacte de Debian 13 :

```
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor,bpf"
```

**BTF** — `DEBUG_INFO_BTF` + `DEBUG_INFO_BTF_MODULES`, activés d'office sur ce profil : c'est le défaut Debian 13, et l'outillage eBPF CO-RE d'observation des conteneurs en dépend. Contrainte Kconfig à connaître : `DEBUG_INFO_BTF` est **incompatible** avec `DEBUG_INFO_REDUCED` et `DEBUG_INFO_SPLIT`, il faut du DWARF complet. Le surcoût est du temps de build et un gros `vmlinux` intermédiaire, **pas un gros vmlinuz** : seul le BTF dédupliqué (~4-6 Mo) part dans l'image. Le paquet `-dbg` produit au passage n'est jamais publié — `[8/9]` l'exclut désormais explicitement.

**KVM** — `KVM_INTEL`/`KVM_AMD` en modules pour GNOME Boxes et virt-manager, `VHOST_NET`, `VHOST_VSOCK`. IOMMU présent pour le passthrough occasionnel (eGPU, VM GPU) ; `INTEL_IOMMU_DEFAULT_ON` reste volontairement à l'écart — l'activer par défaut casse le démarrage de certaines cartes anciennes ; opt-in documenté `intel_iommu=on iommu=pt`.

**AuxiNuxOS en invité** — `VIRTIO_PCI`/`BLK`/`NET` sont **built-in** : l'ISO s'installe et se valide aussi en machine virtuelle, et là non plus le démarrage ne doit pas dépendre d'un initramfs correct.

---

## 9. Portable

À l'inverse du profil hyperviseur, qui coupe `SUSPEND` et `HIBERNATION` pour éliminer une classe entière de bugs ACPI, un poste de travail **doit** pouvoir se mettre en veille : rabattre l'écran est le geste le plus courant qui soit.

`ACPI_AC`/`BATTERY`/`BUTTON`/`FAN`/`THERMAL`/`DOCK`, `BACKLIGHT_CLASS_DEVICE`, `ACPI_VIDEO`, `PCIEASPM_DEFAULT`, et les pilotes constructeur (`THINKPAD_ACPI`, `ASUS_WMI`, `DELL_LAPTOP`, `HP_WMI`, `ACER_WMI`, `MSI_WMI`, `LENOVO_YMC`, `INTEL_HID_EVENT`, `INTEL_VBTN`, `AMD_PMF`, `AMD_PMC`) — ce sont eux qui font fonctionner les touches de luminosité, de volume et de mode avion.

Thermique et capteurs : `X86_PKG_TEMP_THERMAL`, `INT340X_THERMAL`, `SENSORS_CORETEMP`, `SENSORS_K10TEMP`, `SENSORS_DELL_SMM`.

Wi-Fi : correction des trois symboles morts du §0, plus `IWLMLD` (Wi-Fi 7 Intel BE200/BE201), `IWLDVM` (Intel 5000/6000, 2009-2012), `MT7921E`/`MT7925E`, `ATH12K`.

---

## 10. Exécution

| # | Étape | Livrable | État |
|---|---|---|---|
| 1 | Garde-fou `cfg()` + `[6a]` + `-config-only` + `CRITICAL_BUILTIN` | `build-kernel-core.sh` | **fait** |
| 2 | Profil `auxinuxos` réécrit en branche autonome (~450 options) | `build-kernel-core.sh` | **fait** |
| 3 | Wrapper épinglé sur la série 7.2 + détection EOL | `build-AuxiNuxOS-kernel.sh` | **fait** |
| 4 | Vérification des 516 demandes (499 symboles distincts) contre l'arbre `linux-7.2.5` | index Kconfig | **fait** |
| 5 | **Build à blanc sur le serveur DEV** | `.config` + rapport `[6a]` | **fait** — 4 défauts trouvés, cf. §10.1 |
| 6 | Revue du `.config` généré | validation | **fait** — cf. §10.2 |
| 7 | Build complet | `.deb` dans `OUTPUT_DIR` | **fait** — 2 h 40, cf. §10.3 |
| 8 | Publication dépôt + purge 7.1.x | suite APT `kernel` | **fait** — cf. §10.4 |
| 9 | Tests sur matériel réel (§11) | rapport | **à faire — le noyau n'a jamais démarré** |
| 10 | Notes de version | — | à faire |

### 10.3 Build et taille du paquet

Le paquet image est passé de **89 Mo** (7.1.12) à **165 Mo**. Trois causes,
mesurées et non supposées :

| Cause | Effet |
|---|---|
| **BTF dans les modules** (`DEBUG_INFO_BTF_MODULES`) — le 7.1.12 était en `DEBUG_INFO_NONE`, sans aucun BTF | **47 %** des octets de modules |
| Pilotes ajoutés (xe, amdgpu SI/CIK, SOF…) + passage 6.12 → 7.2 | +16 % par module |
| Compression des modules | cf. ci-dessous |

**Compression : zstd → xz.** Le noyau compresse les modules avec `zstd` sans
niveau, donc au **niveau 3** par défaut (`scripts/Makefile.modinst`). Mesuré sur
300 modules du build : 13,2 Mo en zstd contre 9,4 Mo en xz, soit **29 % de
plus**. Debian 13 livre ses modules en xz (`linux-image-6.12.101+deb13`, arbre
de 104 Mo, `DEBUG_INFO_BTF_MODULES=y` lui aussi). Le profil a donc été aligné
sur Debian : le paquet est passé de 214 Mo à **165 Mo**.

`MODULE_COMPRESS_*` est un **`choice`**, comme `PREEMPT` : activer XZ ne
désélectionne pas ZSTD. Sans désélection explicite, le changement aurait été un
no-op silencieux — exactement le piège du §10.1.

Le repackage n'a recompilé **qu'un seul objet** (`kernel/module/decompress.o`,
qui passe de `ZSTD_DECOMPRESS` à `XZ_DEC`), mais le relink de `vmlinux` a obligé
à régénérer le BTF des 4042 modules (BTF « split », relatif à `vmlinux`).

Contrôles sur le paquet final : `vmlinuz` 16,7 Mo avec BTF, 4042 modules tous
en `.ko.xz`, modules **strippés du DWARF** mais porteurs de `.BTF`,
`linux-image-*-dbg` (1,8 Go) et `linux-libc-dev` exclus de la publication.

### 10.4 Publication — 12 septembre 2026

```
KERNEL/      kernel-auxinuxos 7.2.5-auxinuxos-amd64.1  (+ image, headers)
KERNEL-DEV/  vide
```

Purge effectuée : 7.1.3 et 7.1.12 retirés de `KERNEL/` (y compris leurs paquets
`-dbg` de 1,7 Go), 7.2.2-dev retiré de `KERNEL-DEV/`. La rétention automatique
ne l'aurait **pas** fait : `KEEP_VERSIONS=2` groupe par *(préfixe, suffixe)* de
nom de paquet et aurait gardé 7.1.12 à côté de 7.2.5.

Sauvegarde préalable : `~/kernel-purge-backup-auxinuxos-20260912-004720`
(5,2 Go, `KERNEL/` + `KERNEL-DEV/` + `dists/`) sur l'hôte du dépôt.

Vérifications après publication :

| Contrôle | Résultat |
|---|---|
| Index APT `kernel` | 3 paquets, tous en 7.2.5, `Depends` du meta correct |
| Index APT `kernel-dev` | 0 paquet |
| HTTP des 3 paquets | 200 |
| HTTP des anciens 7.1.x et 7.2.2-dev | 404 |
| sha256 servi vs construit | **identique** (image et headers) |
| Signature `InRelease` des deux suites | `Good signature from "AuxiNux Repository <repo@auxinux.ca>"` |

### 10.1 Ce que le build à blanc a attrapé

Quatre défauts qu'une vérification de symboles seule ne pouvait pas voir, parce
qu'ils dépendent de la résolution des dépendances à partir de la config Debian :

| Constat `[6a]` | Cause | Correctif |
|---|---|---|
| `PREEMPT: demandé=y obtenu=n` | `PREEMPT` appartient à un **`choice`**. Écrire `CONFIG_PREEMPT=y` ne suffit pas : `olddefconfig` garde le membre déjà sélectionné par la base Debian (`PREEMPT_LAZY`) et annule la demande **en silence**. | désélectionner `PREEMPT_NONE`/`PREEMPT_VOLUNTARY`/`PREEMPT_LAZY` d'abord |
| `IP_NF_FILTER/NAT/TARGET_MASQUERADE: demandé=y obtenu=m` | en 7.x ils dépendent de `IP_NF_IPTABLES_LEGACY`, tristate livré en module par Debian : ils **ne peuvent pas** être built-in | passer en `--module` (sans conséquence : `docker` et `lxc-net` les chargent à la demande) |
| `FW_LOADER_USER_HELPER: demandé=n obtenu=y` | sélectionné par plusieurs pilotes, impossible à forcer à `n` | viser `FW_LOADER_USER_HELPER_FALLBACK` — c'est lui qui fait attendre 60 s à chaque firmware absent |
| Build interrompu sur `CONFIG_DEBUG_INFO=y` | le garde de `[6/9]` datait d'avant l'activation du BTF, qui **impose** du DWARF complet | le garde tient compte du profil |

Le premier est le plus instructif : sans le build à blanc, tout le travail sur
la latence (§3.4) tombait à l'eau **sans un seul message**, et le noyau aurait
été publié en `PREEMPT_LAZY` alors que la note de version aurait annoncé une
préemption complète.

Reste **un** avertissement, bénin et documenté : `SYSTEM_REVOCATION_KEYS`
n'est pas émis tant que `SYSTEM_REVOCATION_LIST` est à `n` — c'est le résultat
voulu (aucune clé de révocation).

### 10.2 `.config` retenu — contrôles

```
CONFIG_PREEMPT=y            CONFIG_HZ=1000           CONFIG_SCHED_AUTOGROUP=y
CONFIG_BTRFS_FS=y           CONFIG_TMPFS_XATTR=y     CONFIG_ZSTD_COMPRESS=y
CONFIG_PSI=y                (PSI_DEFAULT_DISABLED absent)
CONFIG_MEMCG=y              CONFIG_ZRAM=m            CONFIG_ZRAM_DEF_COMP_ZSTD=y
CONFIG_LRU_GEN_ENABLED=y    CONFIG_NTSYNC=m          CONFIG_IA32_EMULATION=y
CONFIG_DRM=y                CONFIG_DRM_SIMPLEDRM=y   CONFIG_SYSFB_SIMPLEFB=y
CONFIG_DRM_AMD_DC=y         CONFIG_DRM_AMDGPU=m      CONFIG_DRM_I915=m
CONFIG_VFAT_FS=y            CONFIG_SATA_AHCI=y       CONFIG_BLK_DEV_NVME=y
CONFIG_EFIVAR_FS=y          CONFIG_MODVERSIONS=y     (TRIM_UNUSED_KSYMS absent)
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor,bpf"
```

`477 options demandées`, 21 721 symboles Kconfig indexés, toutes les options
`CRITICAL` présentes et toutes les `CRITICAL_BUILTIN` réellement en `=y`.

```bash
# 5. build à blanc — À FAIRE EN PREMIER sur le serveur de build
./build-AuxiNuxOS-kernel.sh -config-only

# 7. build complet
./build-AuxiNuxOS-kernel.sh

# 9. publication
sudo GPG_KEY=repo@auxinux.ca ./build-depot-AuxiNuxOS.sh ./output
```

### Pourquoi l'étape 5 reste indispensable

Les 516 demandes ont été confrontées à l'arbre 7.2.5 réel : **aucun symbole n'est inexistant**, et la cohérence type/action a été contrôlée (pas de `--module` sur un `bool`, pas de `--disable` sur un entier). Ce qui **n'a pas** pu être vérifié ici, faute de chaîne de compilation complète (`flex`, `bison`, `bc`), c'est la résolution des **dépendances** par `olddefconfig` à partir de la config Debian de base. C'est exactement ce que rapporte l'étape `[6a]` sous le verdict *IGNORÉ*, et c'est ce que le build à blanc doit produire avant la première compilation longue.

---

## 11. Validation avant publication

La demande porte sur un poste de travail : la validation doit être celle d'un poste.

* **Affichage** : un démarrage sur chacun des trois constructeurs — Intel, AMD (dont une GCN 1/2 pour valider `DRM_AMDGPU_SI`/`CIK`), NVIDIA (nouveau **et** pilote propriétaire via DKMS, avec `dkms status` et `nvidia-smi` vérifiés).
* **Rollback** : `auxi snapshot`, `auxi rollback N`, redémarrage — **et** le cas qui compte, démarrage depuis le menu « instantanés (restauration) » sur une machine dont la racine ne monte plus. C'est le test qui valide `TMPFS_XATTR` et `BTRFS_FS=y`.
* **Fluidité** : `cat /sys/kernel/mm/lru_gen/enabled`, `zramctl`, `systemd-analyze` ; `oomctl` doit afficher une pression non nulle (preuve que PSI remonte) ; `make -j$(nproc)` pendant une lecture vidéo.
* **Audio** : un portable post-2019 à SOF, un poste fixe HDA, un casque USB.
* **Jeu** : un titre Proton avec `PROTON_USE_NTSYNC=1`, une manette Xbox et une DualSense, en USB et en Bluetooth.
* **Conteneurs** : `docker run` avec profil AppArmor **vérifié appliqué** (`aa-status`), `lxc-start`, `podman` en rootless (valide `USER_NS`).
* **Flatpak** : installation et lancement d'une application (valide `USER_NS` + `FUSE_FS`).
* **Portable** : veille/reprise, hibernation, touches de luminosité et de volume, batterie.
* **Rollback de dernier recours** : l'ancien noyau reste installé et sélectionnable dans GRUB pendant toute la campagne.

---

## 12. Hors périmètre

* **Aucun rétro-portage vers 7.1** : la série est EOL depuis le 2 septembre 2026.
* **7.3** reste hors sujet tant que la 7.2 n'est pas validée en production.
* Les profils `virtua` et `desktop` de ce moteur ne sont **pas** l'objet de ce plan. Ils bénéficient du garde-fou et de la correction de `CGROUP_NS`, rien de plus.
* OpenZFS reste non publié pour AuxiNuxOS (`no-zfs` imposé par le wrapper). Les gardes DKMS restent en place — elles servent NVIDIA.
