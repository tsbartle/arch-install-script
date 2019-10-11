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

## Usage

Boot to ArchISO, then:

```bash
curl -sL https://iambartlett.com/arch > i
source i
./install.sh
```

## Post Install Script

**Coming Soon**
