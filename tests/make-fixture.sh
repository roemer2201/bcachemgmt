#!/usr/bin/env bash
#
# make-fixture.sh
#
# Description:
#   Builds a fake sysfs tree that looks like a machine with two bcache
#   backing devices, one cache device and one cache set. bcachemgmt reads it
#   through its --sysfs-root option, so the whole tool can be exercised on a
#   machine that has no bcache hardware and no bcache module.
#
#   The layout mirrors what the kernel exposes: a "bcache" directory below
#   each block device, the cache set below fs/bcache, and the symlinks
#   (dev, cache, set) that tie them together.
#
# Program flow:
#   1. Parse arguments and resolve configuration (CLI > env > default).
#   2. Remove an existing tree at the target path.
#   3. Create the cache set, the two backing devices and the cache device.
#   4. Link them together the way the kernel does.
#
# Usage:
#   make-fixture.sh [-d|--dir DIR] [-v|--verbose]
#
# Version: 1.0.0  (2026-08-27)

set -euo pipefail

SCRIPT_NAME="$(basename -- "${0}")"

# --- Defaults seeded from environment variables ---------------------------
# Precedence: command-line argument > environment variable > built-in default.
FIXTURE_DIR="${BCACHEMGMT_FIXTURE_DIR:-}"
VERBOSE="${BCACHEMGMT_FIXTURE_VERBOSE:-0}"

# The UUID of the fake cache set. Fixed so tests can refer to it.
FIXTURE_CACHE_SET_UUID="5a3c1f2e-8b7d-4c11-9a2f-000000000001"

# Print usage information to STDOUT.
usage() {
    cat <<'EOF'
Usage: make-fixture.sh [OPTIONS]

Builds a fake sysfs tree for testing bcachemgmt without bcache hardware.

Options:
  -d, --dir DIR   Where to build the tree. The directory is removed first.
                  Env: BCACHEMGMT_FIXTURE_DIR      Default: (required)
  -v, --verbose   Report every element that is created.
                  Env: BCACHEMGMT_FIXTURE_VERBOSE  Default: 0
  -h, --help      Show this help and exit.

Precedence for every option: command-line argument > environment variable
> built-in default.

Example:
  make-fixture.sh --dir /tmp/fake-sysfs
  bcachemgmt status --sysfs-root /tmp/fake-sysfs
EOF
}

# Report a diagnostic detail, but only in verbose mode.
vmsg() {
    if [ "${VERBOSE}" = "1" ]; then
        printf '%s\n' "$*"
    fi
}

# Report an explicit, anticipated failure and exit non-zero.
die() {
    printf '%s: error: %s\n' "${SCRIPT_NAME}" "$*" >&2
    exit 1
}

# Create a sysfs style attribute file. Values are written without a trailing
# newline, exactly as the kernel presents most of them.
attr() {
    local path="${1}"
    local value="${2}"
    printf '%s' "${value}" >"${path}"
    vmsg "attribute ${path} = ${value}"
}

# --- Argument parsing (highest precedence) --------------------------------
while [ "$#" -gt 0 ]; do
    case "${1}" in
        -d|--dir)
            if [ "$#" -lt 2 ]; then
                printf '%s: option %s requires an argument\n' "${SCRIPT_NAME}" "${1}" >&2
                exit 2
            fi
            FIXTURE_DIR="${2}"
            shift 2
            ;;
        --dir=*)
            FIXTURE_DIR="${1#*=}"
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            printf '%s: unknown option: %s\n' "${SCRIPT_NAME}" "${1}" >&2
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

# Build the cache set: the numbers are plausible for a half used SSD cache.
build_cache_set() {
    local dir="${1}/fs/bcache/${FIXTURE_CACHE_SET_UUID}"

    mkdir -p "${dir}/stats_total" "${dir}/stats_five_minute"
    attr "${dir}/cache_available_percent" "42"
    attr "${dir}/dirty_data" "1.2G"
    attr "${dir}/block_size" "512"
    attr "${dir}/bucket_size" "512.0k"
    attr "${dir}/congested" "0"
    attr "${dir}/errors" "[unregister] panic"
    attr "${dir}/io_error_limit" "8"
    attr "${dir}/synchronous" "0"
    attr "${dir}/congested_read_threshold_us" "2000"
    attr "${dir}/congested_write_threshold_us" "20000"
    attr "${dir}/journal_delay_ms" "100"
    attr "${dir}/stats_total/cache_hit_ratio" "87"
    attr "${dir}/stats_five_minute/cache_hit_ratio" "91"
    : >"${dir}/stop"
}

# Build bcache0: a cached device in writeback mode holding dirty data.
build_backing_cached() {
    local root="${1}"
    local dir="${root}/block/sdb/sdb1/bcache"

    mkdir -p "${dir}/stats_total" "${dir}/stats_five_minute" "${root}/block/bcache0"
    attr "${dir}/cache_mode" "writethrough [writeback] writearound none"
    attr "${dir}/state" "clean"
    attr "${dir}/running" "1"
    attr "${dir}/dirty_data" "1.2G"
    attr "${dir}/label" ""
    attr "${dir}/sequential_cutoff" "4.0M"
    attr "${dir}/readahead" "0"
    attr "${dir}/writeback_percent" "10"
    attr "${dir}/writeback_running" "1"
    attr "${dir}/writeback_delay" "30"
    attr "${dir}/writeback_metadata" "1"
    attr "${dir}/writeback_rate" "0"
    attr "${dir}/backing_dev_uuid" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    attr "${dir}/stats_total/cache_hit_ratio" "87"
    attr "${dir}/stats_five_minute/cache_hit_ratio" "91"
    attr "${dir}/stats_total/cache_hits" "1000"
    attr "${dir}/stats_total/cache_misses" "150"
    attr "${dir}/stats_total/bypassed" "0.0k"
    : >"${dir}/attach"
    : >"${dir}/detach"
    : >"${dir}/stop"
    ln -s "../../../bcache0" "${dir}/dev"
    ln -s "../../../../fs/bcache/${FIXTURE_CACHE_SET_UUID}" "${dir}/cache"
    ln -s "../sdb/sdb1/bcache" "${root}/block/bcache0/bcache"
}

# Build bcache1: registered and running, but with no cache attached. This is
# the state a machine ends up in when the SSD did not come back after a boot.
build_backing_uncached() {
    local root="${1}"
    local dir="${root}/block/sdc/sdc1/bcache"

    mkdir -p "${dir}/stats_total" "${dir}/stats_five_minute" "${root}/block/bcache1"
    attr "${dir}/cache_mode" "[writethrough] writeback writearound none"
    attr "${dir}/state" "no cache"
    attr "${dir}/running" "1"
    attr "${dir}/dirty_data" "0.0k"
    attr "${dir}/label" "data-disk"
    attr "${dir}/sequential_cutoff" "0.0k"
    attr "${dir}/readahead" "0"
    attr "${dir}/writeback_percent" "10"
    attr "${dir}/writeback_running" "0"
    attr "${dir}/backing_dev_uuid" "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"
    attr "${dir}/stats_total/cache_hit_ratio" "0"
    attr "${dir}/stats_five_minute/cache_hit_ratio" "0"
    : >"${dir}/attach"
    : >"${dir}/detach"
    : >"${dir}/stop"
    ln -s "../../../bcache1" "${dir}/dev"
    ln -s "../sdc/sdc1/bcache" "${root}/block/bcache1/bcache"
}

# Build the cache device that backs the cache set.
build_cache_device() {
    local root="${1}"
    local dir="${root}/block/nvme0n1/nvme0n1p1/bcache"

    mkdir -p "${dir}"
    attr "${dir}/nbuckets" "1024"
    attr "${dir}/bucket_size" "512.0k"
    attr "${dir}/block_size" "512"
    attr "${dir}/written" "12.4G"
    attr "${dir}/io_errors" "0"
    attr "${dir}/discard" "1"
    attr "${dir}/cache_replacement_policy" "[lru] fifo random"
    attr "${dir}/io_error_halflife" "80"
    ln -s "../../../../fs/bcache/${FIXTURE_CACHE_SET_UUID}" "${dir}/set"
}

main() {
    if [ -z "${FIXTURE_DIR}" ]; then
        printf '%s: no target directory given\n' "${SCRIPT_NAME}" >&2
        usage >&2
        exit 2
    fi
    # Refuse to work anywhere near a real sysfs: this function starts with
    # "rm -rf" and must never be aimed at the running system.
    case "${FIXTURE_DIR}" in
        /|/sys|/sys/*) die "refusing to build the fixture at ${FIXTURE_DIR}" ;;
    esac

    vmsg "building fixture at ${FIXTURE_DIR}"
    rm -rf -- "${FIXTURE_DIR}"
    mkdir -p "${FIXTURE_DIR}"

    build_cache_set "${FIXTURE_DIR}"
    build_backing_cached "${FIXTURE_DIR}"
    build_backing_uncached "${FIXTURE_DIR}"
    build_cache_device "${FIXTURE_DIR}"

    printf 'fixture ready: %s\n' "${FIXTURE_DIR}"
}

main
