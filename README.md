# Arch Install Script
Scripts to automate an Arch installation, customized with my default preferences and packages.

* UEFI
* LUKS Encryption
* LVM partitioning
* User account creation
* ssh - remove root login, disallow pw login
* Randomize root password
* Prompt for user password
* Add public key to "authorized_keys" of User account

_Tested with ArchISO 2021.2.01_

## Usage

Boot to ArchISO, then:

```bash
curl -sL https://iambartlett.com/arch > i
source i
```
### nvme install
```
./install.sh -f p
```

### sda install
```
./install.sh
```

