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

## OpenZFS

When enabled (`WITH_ZFS`), this project ships OpenZFS as a DKMS **source**
package (`openzfs-zfs-dkms`) — never a precompiled kernel module. Linux is
GPL-2.0-only and OpenZFS is CDDL; distributing a binary that combines the two
is a legal gray area (Ubuntu accepts this risk and ships a precompiled
module, Debian does not and ships DKMS source only). This project follows
the Debian approach: the module is compiled by DKMS on the end user's own
machine at install time, against their installed `linux-headers-*` package,
never on this build/repository server.

## License

GPL-2.0-only, see [LICENSE](LICENSE).
