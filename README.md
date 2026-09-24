# bcachemgmt

Management tooling for Linux `bcache` setups.

`bin/bcachemgmt` is a single, self-contained bash script with four jobs:

* show the state of every bcache device (`status`)
* switch the cache mode of the backing devices of a cache set
  (`set-cache-mode`)
* add backing devices to a cache set, including fresh disks (`attach`)
* remove backing devices from a cache set, optionally stopping them
  (`detach`)

`status` never writes to a device and is safe to run at any time. Every
command that changes something supports `--dry-run`, asks for confirmation
before a destructive step and records what it changed in syslog.

Functions that were part of earlier versions and may come back later are
described in [NEW-FEATURES.md](NEW-FEATURES.md).

## Requirements

* bash 4.2 or newer
* a kernel with bcache support
* `lsblk` - optional for `status` (detects unregistered superblocks and shows
  what sits on top of a bcache device)
* `blkid` and `make-bcache` (bcache-tools) - required for `attach -B` only

Reading needs no privileges; a few sysfs attributes may be unreadable for an
unprivileged user and are then reported as unknown. Every changing command
needs root, because sysfs does.

## Installation

```
install -m 0755 bin/bcachemgmt /usr/local/sbin/bcachemgmt
```

## Usage

```
bcachemgmt status         [-l] [-j] [DEVICE ...]
bcachemgmt set-cache-mode [-n] -m MODE (-c SET | DEVICE ...)
bcachemgmt attach         [-n] [-y] [-f] [-c SET] [-m MODE] [-B DEV ...] [DEVICE ...]
bcachemgmt detach         [-n] [-y] [-f] [-t SECONDS] [--stop] DEVICE ...
bcachemgmt help | version
```

Every option can also be passed as an exported environment variable
(`BCACHEMGMT_*`). The command line wins over the environment, the
environment over the built-in default. `bcachemgmt --help` lists every
option with its variable.

A `DEVICE` is a registered backing device and can be named in any of these
ways:

```
bcache0                               the bcache device name
sdb1  or  /dev/sdb1                   the backing device
ata-Samsung_SSD_870_S5Y2NJ0R123456    a /dev/disk/by-id name
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  the backing device UUID
```

A cache set (`SET`) is named by its UUID or by its cache device, for example
`/dev/nvme0n1p1`.

Prefer a by-id name or a UUID in anything you automate: the `bcacheN`
numbering depends on the order the devices are registered in and can change
across a reboot.

## status

Prints one line per backing device, followed by a summary per cache set, the
flash-only volumes and any device that carries a bcache superblock without
being registered.

```
$ bcachemgmt status
BCACHE   BACKING    CACHE           MODE          STATE         DIRTY  HIT%  USAGE
bcache0  /dev/sdb1  /dev/nvme0n1p1  writeback     clean          1.2G    87  /srv (ext4)
bcache1  /dev/sdc1  -               writethrough  no cache       0.0k     0  lvm: vg0

CACHE SETS
  5a3c1f2e-8b7d-4c11-9a2f-000000000001
    cache devices   : /dev/nvme0n1p1
    backing devices : bcache0
    available       : 42%   dirty: 1.2G   hit ratio: 87% total / 91% 5min
```

`--long` adds a detail block per device, including the stable
`/dev/disk/by-id` name, the backing device UUID and the runtime tunables.
`--json` emits a stable structure with `null` for unknown values:

```
bcachemgmt status --json | jq -r '.backing_devices[] | "\(.bcache_device) \(.cache_mode)"'
```

## set-cache-mode

The cache mode is a property of each backing device, not of the cache set.
`--cache-set` changes every backing device attached to one set, which is the
usual unit of work; device arguments change individual devices, and `all`
changes every backing device on the host.

```
$ bcachemgmt set-cache-mode --cache-mode writethrough --cache-set /dev/nvme0n1p1
Cache set 5a3c1f2e-8b7d-4c11-9a2f-000000000001: 2 attached backing device(s)
bcache0: 1.2G of dirty data stays in the cache and is written back in the background
set cache_mode of bcache0 (/dev/sdb1) from 'writeback' to 'writethrough'
set cache_mode of bcache2 (/dev/sdd1) from 'writeback' to 'writethrough'

Changed the cache mode of 2 device(s).
```

Only `.../bcache/cache_mode` is written; nothing is recreated and no data is
moved. The kernel stores the mode in the superblock of the backing device, so
the change survives a reboot. The value is read back afterwards, so a mode
the kernel silently ignored is reported as an error. A device that is already
in the wanted mode is skipped, so the command is safe to repeat.

## attach

Adds backing devices to a cache set. With exactly one cache set on the host,
`--cache-set` may be omitted.

```
bcachemgmt attach bcache1                                # a registered backing device
bcachemgmt attach -B /dev/sdd --cache-mode writeback     # a fresh disk
```

A fresh disk given with `-B` goes through these steps:

1. Every `-B` disk is checked before any of them is touched: it must exist,
   be a block device, not be mounted, carry no partitions or holders, not be
   registered with bcache and carry no signature (probed directly with
   `blkid --probe`, so a missing udev database cannot hide a filesystem).
   `--force` overrides partitions, holders and a foreign signature; a
   mounted disk is always refused. `--wipe` allows overwriting an old bcache
   superblock.
2. One confirmation for all disks (`--yes` in scripts).
3. `make-bcache -B` formats them. The block size of the cache set is passed
   on, because the kernel refuses to attach a backing device with a smaller
   block size than the set.
4. The disks are registered with the kernel explicitly, so the result does
   not depend on udev.
5. Every device is attached, and `--cache-mode` is applied if given.

A disk that already carries a bcache superblock is most likely a stopped
backing device that still holds its data. The command refuses it and says so
instead of formatting it; register it with
`echo /dev/sdX > /sys/fs/bcache/register` and attach it without `-B`.

## detach

Removes backing devices from their cache set. bcache writes the dirty data
back to the backing disk first; the command waits for that (`--timeout`,
`0` waits indefinitely) and the device keeps running uncached as
`/dev/bcacheN`.

```
bcachemgmt detach bcache1
bcachemgmt detach --stop --timeout 0 bcache1
```

`--stop` additionally stops the device after the detach: `/dev/bcacheN`
disappears and the disk is released. The data and the superblock stay on the
disk. Before anything is written, a mounted bcache device or one with
holders (LVM, LUKS, ...) is refused unless `--force` is given, so a refusal
never leaves a device detached but not stopped.

## Safety model

* `--dry-run` is supported by every changing command and performs no write
  at all.
* `attach -B` and `detach` ask for confirmation. Without a terminal there is
  nobody to ask, so they abort instead of assuming consent: an unattended job
  has to state its intent with `--yes`.
* Every change is written to syslog via `logger`. `status` stays out of the
  system log.
* Changing anything is refused unless the tool is talking to the real kernel
  interface, so a command aimed at a captured sysfs tree cannot pretend to
  have done something.

## Testing against a captured sysfs tree

`--sysfs-root DIR` reads the device state below `DIR` instead of `/sys`, so a
setup can be reproduced without bcache hardware. Checks that need the live
system (`lsblk`, `/dev/disk/by-id`) are skipped in that mode, and every
changing command refuses to run unless `--dry-run` is given as well.

```
tests/make-fixture.sh --dir /tmp/fake-sysfs
bcachemgmt status --sysfs-root /tmp/fake-sysfs

tests/run-tests.sh            # no bcache hardware needed
tests/run-tests.sh --verbose  # list every test
```

The write path is exercised by sourcing the script and calling its functions
directly, because a real invocation refuses to write to a captured tree. One
test proves that no dry run touches a single file, by comparing the
modification times of the whole tree. The guards of `attach -B` are tested
against a real loop device; those tests need root and loop device support and
are skipped when either is missing.
