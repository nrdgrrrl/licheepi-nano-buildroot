# Optional development swap

The development image does not create or enable swap automatically. After
booting with the SD card mounted read-write, run:

```sh
swapfile create
swapfile enable
```

The first command creates a 512 MiB `/swapfile` once and formats it with
`mkswap`. Pass another size in MiB if needed, for example `swapfile create
256`. Use `swapfile disable` when the extra memory is no longer needed. The
`swapfile-256m` compatibility command invokes the same helper. The
`/etc/inittab` `swapon -a` line remains harmless because this image does not
add `/swapfile` to `/etc/fstab`.
