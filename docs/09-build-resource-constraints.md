# 09 — Host resource constraints during the EdgeAI build

Building `tisdk-edgeai-image` is far heavier than the minimal image — it pulls in the
full C7x/MMA stack, Qt6, and Weston. The build host used for this project was
resource-constrained (~15 GB free on the native Ubuntu partition, 16 GB RAM), well below
the 80–120 GB / high-RAM envelope a clean EdgeAI build expects. This document records
the memory and disk workarounds that were needed to complete the build, so the same
host can be used again without rediscovering them.

Related baseline settings live in [`config/local.conf.example`](../config/local.conf.example)
(`rm_work`, `RM_OLD_IMAGE`, `BB_DISKMON_DIRS`, `BB_NUMBER_THREADS = 1`,
`PARALLEL_MAKE = -j2`) — those are the *first* line of defence. The steps below are what
was additionally required when they were not enough.

## 1. Memory pressure — layered swap + cache control

The compile/link phases (notably `ti-tidl`, Qt6, and the kernel) exhausted physical RAM
and stalled the build. Mitigations, in the order applied:

### 8 GB primary swap file
```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab
```

### VM tuning to favour keeping build data in RAM over swapping early
```bash
# /etc/sysctl.d (or sysctl -w) :
vm.swappiness=10           # swap only under real pressure, not eagerly
vm.vfs_cache_pressure=50   # retain dentry/inode cache longer
sudo mount -o remount,noatime /   # drop atime writes on the build FS
```

### Second 8 GB swap file when 8 GB was still not enough
The peak footprint exceeded the first swap file, so a second was added on the fly:
```bash
sudo fallocate -l 8G /swapfile_temp
sudo chmod 600 /swapfile_temp
sudo mkswap /swapfile_temp
sudo swapon /swapfile_temp     # 16 GB total swap
```

### Manual cache flush + killing stuck tasks
When the page cache crowded out anonymous memory, it was flushed manually, and
bitbake tasks that hung under pressure were interrupted so the build could be resumed:
```bash
sudo sync; sudo sysctl -w vm.drop_caches=3   # free pagecache/dentries/inodes
pkill -INT -f "bitbake"                       # gracefully interrupt hung tasks
```

> `pkill -INT` (SIGINT) lets bitbake shut down its workers and leave the build
> resumable, rather than a hard `-9` kill that can leave stale locks/stamps.

## 2. Disk space — loop-mounted image on a secondary drive

The native partition ran out of space mid-build. `TMPDIR` in `local.conf` is set to
`${TOPDIR}/yocto-disk/tmp`, so the fix was to back `build/yocto-disk` with a large,
**growable** ext4 image file placed on a secondary (shared) drive that had free space,
and mount it there.

### Create and grow a virtual ext4 volume
```bash
# grow the backing file in place (started small, extended as the build demanded space)
truncate -s +20G /media/shared/yocto_tmp.img     # first extension
# ... later, when it filled again:
truncate -s +30G /media/shared/yocto_tmp.img     # ~50 GB total

# tell the loop device the backing file grew, then grow the filesystem onto it
sudo losetup -c /dev/loop45        # refresh capacity of the existing loop device
sudo resize2fs /dev/loop45         # expand the ext4 fs to the new size
```

### Mount it into the build tree
```bash
sudo mount -o loop /media/shared/yocto_tmp.img /home/mohamedkhalid/tisdk/build/yocto-disk
```
With `yocto-disk` backed by the 50 GB loop volume, `TMPDIR` had room to complete the
build without touching the nearly-full native partition.

> **Caveat:** the backing file lived on a shared (Windows-formatted host) drive exposed
> to Linux; the ext4 filesystem *inside* the image is what Yocto writes to, so POSIX
> permissions/symlinks behave correctly. The volume must be re-mounted after each reboot
> before resuming a build (it is not in `/etc/fstab`).

## 3. Continuous monitoring

Because both disk and memory ran close to their limits, the build was watched live to
catch a disk-full or OOM condition before it crashed a task:
```bash
watch -n 5 df -h / /home/mohamedkhalid/tisdk/build/yocto-disk   # free space, both FSes
sudo iotop -o                                                   # active I/O, spot stalls
```
`BB_DISKMON_DIRS` in `local.conf` provides an automatic `STOPTASKS`/`HALT` safety net on
top of this manual watch.

## Takeaways
- The EdgeAI image is buildable on a modest host, but only with **16 GB of swap** and a
  **loop-mounted overflow volume** for `TMPDIR`, on top of the standard `rm_work` /
  `RM_OLD_IMAGE` disk hygiene.
- Keep `BB_NUMBER_THREADS`/`PARALLEL_MAKE` low (1 / -j2) — parallelism trades directly
  against peak RAM and disk churn on a constrained host.
- Re-mount the `yocto-disk` loop volume and re-enable swap after any reboot before
  resuming the build.
