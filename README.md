# Linux Business Card Bootable Linux Image (Buildroot)

![Linux Business Card hardware](licheepi-nano-lcd.jpg)

The Linux Business Card is a small F1C200S single-board computer derived from the [Lichee Pi Nano](https://wiki.sipeed.com/soft/Lichee/zh/Nano-Doc-Backup/get_started/first_eye.html) hardware ([English article](https://www.cnx-software.com/2018/08/17/licheepi-nano-cheap-sd-card-sized-linux-board/), [old site](http://nano.lichee.pro/index.html)). It is about the size of an SD card and runs Linux. The original manufacturer documentation is available on the [old manufacturer site](http://nano.lichee.pro/get_started/first_eye.html) (in Chinese, but easily readable thanks to Google Translate). However, the tooling used to build the full card/SPI-Flash images is mostly made up of custom shell scripts, and is not always easy to extend or maintain.

This repository contains a Buildroot-based Linux image build for the Linux Business Card. It compiles a U-Boot image, Linux kernel, the rootfs image and the final partitioned binary image for the bootable micro SD card (note: SPI-Flash boot image builds are possible but are not part of the current hardware workflow).

The finished device identifies itself as `Linux Business Card`, uses hostname `bizcard1`, and shows `Welcome to Linux Business Card` at login.

All the custom configuration is packaged as a `BR2_EXTERNAL` Buildroot extension to avoid the need to fork the entire Buildroot repo. You can fork this project or integrate it as a Git subtree to customize your own OS build on top of it as needed.

The build process uses [Docker](Dockerfile) for reproducibility and convenience. If you are an advanced Linux user you can set up your own build on your host machine by running the same commands as [Dockerfile.base].

Explore the configuration and modify it at will: e.g. start with the main Buildroot defconfig file in [configs/licheepi_nano_defconfig](configs/licheepi_nano_defconfig). You will most likely need to update the Linux DTS (device tree) file to match your board usage, for which you can edit [suniv-f1c100s-licheepi-nano-custom.dts](board/licheepi_nano/suniv-f1c100s-licheepi-nano-custom.dts). Sample peripheral descriptions are listed in comments there - uncomment and modify what you need. This custom DTS file includes the original [suniv-f1c100s-licheepi-nano.dts](https://github.com/unframework/linux/blob/nano-5.11/arch/arm/boot/dts/suniv-f1c100s-licheepi-nano.dts) in the kernel tree, so you don't need to fork the kernel or duplicate code to make your local customizations. I may also set up an equivalent customizable U-Boot DTS file in the future.

More customization is available by changing other files in the `board` and `configs` directories, such as the kernel boot command, kernel defconfig and SD image layout. There is also a preconfigured rootfs overlay folder, ready to populate.

This effort heavily borrowed from the work done by the FunKey Zero project: https://github.com/Squonk42/buildroot-licheepi-zero/. The latter targets Lichee Pi Zero, a sibling board to the Nano, but I was able to adapt it for use with Nano, and also converted the content to be a `BR2_EXTERNAL` extension rather than a full Buildroot fork.

Also check out https://github.com/florpor/licheepi-nano: that work was done prior to mine but I somehow didn't find it until later, oops.

## Dependencies

Builds are Docker-based: multi-stage syntax support is needed (available since Docker Engine 17.05 release in 2017). Docker BuildKit support is needed for direct `tar` file output but you can omit that and manually copy `sdcard.img` from the built Docker images.

## Building the Image

The easiest way is using Docker (on Windows/MacOS/Linux). If your Docker is older than v23, ensure that you have [BuildKit enabled](https://docs.docker.com/build/buildkit/#getting-started).

First, clone this repo to your host:

```sh
git clone git@github.com:nrdgrrrl/licheepi-nano-buildroot.git
```

There are two options available - fast build using the [prepared Docker Hub images](https://hub.docker.com/r/unframework/licheepi-nano-buildroot) or from scratch (takes 1-2 hours or more).

Fast build:

```sh
docker build --output type=tar,dest=- . | (mkdir -p dist && tar x -C dist)
```

The built image will be available in `dist/sdcard.img` - you can write this to your bootable micro SD card (see below).

### Development image

The separate development configuration is [configs/licheepi_nano_dev_defconfig](configs/licheepi_nano_dev_defconfig). It keeps the existing ARM926EJ-S/ARMv5 soft-float external glibc toolchain and grows the root filesystem to approximately 1 GiB. Build it with:

```sh
docker build -f Dockerfile.dev --target devout --output type=local,dest=/tmp/licheepi-nano-dev-dist .
mkdir -p dist
cp /tmp/licheepi-nano-dev-dist/sdcard-dev.img dist/sdcard-dev.img
```

The image includes the supported Buildroot target development utilities, including binutils, make, pkgconf, Git, curl, wget, archive/compression tools, patch, file, diffutils, findutils, and util-linux swap tools. Buildroot 2023.02 deliberately does not provide a native target GCC/G++ package: its external-toolchain GCC/G++ are host-side cross compilers, and Buildroot removes libc development headers from the target. A native `gcc`/`g++` image therefore requires moving this project to a distribution-oriented build (for example Debian, OpenEmbedded, or Yocto) or maintaining a separately built native toolchain package; this dev image does not silently make that ABI/toolchain change.

The ESP8266 SLIP link starts through `/etc/init.d/S40slip` with a short delay and three bounded attempts. It uses `/usr/bin/slip-up /dev/ttyS2`, avoids duplicate `slattach` processes, installs the existing default route, and writes Quad9 DNS to `/etc/resolv.conf`. Use `/etc/init.d/S40slip stop|start|restart` for lifecycle control. `S45time` then makes up to three attempts to run `rdate -s time.nist.gov`; an unavailable server only produces a visible warning and does not block boot.

After that, `S50dropbear` starts the Dropbear binary and ED25519 host key built natively under `/home/victoria/.local`, on port 22 with password authentication and root SSH login disabled. It uses `/run/dropbear.pid`, recognizes an already-running Dropbear, and fails visibly without hanging if the persistent HOME files are not present yet. No Dropbear binary, host key, authorized key, password, or other secret is stored in this repository.

The optional development swap helper is `swapfile create` followed by `swapfile enable`; it creates a 512 MiB `/swapfile` by default and never creates or enables swap automatically. The compatibility name `swapfile-256m` is retained and uses the same helper. An explicit size can be passed, for example `swapfile create 256`. `esp-reset` uses libgpiod 1.6.3's `--usec=100000` syntax and releases PD15 back to input/high-Z after the pulse.

The kernel uses `CONFIG_POWER_RESET_GPIO` and the standard `gpio-poweroff` binding for PC1 (F1C physical pin 60), with `<&pio 2 1 GPIO_ACTIVE_LOW>`. Its pinctrl pull-up and inactive active-low initialization keep PC1 physically HIGH during boot and normal runtime; kernel poweroff drives it LOW to release the power latch.

The development image also creates the stable local account `victoria` with UID/GID 1000, home `/home/victoria`, and `/bin/bash`. Its build-time password is locked; set a real password on the handheld with `passwd victoria`. `sudo` is enabled through `/etc/sudoers.d/90-victoria`. Root serial login remains available for recovery.

At boot, `S05home` verifies that `/home` is an actual mountpoint, mounts it from `LABEL=HOME` through `/etc/fstab` when needed, and only then creates the top-level `/home/victoria` directory with UID/GID 1000. It never recursively changes or replaces an existing home, and logs a visible error while allowing boot to continue if HOME is unavailable.

## Long-term 64 GB Development Card

Do not make a large raw image for the long-term card. The approximately 1 GiB `sdcard-dev.img` is only a seed. The host-side [provisioning script](scripts/provision-dev-sdcard.sh) writes that seed, creates the fixed 16 GiB root partition, expands its ext4 filesystem, and creates an ext4 `HOME` partition using all remaining sectors of the actual block device. `/home` is mounted by `LABEL=HOME`, not by a hard-coded partition number.

Before permanently provisioning a card, first write the current known-good seed image and test it without changing the layout:

```sh
sudo dd if=dist/sdcard-dev.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Replace `/dev/sdX` with the explicitly identified 64 GB card. Verify U-Boot and Linux boot, that root mounts, that `lsblk` and the kernel see the full card capacity, and that basic reads and writes work. Only then run the destructive provisioning workflow:

```sh
sudo scripts/provision-dev-sdcard.sh /dev/sdX dist/sdcard-dev.img
```

The script rejects partition arguments, calculates the HOME end from the card's reported sector count, prints the target, and requires typing an exact confirmation before unmounting, repartitioning, or formatting. It does not guess `/dev/sda` and must not be run against a disk containing data that should be kept.

After first boot on the provisioned card, set the account password and optionally enable swap:

```sh
passwd victoria
swapfile create       # 512 MiB on / by default
swapfile enable
findmnt /home         # should show the filesystem labeled HOME
```

For a routine Buildroot update, use the separate [preserve-home update script](scripts/update-dev-sdcard.sh):

```sh
sudo scripts/update-dev-sdcard.sh /dev/sdX dist/sdcard-dev.img
```

It writes only the boot partition and the approximately 1 GiB seed root filesystem, then runs `e2fsck` and `resize2fs` so root fills the existing 16 GiB partition. It does not rewrite the partition table, format, or write the HOME partition. Software installed directly into `/` is lost when rootfs is replaced; keep source under `/home/victoria` and preferably install personal software under `/home/victoria/.local`.

Full rebuild from scratch:

```sh
docker build -f Dockerfile.base --output type=tar,dest=- . | (mkdir -p dist && tar x -C dist)
```

## Write Bootable Image to SD Card

On Windows, use Rufus or Balena Etcher to write the bootable SD card image (`sdcard.img`). Typical image size is at least 18-20Mb, which should fit on most modern SD cards.

Example command to write image to SD card on Linux host:

```sh
sudo dd if=output/images/sdcard.img of=DEVICE # e.g. /dev/sd?, etc
```

Then, plug the micro SD card into the Linux Business Card and turn it on!

## Iterating on the Base Image

The "fast build" Docker command allows tweaking config files in `board` and `configs` without having to rebuild everything. First it pulls the [pre-built Docker Hub image](https://hub.docker.com/r/unframework/licheepi-nano-buildroot), re-copies the defconfig and board folder from local workspace into it, and runs the `make` command once again.

Note that certain config file changes will not automatically cause Buildroot to rebuild affected folders. Please see the Buildroot manual sections [Understanding when a full rebuild is necessary](https://buildroot.org/downloads/manual/manual.html#full-rebuild) and [Understanding how to rebuild packages](https://buildroot.org/downloads/manual/manual.html#rebuild-pkg).

It's very convenient to run the intermediate Docker image and inspect the build folder, run `make menuconfig`, etc:

```sh
docker build --target main -t licheepi-nano-tmp
docker run -it licheepi-nano-tmp /bin/bash
```

Just don't forget to e.g. carry out any resulting `.config` file changes back into your source folder as needed.

Once you are happy with your own additions, you can run a full Docker image rebuild and tag the result:

```sh
docker build -f Dockerfile.base --target main -t licheepi-nano-mybase:latest .
```

And then use that image as the base for generating the SD image as well as further config iterations:

```sh
docker build \
  --build-arg="BASE_IMAGE=licheepi-nano-mybase" \
  --output type=tar,dest=- . \
  | (mkdir -p dist && tar x -C dist)
```

For reference, here is how the base image is generated and published (these are the commands I run as the repo maintainer):

```sh
docker build -f Dockerfile.base --target main -t unframework/licheepi-nano-buildroot:$(git rev-parse --short HEAD) .
docker build -f Dockerfile.base --target main -t unframework/licheepi-nano-buildroot:latest .
docker push unframework/licheepi-nano-buildroot:$(git rev-parse --short HEAD)
docker push unframework/licheepi-nano-buildroot:latest
```

## Linux and U-Boot Versions

The built kernel is [a Linux fork based off 5.11](https://github.com/unframework/linux/commits/nano-5.11), with hardware-specific customizations. I have cherry-picked the original customizations from @Lichee-Pi Linux repo [nano-5.2-tf branch](https://github.com/torvalds/linux/compare/master...Lichee-Pi:nano-5.2-tf) and [nano-5.2-flash branch](https://github.com/torvalds/linux/compare/master...Lichee-Pi:nano-5.2-flash) (both based off Linux version 5.2) and added tiny fixes due to newer kernel version.

The built U-Boot is [a fork based off v2021.01](https://github.com/unframework/u-boot/commits/2021.01-f1c100s) with hardware-specific customizations, which I ported over from [the original @Lichee-Pi v2018.01 fork](https://github.com/Lichee-Pi/u-boot/commits/nano-v2018.01) referenced in the docs. By the way, the latter is actually itself a rebase of [an earlier repo branch maintained by @Icenowy](https://github.com/u-boot/u-boot/compare/master...Icenowy:f1c100s-spiflash). Splash screen support is not yet ported.

## Inherited LCD Screen Support

The inherited `suniv-f1c100s-licheepi-nano.dts` device tree describes an 800x480 TFT screen on the 40-pin flex-PCB connector. The current Linux Business Card image intentionally disables the LCD/TCON path so the GPIO buttons and other board peripherals remain available. If display support is needed for another hardware variant, the `panel` block in [suniv-f1c100s-licheepi-nano-custom.dts](board/licheepi_nano/suniv-f1c100s-licheepi-nano-custom.dts) can be restored and adapted (see also [original docs](http://nano.lichee.pro/build_sys/devicetree.html#lcd)).
