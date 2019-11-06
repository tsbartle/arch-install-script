#!/usr/bin/env bash

set -o errexit          # Exit on most errors (see the manual)
set -o errtrace         # Make sure any error trap is inherited
set -o nounset          # Disallow expansion of unset variables
set -o pipefail         # Use last non-zero exit code in a pipeline
#set -o xtrace          # Trace the execution of the script (debug)

# DESC: Usage help
# ARGS: None
# OUTS: None
function script_usage() {
    cat << EOF
Usage:
     -p|--pause                 Pauses after each section
     -n|--hostname              Hostname to use (default: hal-arch)
     -v|--device                Device for installation (default: /dev/sda)
     -u|--user                  Primary User
EOF
}


function var_init() {
    readonly mirrorlist_url="https://www.archlinux.org/mirrorlist/?country=US&protocol=http&protocol=https&ip_version=4&use_mirror_status=on"

    hostname="hal-arch"
    do_efi=true
    do_pause=false
    do_encrypt=true
    device="/dev/sda"
    prefix=""
    user="tsb"
}


# DESC: Parameter parser
# ARGS: $@ (optional): Arguments provided to the script
# OUTS: Variables indicating command-line parameters and options
function parse_params() {
    local param
    while [[ $# -gt 0 ]]; do
        param="$1"
        case $param in
            -h|--help)
                shift
                script_usage
                exit 0
                ;;
            -p|--pause)
                shift
                do_pause=true
                ;;
            -nc|--no-color)
                shift
                no_color=true
                ;;
            -n|--hostname)
                shift
                hostname=$1
                shift
                ;;
            -y|--encrypt)
                shift
                do_encrypt=true
                ;;
            -s|--swap)
                shift
                swap=$1
                shift
                ;;
            -e|--efi)
                shift
                do_efi=true
                ;;
            -v|--device)
                shift
                device=$1
                shift
                ;;
            -f|--prefix)
                shift
                prefix=$1
                shift
                ;;
            -u|--user)
                shift
                user=$1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                script_exit "Invalid parameter was provided: $param" 2
                ;;
            *)
                break;
        esac
    done
}


function init_locales() {
    ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
    hwclock --systohc
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
}


function init_host() {
    echo $hostname > /etc/hostname
    echo "
127.0.0.1       localhost
::1             localhost
127.0.1.1       $hostname.localdomain $hostname.local $hostname
" > /etc/hosts
}


function install_bootloader() {

    if [ "$do_encrypt" = true ]; then

        # Create an encryption key, set 000 permissons
        dd bs=512 count=4 if=/dev/random of=/root/archlvm.keyfile iflag=fullblock
        chmod 000 /root/archlvm.keyfile

        cryptsetup -v luksAddKey ${device}${prefix}4 /root/archlvm.keyfile

        cp /etc/mkinitcpio.conf{,.orig}
        cat /etc/mkinitcpio.conf.orig | sed 's/FILES=()/FILES=\(\/root\/archlvm.keyfile\)/' > /etc/mkinitcpio.conf
        cp /etc/mkinitcpio.conf{,.part1}
        cat /etc/mkinitcpio.conf.part1 | sed 's/HOOKS=.*/HOOKS=\(base udev autodetect block encrypt lvm2 resume filesystems keyboard fsck shutdown\)/' > /etc/mkinitcpio.conf
        cp /etc/mkinitcpio.conf{,.part2}
        cat /etc/mkinitcpio.conf.part2 | sed 's/MODULES=.*/MODULES=\(vfat ext4 dm_mod dm_crypt aes_x86_64 i915\)/' > /etc/mkinitcpio.conf
        mkinitcpio -p linux

    fi

    if [ "$do_efi" = true ]; then
        bootctl --path=/boot install
        touch /boot/loader/loader.conf
        touch /boot/loader/entries/arch.conf

# Write in loader config
cat >> /boot/loader/loader.conf <<LOADER
default arch
timeout 5
LOADER

# Write in arch config
cat >> /boot/loader/entries/arch.conf <<ARCH
default arch
efi \vmlinuz-linux
options initrd=\initramfs-linux.img cryptdevice=/dev/sda4:archvg root=/dev/mapper/archvg-rootlv ro
ARCH

    else
        echo "nonUEFI is not supported yet..."
    fi
}

# Set root password to seconds since 1970
function init_root() {
    passwd=`date +%s | sha256sum | base64 | head -c 32`
    echo "root:$passwd" | chpasswd
}

# Set user account and password to seconds since 1970
function init_user() {
    while true; do
        echo 'Enter a password for "'$user'":'
        read -s -p "Password: " passwd
        echo
        read -s -p "Password (verify): " passwd2
        echo
        [ "$passwd" = "$passwd2" ] && break || echo "Passwords do not match! Please try again."
    done

    groupadd $user
    useradd -m -g users -G wheel $user

    echo "$user:$passwd" | chpasswd

    # Copy authorized_keys to user's homedir
    mkdir -p /home/$user/.ssh
    chmod 700 /home/$user/.ssh
    cp /root/.ssh/authorized_keys /home/$user/.ssh/authorized_keys
    chmod 600 /home/$user/.ssh/authorized_keys
    chown $user:$user -R /home/$user/.ssh

}

# Edit sudoers files
function edit_sudoers() {

        # Add $user to sudoers files
        cp /etc/sudoers{,.orig}
        cat /etc/sudoers.orig | sed '/root ALL=(ALL) ALL/a '"$user"' ALL=(ALL) ALL' > /etc/sudoers

        # Allow members of wheel to execute any command
        cp /etc/sudoers{,.part1}
        cat /etc/sudoers.part1 | sed '/%wheel ALL=(ALL) ALL/s/^# //g' > /etc/sudoers

        # Remove temp copies
        rm -rf /etc/sudoers.orig /etc/sudoers.part1

}


# Disable ssh root login, disable password logins
function edit_sshd() {

        # Disable root login via ssh
        cp /etc/ssh/sshd_config{,.orig}
        cat /etc/ssh/sshd_config.orig | sed '/# Authentication:/a PermitRootLogin no' > /etc/ssh/sshd_config

        # Allow members of wheel to execute any command
        cp /etc/ssh/sshd_config{,.part1}
        cat /etc/ssh/sshd_config.part1 | sed '/#PasswordAuthentication yes/a PasswordAuthentication no' > /etc/ssh/sshd_config

        # Remove temp copies
        rm -rf /etc/ssh/sshd_config.orig /etc/ssh/sshd_config.part1

    }

# Config makepkg.conf
function makepkg_set() {
        
        # Get CPU count, set compression type

        # Enter CPU count into makepkg.conf
        cp /etc/makepkg.conf{,.orig}
        cat /etc/makepkg.conf.orig | sed 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T '$(nproc)' -z -)/' > /etc/makepkg.conf

        # Uncomment MAKEFLAGS, set jflag
        cp /etc/makepkg.conf{,.part1}
        cat /etc/makepkg.conf.part1 | sed 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j'$(($(nproc) + 1))'"/' > /etc/makepkg.conf

        # Set compression to lzo for speed
        cp /etc/makepkg.conf{,.part2}
        cat /etc/makepkg.conf.part2 | sed 's/PKGEXT='.pkg.tar.xz'/PKGEXT='.pkg.tar.lzo'/' > /etc/makepkg.conf
        
        # Remove temp copies
        rm -rf /etc/makepkg.conf.orig /etc/makepkg.conf.part1 /etc/makepkg.conf.part2

    }



function clean_pacman() {
#    pacman -Rs gcc groff man-db git make guile binutils man-pages nano --noconfirm
#    echo "y\ny" | pacman -Scc
    # Enable pacman in pacman
    echo "ILoveCandy" >> /etc/pacman.cfg
}

function create_swapfile() {

    if (( $swap > 0 )); then

        truncate -s 0 /swapfile

        fallocate -l "$swap"M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap defaults 0 0" >> /etc/fstab

    fi

}


# DESC: Main control flow
# ARGS: $@ (optional): Arguments provided to the script
# OUTS: None
function main() {
    source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

    trap script_trap_err ERR
    trap script_trap_exit EXIT

    script_init "$@"
    var_init "$@"
    parse_params "$@"
    cron_init
    color_init

    run_section "Initalizing locales" "init_locales"
    run_section "Setting Hostname" "init_host"
    run_section "Installing Bootloader" "install_bootloader"
    run_section "Initaling root User" "init_root"
    run_section "Initaling primary User" "init_user"
    run_section "Add primary user to sudoers" "edit_sudoers"
    run_section "Creating Swapfile" "create_swapfile"
    run_section "Installing Core Packages" "pacman -Syu vim git python --noconfirm"
    run_section "Configure makepkg.conf" "makepkg_set"
    run_section "Enabling Core Services" "systemctl enable sshd dhcpcd"
    run_section "Edit sshd_config - no root login; disable password logins" "edit_sshd"
    run_section "Cleaning Up Pacman" "clean_pacman"
}


# Make it rain
main "$@"

# vim: syntax=sh cc=80 tw=79 ts=4 sw=4 sts=4 et sr
