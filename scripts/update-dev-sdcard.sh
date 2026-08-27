#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
DEFAULT_SEED_IMAGE="$REPO_DIR/dist/sdcard-dev.img"

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

image_partition_geometry()
{
	local number=$1
	local line
	line=$(sfdisk -d -- "$SEED_IMAGE" | awk -v number="$number" '$1 ~ (number "$") { print; exit }')
	[ -n "$line" ] || die "seed image has no partition $number"
	IMAGE_START=$(printf '%s\n' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\),.*/\1/p')
	IMAGE_SECTORS=$(printf '%s\n' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\),.*/\1/p')
	[ -n "$IMAGE_START" ] && [ -n "$IMAGE_SECTORS" ] || die "could not parse seed partition $number"
}

confirm()
{
	echo
	echo "Target block device: $DEVICE"
	echo "This updates only the boot and root partitions; HOME will not be written."
	read -r -p "Type UPDATE $DEVICE to continue: " answer
	[ "$answer" = "UPDATE $DEVICE" ] || die "confirmation did not match; nothing was changed"
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

for command in awk blkid blockdev dd e2fsck findmnt lsblk readlink sfdisk sed umount; do
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
ROOT_DEV=$(partition_device 2)
HOME_DEV=$(partition_device 3)
[ -n "$ROOT_DEV" ] || die "could not find partition 2"
[ -n "$HOME_DEV" ] || die "could not find partition 3"

ROOT_BYTES=$((16 * 1024 * 1024 * 1024))
ROOT_SECTORS=$((ROOT_BYTES / SECTOR_SIZE))
[ "$(blockdev --getsz "$ROOT_DEV")" -ge "$ROOT_SECTORS" ] || die "partition 2 is smaller than 16 GiB"
[ "$(blkid -s LABEL -o value -- "$HOME_DEV" 2>/dev/null || true)" = HOME ] || die "partition 3 is not labeled HOME; refusing to risk the home data"

image_partition_geometry 1
BOOT_START_IMAGE=$IMAGE_START
BOOT_SECTORS_IMAGE=$IMAGE_SECTORS
image_partition_geometry 2
ROOT_START_IMAGE=$IMAGE_START
ROOT_SECTORS_IMAGE=$IMAGE_SECTORS

BOOT_DEV=$(partition_device 1)
[ -n "$BOOT_DEV" ] || die "could not find partition 1"
[ "$(blockdev --getsz "$BOOT_DEV")" -ge "$BOOT_SECTORS_IMAGE" ] || die "card boot partition is smaller than the seed boot image"
[ "$(blockdev --getsz "$ROOT_DEV")" -ge "$ROOT_SECTORS_IMAGE" ] || die "card root partition is smaller than the seed root image"

confirm
unmount_children

echo "Updating the boot partition from the seed image"
dd if="$SEED_IMAGE" of="$BOOT_DEV" bs=512 skip="$BOOT_START_IMAGE" count="$BOOT_SECTORS_IMAGE" conv=fsync status=progress

echo "Replacing the root filesystem from the seed image"
dd if="$SEED_IMAGE" of="$ROOT_DEV" bs=512 skip="$ROOT_START_IMAGE" count="$ROOT_SECTORS_IMAGE" conv=fsync status=progress
e2fsck -f -y "$ROOT_DEV"
resize2fs "$ROOT_DEV"
sync

echo "Update complete. HOME was not written or reformatted."
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT -- "$DEVICE"
