# bcachemgmt

Management tooling for Linux `bcache` setups.

`bin/bcachemgmt` is a single, self-contained bash script. The current version
is read-only: it collects the state of every registered bcache device from
sysfs and reports it, either as a compact overview or as a list of health
check findings. It never attaches, detaches, stops or formats a device, so it
is safe to run on a production system at any time.

## Requirements

* bash 4.2 or newer
* a kernel with bcache support
* `lsblk` (optional) - used to detect unregistered bcache superblocks and to
  show what sits on top of a bcache device

Root privileges are not required for reading; a few sysfs attributes may be
unreadable for an unprivileged user and are then reported as unknown.

## Installation

The script has no dependencies beyond the above, so copying it is enough:

```
install -m 0755 bin/bcachemgmt /usr/local/sbin/bcachemgmt
```

## Usage

```
bcachemgmt status [-l] [-j] [DEVICE ...]
bcachemgmt doctor [-j] [-m PERCENT]
bcachemgmt help
bcachemgmt version
```

Every option can also be passed as an exported environment variable. The
precedence is: command-line argument > environment variable > built-in
default. Run `bcachemgmt --help` for the full list.

### status

Prints one line per backing device with its bcache device, backing device,
attached cache, cache mode, state, dirty data, hit ratio and what is mounted
on top of it, followed by a summary per cache set, the flash-only volumes and
any device that carries a bcache superblock without being registered.

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

`--long` adds a detail block per device, including the stable `/dev/disk/by-id`
name, the backing device UUID and the runtime tunables.

### doctor

Runs the health checks and prints one line per check. Checks currently
implemented:

| Check             | Reports                                                        |
|-------------------|----------------------------------------------------------------|
| `module`          | bcache sysfs interface missing (module not loaded)              |
| `tools`           | `bcache-tools` incomplete or not installed                      |
| `backing-running` | backing device registered but not running (waiting for a cache) |
| `backing-attached`| backing device running without a cache, silently uncached       |
| `backing-state`   | backing device in state `inconsistent`                          |
| `writeback`       | dirty data present while writeback is not running               |
| `cache-set-used`  | cache set without any backing device (unused SSD)               |
| `cache-available` | cache set below the available-space threshold (`-m`)            |
| `cache-errors`    | I/O errors reported by a cache device                           |
| `unregistered`    | bcache superblock present but not registered with the kernel    |
| `udev-rule`       | no bcache udev rule installed, devices may not return on reboot |

`doctor` exits 0 when nothing was found and 1 when at least one warning or
critical finding was reported, so it can be used directly as a pass/fail
check.

### JSON output

Both commands accept `-j` / `--json` and emit a stable structure with `null`
for unknown values:

```
bcachemgmt status --json | jq -r '.backing_devices[] | "\(.bcache_device) \(.cache_mode)"'
bcachemgmt doctor --json | jq -r '.summary.status'
```

## Testing against a captured sysfs tree

`--sysfs-root DIR` reads the device state below `DIR` instead of `/sys`. This
makes it possible to reproduce a setup from another machine without any bcache
hardware. Checks that need the live system (`lsblk`, `/dev/disk/by-id`, the
udev rule) are skipped and reported as "not checked" in that mode.

## Roadmap

Planned for the next stages, in this order:

1. Desired-state configuration: cache mode and tunables per device in a config
   file, `apply` to enforce them and `diff` to show drift. Sysfs tunables are
   lost on every reboot, so this is the main gap after `status` and `doctor`.
2. Runtime operations: `flush`, `attach`, `detach`, `stop`, each with a
   dry-run mode and a dirty-data flush that is waited for.
3. Setup operations: guarded `make-bcache` wrappers and a guided cache device
   replacement.
