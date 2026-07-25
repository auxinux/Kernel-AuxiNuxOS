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
