# Parked features

Functions that are not part of `bcachemgmt` 2.x. Some of them existed in
version 1.3.0 and were removed to keep the tool small; one never existed.
They are kept here so they can be added back one at a time when there is a
real need for them.

The complete 1.3.0 implementation, including its tests, is in the git history
at commit `aa409d8` (`git show aa409d8:bin/bcachemgmt`). A feature can be
restored from there instead of being rewritten.

## SSD health of the cache devices (new)

**Purpose:** show in `status` whether the SSD behind a cache set is healthy,
because a failing cache device in `writeback` mode takes the not yet written
data with it.

**Idea:**

* For every cache device, query `smartctl -H /dev/...` (smartmontools) or,
  for NVMe devices, `nvme smart-log /dev/...` (nvme-cli).
* Check with `command -v` first whether either tool is installed. If neither
  is, `status` keeps working and shows the health as "not checked" instead
  of failing.
* Show the result as an extra field per cache device (table, `--long` and
  JSON), and colour a failed health check red like an inconsistent backing
  device.
* Both tools need root for most devices; an unprivileged `status` has to
  report "unknown", not an error.
* Only on the live system: skipped with `--sysfs-root`, like `lsblk`.

## doctor (removed in 2.0.0)

**Purpose:** run health checks and print one line per finding; exit 0 when
nothing was found and 1 otherwise, so it can be used directly as a monitoring
check (for example from Xymon).

**Checks in 1.3.0:**

| Check              | Reports                                                        |
|--------------------|----------------------------------------------------------------|
| `module`           | bcache sysfs interface missing (module not loaded)              |
| `tools`            | `bcache-tools` incomplete or not installed                      |
| `backing-running`  | backing device registered but not running (waiting for a cache) |
| `backing-attached` | backing device running without a cache, silently uncached       |
| `backing-state`    | backing device in state `inconsistent`                          |
| `writeback`        | dirty data present while writeback is not running               |
| `cache-set-used`   | cache set without any backing device (unused SSD)               |
| `cache-available`  | cache set below the available-space threshold (`-m PERCENT`)   |
| `cache-errors`     | I/O errors reported by a cache device                           |
| `unregistered`     | bcache superblock present but not registered with the kernel    |
| `udev-rule`        | no bcache udev rule installed, devices may not return on reboot |

`--json` emitted the findings plus a summary status. The SSD health check
above would fit here as an additional check.

## diff and apply (removed in 2.0.0)

**Purpose:** keep the sysfs tunables in a declarative file, show the drift
(`diff`, exit 1 on drift) and write only what differs (`apply`, with
read-back of every value).

**Why it existed:** tunables such as `sequential_cutoff`,
`writeback_percent` or `congested_read_threshold_us` are lost on every
reboot, so they have to be applied again at boot. `cache_mode` is not one of
them: the kernel stores it in the superblock of the backing device.

**Design notes from 1.3.0:**

* The file was a shell fragment with the directives
  `device NAME attr=value ...`, `cache_set UUID attr=value ...` and
  `cache_device NAME attr=value ...`; `all` was a default layer that a
  specific stanza always overrode.
* Only attributes the kernel accepts a write for were allowed, each with a
  type (enum, integer range, size), and errors were reported at the line in
  the file.
* Sizes had to be compared as byte counts, because the kernel prints `4.0M`
  for a written `4M`.
* An attribute the running kernel does not expose was reported as
  `unsupported` instead of being ignored.
* If the feature comes back: no `/etc/org.conf` and no ORGANIZATION lookup.
  A plain `/etc/bcachemgmt.conf` (plus `--config FILE`) is enough.
* `--yes` and `--force` must never be settable from the file.

## flush (removed in 2.0.0)

**Purpose:** drain all dirty data of a backing device to the backing disk
now and wait until the cache is clean, without detaching.

**How:** set `writeback_percent` to 0 so the writeback thread drains
everything, wait for `dirty_data` to reach zero (with progress output and
`--timeout`), and put the original value back afterwards. The restore must be
wired to an exit trap, so a Ctrl-C does not leave write caching disabled on
the device.

`detach` does not need it: the kernel writes the dirty data back before a
detach completes.

## stop of a whole cache set (removed in 2.0.0)

**Purpose:** stop a cache set (write `1` to `/sys/fs/bcache/<uuid>/stop`),
so the SSD is released. Every attached backing device loses its cache at
once, so each one had to be clean first (or `--force`).

2.0.0 only stops individual backing devices (`detach --stop`).

## Create a new cache set (removed in 2.0.0, was "make -C")

**Purpose:** format a fresh SSD as a cache device and register it, which
creates a new cache set. Uses the same guards as `attach -B` (no mount, no
partitions, no holders, no signature, direct `blkid --probe`), plus
`--bucket-size` and `--block-size` for `make-bcache`.

Note: current kernels support exactly one cache device per cache set
(`struct cache_set` holds a single `struct cache *cache`, and a second one is
refused with "duplicate cache set member"). "Adding an SSD to a cache set" is
therefore not possible; a second SSD means a second cache set.

## replace (removed in 2.0.0)

**Purpose:** replace the cache device of a cache set without losing data.
The order of the steps is what makes it safe:

1. Switch every attached backing device to `writethrough`, so no new dirty
   data appears.
2. Flush the existing dirty data and wait for it.
3. Detach the backing devices.
4. Stop the old cache set.
5. Create the new cache device and register it.
6. Attach every backing device to the new cache set.
7. Restore the original cache mode of each device.

The plan was printed and confirmed once; every step was a no-op when already
true, so an interrupted run could simply be started again. Depends on
`flush`, "stop of a whole cache set" and "create a new cache set" above.

## Register an existing backing device (new)

**Purpose:** bring back a backing device that was stopped (for example with
`detach --stop`) or not picked up by udev at boot. It still carries its
superblock and its data, and `status` lists it under "UNREGISTERED bcache
DEVICES".

**Idea:** `attach` accepts such a device as an argument, registers it
(`echo /dev/sdX > /sys/fs/bcache/register`) and then attaches it, without
formatting anything. It must be told apart from an unregistered cache device,
whose registration would bring up a whole cache set instead. Today
`attach -B` refuses such a disk and prints the manual `register` command.
