#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
DEFAULT_SEED_IMAGE="$REPO_DIR/dist/sdcard-dev.img"

BOOT_START=2048
BOOT_SECTORS=16384
ROOT_START=$((BOOT_START + BOOT_SECTORS))
ROOT_BYTES=$((16 * 1024 * 1024 * 1024))

usage()
{
	echo "Usage: sudo $0 BLOCK_DEVICE [SEED_IMAGE]" >&2
	echo "Example: sudo $0 /dev/sdX $DEFAULT_SEED_IMAGE" >&2
	exit 2
}

die()
{
	echo "error: $*" >&2
	exit 1
}

need()
{
	command -v "$1" >/dev/null 2>&1 || die "missing required host command: $1"
}

partition_device()
{
	local number=$1
	lsblk -nrpo NAME,PARTN -- "$DEVICE" |
		awk -v number="$number" '$2 == number { print $1; exit }'
}

unmount_children()
{
	local part type
	while read -r part type; do
		[ "$type" = part ] || continue
		if findmnt -rn -S "$part" >/dev/null 2>&1; then
			echo "Unmounting $part"
			umount -- "$part"
		fi
	done < <(lsblk -nrpo NAME,TYPE -- "$DEVICE")
}

confirm()
{
	echo
	echo "Target block device: $DEVICE"
	echo "Card size: $((TOTAL_SECTORS * SECTOR_SIZE / 1024 / 1024 / 1024)) GiB"
	echo "This will erase the card, replace its partition table, and format HOME."
	read -r -p "Type PROVISION $DEVICE to continue: " answer
	[ "$answer" = "PROVISION $DEVICE" ] || die "confirmation did not match; nothing was changed"
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

for command in awk blockdev dd e2fsck findmnt lsblk mkfs.ext4 partprobe readlink sfdisk stat umount udevadm; do
	need "$command"
done

[ "$(id -u)" -eq 0 ] || die "run as root, for example: sudo $0 /dev/sdX"

DEVICE=$(readlink -f -- "$1")
SEED_IMAGE=${2:-$DEFAULT_SEED_IMAGE}

[ -b "$DEVICE" ] || die "$DEVICE is not a block device"
[ -f "$SEED_IMAGE" ] || die "seed image not found: $SEED_IMAGE"
[ "$(lsblk -dnro TYPE -- "$DEVICE")" = disk ] || die "$DEVICE is not a whole disk; refusing a partition argument"

SECTOR_SIZE=$(blockdev --getss "$DEVICE")
[ "$SECTOR_SIZE" -eq 512 ] || die "seed image requires a 512-byte logical-sector card"
TOTAL_SECTORS=$(blockdev --getsz "$DEVICE")
ROOT_SECTORS=$((ROOT_BYTES / SECTOR_SIZE))
HOME_START=$((ROOT_START + ROOT_SECTORS))
[ "$TOTAL_SECTORS" -gt "$HOME_START" ] || die "card is too small for boot, 16 GiB root, and HOME"
HOME_SECTORS=$((TOTAL_SECTORS - HOME_START))

SEED_BYTES=$(stat -c %s -- "$SEED_IMAGE")
[ "$SEED_BYTES" -le $((TOTAL_SECTORS * SECTOR_SIZE)) ] || die "seed image is larger than the target card"

confirm
unmount_children

echo "Writing the approximately 1 GiB seed image"
dd if="$SEED_IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress

echo "Creating the card-sized partition table"
sfdisk --no-reread -- "$DEVICE" <<EOF
label: dos
unit: sectors

start=$BOOT_START, size=$BOOT_SECTORS, type=c, bootable
start=$ROOT_START, size=$ROOT_SECTORS, type=83
start=$HOME_START, size=$HOME_SECTORS, type=83
EOF

partprobe "$DEVICE"
udevadm settle

ROOT_DEV=$(partition_device 2)
HOME_DEV=$(partition_device 3)
[ -n "$ROOT_DEV" ] || die "could not find the new root partition"
[ -n "$HOME_DEV" ] || die "could not find the new HOME partition"

echo "Expanding the root filesystem to 16 GiB"
e2fsck -f -y "$ROOT_DEV"
resize2fs "$ROOT_DEV"

echo "Formatting HOME as ext4 with label HOME"
mkfs.ext4 -F -L HOME "$HOME_DEV"
sync

echo "Provisioning complete. The handheld will mount $HOME_DEV at /home by label."
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT -- "$DEVICE"
