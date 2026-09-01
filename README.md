# AuxiNuxOS Kernel

Dedicated kernel entry points for AuxiNuxOS workstation editions.

The builder wrapper targets the `auxinuxos` profile and publishes to the
AuxiNuxOS kernel repository. Its build and repository engines are included
locally, so this repository can be cloned and used without Kernel/VirtuaOS.

Build and repository entry points:

```bash
./build-AuxiNuxOS-kernel.sh
sudo GPG_KEY=repo@auxinux.ca ./build-depot-AuxiNuxOS.sh ./output
```

## Canaux prod / dev

Deux canaux de publication coexistent, physiquement séparés côté dépôt :

| Canal | Release noyau | Meta-paquet | Suite APT | Dossier |
|---|---|---|---|---|
| `prod` (défaut) | `7.1.12-auxinux-virtua-amd64` | `kernel-virtua` | `kernel` | `KERNEL/` |
| `dev` | `7.2.2-dev-auxinux-virtua-amd64` | `kernel-virtua-dev` | `kernel-dev` | `KERNEL-DEV/` |

```bash
./build-kernel-core.sh KERNEL_VERSION=7.1.12            # prod
./build-kernel-core.sh track=dev KERNEL_VERSION=7.2.2   # dev
sudo RELEASE_TRACK=dev GPG_KEY=repo@auxinux.ca ./build-depot-kernel-core.sh /tmp/dev
```

Les noms de paquets diffèrent, donc les deux noyaux **coexistent installés** : on
choisit celui à tester au démarrage via GRUB, et le retour arrière est immédiat.

Le marqueur `dev` est en **minuscules** par obligation : la politique Debian
interdit les majuscules dans un nom de paquet et `dpkg` les convertit
silencieusement, ce qui désynchroniserait le nom du paquet du répertoire
`/lib/modules/$(uname -r)`.

Rétention par défaut : `KEEP_VERSIONS=2` par série et par architecture.

## OpenZFS

When enabled (`WITH_ZFS`), this project ships OpenZFS as a DKMS **source**
package (`openzfs-zfs-dkms`) — never a precompiled kernel module. Linux is
GPL-2.0-only and OpenZFS is CDDL; distributing a binary that combines the two
is a legal gray area (Ubuntu accepts this risk and ships a precompiled
module, Debian does not and ships DKMS source only). This project follows
the Debian approach: the module is compiled by DKMS on the end user's own
machine at install time, against their installed `linux-headers-*` package,
never on this build/repository server.

Le meta-paquet noyau ne tire **pas** automatiquement `openzfs-zfs-dkms`
(`ZFS_META_DEP=none` par défaut) : APT installant les `Recommends` par défaut,
l'ancien réglage déclenchait la compilation CDDL+GPL chez l'utilisateur sans
qu'il l'ait demandée. Comme sous Debian, l'installation est explicite :

```bash
sudo apt install openzfs-zfs-dkms
```

## License

GPL-2.0-only, see [LICENSE](LICENSE).
