# bcachemgmt

Management tooling for Linux `bcache` setups.

`bin/bcachemgmt` is a single, self-contained bash script. It reads the state
of every registered bcache device from sysfs and lets you report on it, keep
it in sync with a declarative configuration file, and run the operations
that bcache otherwise only exposes as raw sysfs writes.

The reporting commands (`status`, `doctor`, `diff`) never write to a device
and are safe to run at any time, including on production systems. Every
command that does change something supports `--dry-run`, asks for
confirmation before a destructive step, and records what it changed in
syslog.

## Requirements

* bash 4.2 or newer
* a kernel with bcache support
* `lsblk` - optional for reporting (detects unregistered superblocks and
  shows what sits on top of a bcache device)
* `blkid` - used by the guards of `make` and `replace` to probe a device for
  an existing signature; `lsblk` is the fallback
* `bcache-tools` - required for `make` and `replace` only

Reading needs no privileges; a few sysfs attributes may be unreadable for an
unprivileged user and are then reported as unknown. Every changing command
needs root, because sysfs does.

## Installation

The script has no dependencies beyond the above, so copying it is enough:

```
install -m 0755 bin/bcachemgmt /usr/local/sbin/bcachemgmt
install -m 0644 examples/bcachemgmt.conf /etc/bcachemgmt.conf
```

## Usage

```
bcachemgmt status  [-l] [-j] [DEVICE ...]
bcachemgmt doctor  [-j] [-m PERCENT]
bcachemgmt diff    [-j] [DEVICE ...]
bcachemgmt apply   [-n] [DEVICE ...]
bcachemgmt set-cache-mode [-n] --cache-mode MODE (DEVICE ... | --cache-set UUID)
bcachemgmt flush   [-n] [-t SECONDS] DEVICE ...
bcachemgmt attach  [-n] [-c CACHE] DEVICE ...
bcachemgmt detach  [-n] [-y] [-t SECONDS] DEVICE ...
bcachemgmt stop    [-n] [-y] [-f] TARGET ...
bcachemgmt make    [-n] [-y] -B DEV ... [-C DEV ...]
bcachemgmt replace [-n] [-y] --cache-set UUID --new DEV
bcachemgmt help
bcachemgmt version
```

Every option can also be passed as an exported environment variable, and most
can be set in the configuration file. The precedence is: command-line
argument > environment variable > configuration file > built-in default. Run
`bcachemgmt --help` for the full list.

A `DEVICE` can be named in any of these ways, and `all` addresses every
backing device:

```
bcache0                               the bcache device name
sdb1  or  /dev/sdb1                   the backing device
ata-Samsung_SSD_870_S5Y2NJ0R123456    a /dev/disk/by-id name
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  the backing device UUID
```

Prefer a by-id name or a UUID in anything you automate: the `bcacheN`
numbering depends on the order the devices are registered in and can change
across a reboot.

## Reporting

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

`--long` adds a detail block per device, including the stable
`/dev/disk/by-id` name, the backing device UUID and the runtime tunables.

### doctor

Runs the health checks and prints one line per check. Checks currently
implemented:

| Check              | Reports                                                        |
|--------------------|----------------------------------------------------------------|
| `module`           | bcache sysfs interface missing (module not loaded)              |
| `tools`            | `bcache-tools` incomplete or not installed                      |
| `backing-running`  | backing device registered but not running (waiting for a cache) |
| `backing-attached` | backing device running without a cache, silently uncached       |
| `backing-state`    | backing device in state `inconsistent`                          |
| `writeback`        | dirty data present while writeback is not running               |
| `cache-set-used`   | cache set without any backing device (unused SSD)               |
| `cache-available`  | cache set below the available-space threshold (`-m`)            |
| `cache-errors`     | I/O errors reported by a cache device                           |
| `unregistered`     | bcache superblock present but not registered with the kernel    |
| `udev-rule`        | no bcache udev rule installed, devices may not return on reboot |

`doctor` exits 0 when nothing was found and 1 when at least one warning or
critical finding was reported, so it can be used directly as a pass/fail
check.

## Desired-state configuration

Sysfs tunables are lost on every reboot, so the settings that matter belong
in a file rather than in someone's shell history. `bcachemgmt.conf` declares
the state the machine should be in; `diff` shows the drift and `apply`
writes it.

The file is a shell fragment and is looked up in this order, first match per
scope, user scope overriding system scope:

```
/etc/${ORGANIZATION}/bcachemgmt.conf   (ORGANIZATION comes from /etc/org.conf)
/etc/orgdefault/bcachemgmt.conf
/etc/bcachemgmt.conf
${HOME}/.config/${ORGANIZATION}/bcachemgmt.conf
${HOME}/.config/orgdefault/bcachemgmt.conf
${HOME}/.config/bcachemgmt.conf
```

`--config FILE` reads one specific file instead; `--config none` ignores the
configuration entirely. See `examples/bcachemgmt.conf` for a commented
template with the full list of settable attributes.

```
# defaults for every backing device
device all \
    sequential_cutoff=4M \
    writeback_percent=10

# the database volume, addressed by a name that survives a reboot
device aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
    cache_mode=writeback \
    writeback_percent=20

cache_set all congested_read_threshold_us=2000
cache_device nvme0n1p1 cache_replacement_policy=lru
```

`all` is a default layer: a stanza naming a specific device always wins over
it, wherever the two appear in the file.

### diff

```
$ bcachemgmt diff
desired state

STATE  TARGET   ATTRIBUTE          CURRENT       DESIRED
drift  bcache1  sequential_cutoff  0.0k          4M
drift  bcache1  cache_mode         writethrough  writearound

6 in sync, 2 drifting, 0 unsupported by this kernel
Run 'bcachemgmt apply' to write the desired state.
```

Sizes are compared as byte counts, so the `4.0M` the kernel prints back and
the `4M` you wrote are correctly reported as identical. `diff` exits 0 when
everything matches and 1 on any drift, so it works as a drift alarm. Add
`--verbose` to list the attributes that already match.

An attribute the running kernel does not expose is reported as `unsupported`
rather than silently ignored.

### apply

Writes only the attributes that actually differ, reads each one back
afterwards and reports it when the kernel clamped or ignored the value.
`--dry-run` prints every write it would perform without performing any.

```
$ bcachemgmt apply
set sequential_cutoff of bcache1 from '0.0k' to '4M'
set cache_mode of bcache1 from 'writethrough' to 'writearound'

Applied 2 attribute(s).
Note: these are runtime settings. Run 'bcachemgmt apply' again after a reboot, or from a boot-time unit.
```

## Runtime operations

| Command          | What it does                                                               |
|------------------|----------------------------------------------------------------------------|
| `set-cache-mode` | Switches the cache mode of existing backing devices (`--cache-mode`), named individually or per cache set (`--cache-set`) |
| `flush`          | Drains all dirty data to the backing disk and waits until the cache is clean|
| `attach`         | Attaches backing devices to a cache set (`--cache`, autodetected if one)    |
| `detach`         | Detaches backing devices; bcache writes the dirty data back first           |
| `stop`           | Stops a backing device or a whole cache set                                 |

### set-cache-mode

Changes the cache mode of backing devices that already exist. Nothing is
recreated and no data is moved: the only thing written is
`.../bcache/cache_mode`, exactly the attribute `apply` would write for a
`device NAME cache_mode=...` directive. Use it when you want the change now
without declaring it, or when the device is not covered by the configuration
file at all.

```
$ bcachemgmt set-cache-mode --cache-mode writethrough bcache0
bcache0: 1.2G of dirty data stays in the cache and is written back in the background; run 'bcachemgmt flush bcache0' to drain it now
set cache_mode of bcache0 (/dev/sdb1) from 'writeback' to 'writethrough'

Changed the cache mode of 1 device(s).
Note: this is a runtime setting. Declare 'device NAME cache_mode=writethrough' in bcachemgmt.conf and run 'bcachemgmt apply' at boot to make it persistent.
```

`--dry-run` prints the same lines prefixed with `would have`, and writes
nothing:

```
$ bcachemgmt set-cache-mode --cache-mode writeback --dry-run all
Dry run: nothing will be changed.

bcache0: cache mode is already writeback, nothing to do
bcache1: writeback keeps not yet written data on the cache device only; losing that device from now on means losing that data
bcache1: no cache attached, the mode takes effect once one is
would have set cache_mode of bcache1 (/dev/sdc1) from 'writethrough' to 'writeback'

Dry run: 1 device(s) would be changed, nothing was written.
```

`--cache-set` changes every backing device attached to one cache set in a
single call, which is the usual unit of work: one SSD caches a group of
disks, and the whole group is meant to run in the same mode. The set is named
by its UUID or by one of its cache devices, and only the devices attached to
it are touched, so a host with a second cache set or with uncached devices
stays untouched where `all` would have reached everything:

```
$ bcachemgmt set-cache-mode --cache-mode writethrough --cache-set 5a3c1f2e-8b7d-4c11-9a2f-000000000001
Cache set 5a3c1f2e-8b7d-4c11-9a2f-000000000001: 3 attached backing device(s)
set cache_mode of bcache0 (/dev/sdb1) from 'writeback' to 'writethrough'
set cache_mode of bcache1 (/dev/sdc1) from 'writeback' to 'writethrough'
set cache_mode of bcache2 (/dev/sdd1) from 'writeback' to 'writethrough'

Changed the cache mode of 3 device(s).
```

Naming the cache set by its SSD works just as well
(`--cache-set /dev/nvme0n1p1`). Device arguments and `--cache-set` are
mutually exclusive: the two would answer the same question differently, so
giving both is a usage error instead of a silent decision.

A device that is already in the wanted mode is reported and skipped, so the
command is safe to run repeatedly. Switching away from `writeback` leaves the
dirty data in the cache to be written back in the background; the command
says so and points at `flush` if you want it drained now. Switching to
`writeback` says what a failing cache device would then cost. Neither is
refused: no data is lost either way.

The write goes straight to `.../bcache/cache_mode` and the value is read back
afterwards, so a mode the kernel silently ignored is reported as an error
rather than as a success.

### flush, attach, detach and stop

`flush` works the way bcache itself does: it sets `writeback_percent` to 0 so
the writeback thread drains everything, waits for `dirty_data` to reach zero,
and puts the original value back afterwards. The restore is wired to an exit
trap, so interrupting a long flush with Ctrl-C does not leave write caching
disabled on the device.

`stop` refuses to act on a device that is mounted, that has holders such as
LVM or LUKS on top of it, or that still holds dirty data. `--force`
overrides each of those and says so.

`--timeout SECONDS` bounds the waiting; `--timeout 0` waits indefinitely,
which is the right choice for a large writeback cache.

```
bcachemgmt set-cache-mode --cache-mode writearound bcache0
bcachemgmt set-cache-mode --cache-mode writethrough --cache-set 5a3c1f2e-...
bcachemgmt flush bcache0 --timeout 0
bcachemgmt attach --cache /dev/nvme0n1p1 bcache1
bcachemgmt detach --yes bcache0
bcachemgmt stop --yes bcache1
```

## Setup operations

### make

A guarded wrapper around `make-bcache`. Before anything is formatted, every
target device is checked: it must exist, be a block device, not be mounted,
carry no partitions or holders, not already be registered with bcache and
carry no filesystem signature. All devices are checked before the first one
is touched, so a rejected second device cannot leave a half-finished setup.

Each of those is checked at its own source rather than through one tool that
might be uninformed: sysfs for the bcache registration, the partitions and
the holders, `/proc/self/mounts` for the mounts, and `blkid --probe` for the
signature. That last one matters: `lsblk` reports what udev recorded, which
is empty on any system where udev did not run - a container, a rescue boot,
an initramfs - and an empty answer there would hand a fully populated disk to
`make-bcache`. If nothing can probe the device at all, that is treated as a
reason to stop, not as an all-clear.

```
bcachemgmt make -B /dev/sdb1 -C /dev/nvme0n1p1 --cache-mode writeback
```

`--wipe` allows overwriting an existing bcache superblock, `--force`
overrides the other guards, and `--no-register` skips registering the result
with the kernel. Registration is done explicitly rather than left to udev, so
the outcome is the same whether udev is running or not.

### replace

Replaces the cache device of a cache set without losing data. The order of
the steps is what makes it safe:

1. Switch every attached backing device to `writethrough`, so no new dirty
   data appears.
2. Flush the existing dirty data and wait for it.
3. Detach the backing devices.
4. Stop the old cache set.
5. Create the new cache device and register it.
6. Attach every backing device to the new cache set.
7. Restore the original cache mode of each device.

```
bcachemgmt replace --cache-set 5a3c1f2e-... --new /dev/nvme1n1p1
```

The plan is printed and confirmed once, before anything happens; the
individual steps do not ask again. Every step is a no-op when it is already
true, so an interrupted run can simply be started again.

## Safety model

* `--dry-run` is supported by every changing command and performs no write at
  all, not even a restore.
* Destructive commands ask for confirmation. Without a terminal there is
  nobody to ask, so they abort instead of assuming consent: an unattended job
  has to state its intent with `--yes`.
* `--yes` and `--force` cannot be set from the configuration file, so a file
  can never silently disarm the prompts.
* Every change is written to syslog via `logger`. The reporting commands stay
  out of the system log.
* Changing anything is refused unless the tool is talking to the real kernel
  interface, so a command aimed at a captured sysfs tree cannot pretend to
  have done something.

## JSON output

`status`, `doctor` and `diff` accept `-j` / `--json` and emit a stable
structure with `null` for unknown values:

```
bcachemgmt status --json | jq -r '.backing_devices[] | "\(.bcache_device) \(.cache_mode)"'
bcachemgmt doctor --json | jq -r '.summary.status'
bcachemgmt diff   --json | jq -r '.entries[] | select(.state == "drift")'
```

## Testing against a captured sysfs tree

`--sysfs-root DIR` reads the device state below `DIR` instead of `/sys`. This
makes it possible to reproduce a setup from another machine without any
bcache hardware. Checks that need the live system (`lsblk`,
`/dev/disk/by-id`, the udev rule) are skipped and reported as "not checked"
in that mode, and every changing command refuses to run unless `--dry-run` is
given as well.

The repository ships a fixture generator and a test suite that use exactly
that mechanism, so they run anywhere:

```
tests/make-fixture.sh --dir /tmp/fake-sysfs
bcachemgmt status --sysfs-root /tmp/fake-sysfs

tests/run-tests.sh            # 108 tests, no bcache hardware needed
tests/run-tests.sh --verbose  # list every test
```

The suite covers the reporting output, the configuration parser and its error
messages, the layered precedence, the safety guards and the write path. The
write path is exercised by sourcing the script and calling its functions
directly, because a real invocation refuses to write to a captured tree. One
test proves that no dry run touches a single file, by comparing the
modification times of the whole tree rather than its contents - a write that
happens to restore the value that was already there would pass a content
check.

The guards of `make` are tested against a real loop device, since their whole
job is to look at a device the fixture cannot imitate. Those tests need root
and loop device support and are skipped when either is missing.
