function var_init() {

    # Arch mirror list for USA
    readonly mirrorlist_url="https://archlinux.org/mirrorlist/?country=US"

    # Defaults
    hostname="hal-arch"
    do_efi=true
    do_pause=false
    swap=6000
    no_input=false
    do_cleanup=false
    dry_run=false
    device="/dev/nvme0n1"
    prefix="" # "p" for/dev/nvme0n1p1 as an example
    do_wipe=false
    do_encrypt=true
    user="tsb"
}


# Parameter parser
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
            -c|--clean)
                shift
                do_cleanup=true
                ;;
            -e|--efi)
                shift
                do_efi=true
                ;;
            -w|--wipe)
                shift
                do_wipe=true
                ;;
            -s|--swap)
                shift
                swap=$1
                shift
                ;;
            -ni|--no-input)
                shift
                no_input=true
                ;;
            -f|--prefix)
                shift
                prefix=$1
                shift
                ;;
            -v|--device)
                shift
                device=$1
                shift
                ;;
            -u|--user)
                shift
                user=$1
                shift
                ;;
            -d|--dry-run)
                shift
                dry_run=true
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


function get_params() {
    if [ `contains "$*" -v` -eq 0 ]; then
        prompt_param "$device" "Disk to Install to?"
        device="$prompt_result"
    fi


    if [ `contains "$*" -n` -eq 0 ]; then
        prompt_param "$hostname" "Hostname"
        hostname="$prompt_result"
    fi


    if [ `contains "$*" -u` -eq 0 ]; then
        prompt_param "$user" "Username"
        user=$prompt_result
    fi


    if [ `contains "$*" -s` -eq 0 ]; then
        prompt_param "$swap" "Swapfile size (MB)"
        swap=$prompt_result
    fi

}


function print_vars() {
    pretty_print "Hostname" $fg_magenta 1
    pretty_print ": $hostname" $fg_white

    pretty_print "Install Disk" $fg_magenta 1
    pretty_print ": $device" $fg_white

    pretty_print "Encrypt Disk" $fg_magenta 1
    pretty_print ": $do_encrypt" $fg_white

    pretty_print "Using EFI" $fg_magenta 1
    pretty_print ": $do_efi" $fg_white

    pretty_print "User Name" $fg_magenta 1
    pretty_print ": $user" $fg_white

    pretty_print "Swapfile Size (MB)" $fg_magenta 1
    pretty_print ": $swap" $fg_white

}


# Cleans any existing partitions for disk
 clean_disk() {
    swapoff -a
    wipefs -af $device
    dd if=/dev/zero of=$device bs=512 count=1 conv=notrunc
}


# Securely wipes a disk
function wipe_disk() {
    cryptsetup open --type plain -d /dev/urandom $device to_be_wiped
    dd if=/dev/zero of=/dev/mapper/to_be_wiped status=progress || true
    cryptsetup close to_be_wiped
}


function setup_encrypt() {
    encrypt_partition=$os_partition
    os_partition=/dev/mapper/archvg-rootlv

    cryptsetup luksFormat --type luks1 $encrypt_partition
    cryptsetup open $encrypt_partition archlvm

    pvcreate /dev/mapper/archlvm
    vgcreate archvg /dev/mapper/archlvm

    lvcreate -l 100%FREE archvg -n rootlv
}


# Partitions, formats and mounts disk
function partition_disk() {
    os_partition="${device}${prefix}4"
    sgdisk -Z $device
    sgdisk -og $device

    sgdisk -n 1:2048:4095 -c 1:"BIOS Boot Partition" -t 1:ef02 $device
    sgdisk -n 2:4096:1052762 -c 2:"EFI System Partition" -t 2:ef00 $device
    sgdisk -n 3:1054720:2101339 -c 3:"Linux /boot" -t 3:8300 $device

    ENDSECTOR=`sgdisk -E $device`
    sgdisk -n 4:2103296:$ENDSECTOR -c 4:"Arch LVM" -t 4:8e00 $device
    sgdisk -p $device

    if [ "$do_encrypt" = true ]; then
        setup_encrypt
    fi

    ## Create filesystems for logical volumes and boot ##
    # boot
    mkfs.vfat -F32 ${device}${prefix}2
    mkfs.ext4 /dev/mapper/archvg-rootlv

    # Mount the partitions to /mnt for installation
    mount /dev/mapper/archvg-rootlv /mnt
    mkdir -p /mnt/boot
    mount -t vfat ${device}${prefix}2 /mnt/boot
}

function update_mirrors() {
    curl -s "$mirrorlist_url" |  sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist
}


# Initalizes /mnt so it can be chroot
function bootstrap_arch() {
    pacstrap /mnt base base-devel linux linux-firmware sudo efibootmgr wpa_supplicant dialog intel-ucode lzop lvm2 openssh dhcpcd archlinux-keyring
    genfstab -U -p /mnt > /mnt/etc/fstab

    # Copy chroot.sh to chrooted environment
    cp $script_dir /mnt/root/arch-install-script -R
    chmod +x /mnt/root/arch-install-script/script/chroot.sh

    # Copy authorized_keys to root profile
    mkdir /mnt/root/.ssh -p
    chmod 700 /mnt/root/.ssh
    cp authorized_keys /mnt/root/.ssh/authorized_keys
    chmod 600 /mnt/root/.ssh/authorized_keys
}


# Chroot
function do_chroot() {
    extra_args=""

    if [[ -z ${no_color-} ]]; then
        extra_args="$extra_args -nc"
    fi
    if [ "$do_pause" = true ]; then
        extra_args="$extra_args -p"
    fi
    if [ "$do_encrypt" = true ]; then
        extra_args="$extra_args -y"
    fi
    if [ "$do_cleanup" = true ]; then
        extra_args="$extra_args -c"
    fi
    if [ "$do_efi" = true ]; then
        extra_args="$extra_args -e"
    fi

    # Chroot in, pass arguments to the chroot.sh script
    arch-chroot /mnt /root/arch-install-script/script/chroot.sh $extra_args -v $device -f "$prefix" -n $hostname -u $user -s $swap

    # Remove the installer script directory
    rm /mnt/root/arch-install-script -rf
}


# Removes cleans up disk to help compact (defrag/write 0)
function clean_up() {
    e4defrag $os_partition
    dd if=/dev/zero of=/mnt/zero.small.file bs=1024 count=102400
    cat /dev/zero > /mnt/zero.file || true
    sync
    rm /mnt/zero.small.file
    rm /mnt/zero.file
    if [ "$do_swap" = true ]; then
        swapoff ${device}${prefix}2
    fi
}


function eject_install() {
    umount -d -l -f /run/archiso/bootmnt/ && eject /dev/cdrom
}
