#!/usr/bin/env bash
#
# run-tests.sh
#
# Description:
#   Test suite for bcachemgmt. It builds a fake sysfs tree with
#   make-fixture.sh and checks the tool against it, so the whole suite runs
#   on a machine without bcache hardware, without the bcache module and
#   without root privileges.
#
#   Two kinds of test are run. The black box tests invoke the script as a
#   command and check its output and exit status. The white box tests source
#   the script, which defines its functions without running a command, and
#   call individual functions directly. That is what makes the write path
#   testable: writing to a captured sysfs tree is refused for real
#   invocations, on purpose, so the write is exercised one level below.
#
# Program flow:
#   1. Parse arguments and resolve configuration (CLI > env > default).
#   2. Build a fresh fixture in a temporary directory.
#   3. Run the black box tests against the fixture.
#   4. Source the script and run the white box tests.
#   5. Report the totals and exit non-zero if anything failed.
#
# Usage:
#   run-tests.sh [-v|--verbose] [-k|--keep]
#
# Version: 1.1.0  (2026-08-28)

set -uo pipefail

SCRIPT_NAME="$(basename -- "${0}")"
TESTS_DIR="$(cd -- "$(dirname -- "${0}")" && pwd)"
REPO_DIR="$(dirname -- "${TESTS_DIR}")"
BCACHEMGMT="${REPO_DIR}/bin/bcachemgmt"

# --- Defaults seeded from environment variables ---------------------------
# Precedence: command-line argument > environment variable > built-in default.
# Named apart from the script's own VERBOSE/vmsg: the white box tests source
# bcachemgmt, and identical names would let it take over the runner's
# reporting halfway through the suite.
TEST_VERBOSE="${BCACHEMGMT_TEST_VERBOSE:-0}"
KEEP="${BCACHEMGMT_TEST_KEEP:-0}"
WORKDIR="${BCACHEMGMT_TEST_WORKDIR:-}"

TESTS_RUN=0
TESTS_FAILED=0

# Print usage information to STDOUT.
usage() {
    cat <<'EOF'
Usage: run-tests.sh [OPTIONS]

Runs the bcachemgmt test suite against a generated fake sysfs tree.

Options:
  -v, --verbose      Print the output of every test, not only of failures.
                     Env: BCACHEMGMT_TEST_VERBOSE  Default: 0
  -k, --keep         Keep the working directory instead of removing it.
                     Env: BCACHEMGMT_TEST_KEEP     Default: 0
  -w, --workdir DIR  Use DIR instead of a temporary directory.
                     Env: BCACHEMGMT_TEST_WORKDIR  Default: (mktemp)
  -h, --help         Show this help and exit.

Precedence for every option: command-line argument > environment variable
> built-in default.

Example:
  run-tests.sh --verbose
EOF
}

# Report a diagnostic detail, but only in verbose mode.
tmsg() {
    if [ "${TEST_VERBOSE}" = "1" ]; then
        printf '%s\n' "$*"
    fi
}

# --- Argument parsing (highest precedence) --------------------------------
while [ "$#" -gt 0 ]; do
    case "${1}" in
        -v|--verbose) TEST_VERBOSE=1; shift ;;
        -k|--keep)    KEEP=1; shift ;;
        -w|--workdir)
            if [ "$#" -lt 2 ]; then
                printf '%s: option %s requires an argument\n' "${SCRIPT_NAME}" "${1}" >&2
                exit 2
            fi
            WORKDIR="${2}"
            shift 2
            ;;
        --workdir=*) WORKDIR="${1#*=}"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)
            printf '%s: unknown option: %s\n' "${SCRIPT_NAME}" "${1}" >&2
            usage >&2
            exit 2
            ;;
        *) break ;;
    esac
done

# ==========================================================================
# Assertions
# ==========================================================================

# Record the result of one test and report a failure with its details.
report() {
    local ok="${1}"
    local name="${2}"
    local detail="${3}"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "${ok}" -eq 1 ]; then
        tmsg "ok   ${name}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'FAIL %s\n' "${name}" >&2
        printf '     %s\n' "${detail}" >&2
    fi
}

# Assert that two strings are equal.
assert_equal() {
    local name="${1}"
    local expected="${2}"
    local actual="${3}"

    if [ "${expected}" = "${actual}" ]; then
        report 1 "${name}" ""
    else
        report 0 "${name}" "expected '${expected}', got '${actual}'"
    fi
}

# Assert that a command exits with a given status. The command's output is
# kept in LAST_OUTPUT so a following assertion can inspect it.
LAST_OUTPUT=""
assert_status() {
    local name="${1}"
    local expected="${2}"
    shift 2
    local actual

    LAST_OUTPUT="$("$@" 2>&1)"
    actual="$?"
    if [ "${actual}" = "${expected}" ]; then
        report 1 "${name}" ""
    else
        report 0 "${name}" "expected exit ${expected}, got ${actual}; output: ${LAST_OUTPUT}"
    fi
}

# Assert that the output of the last command contains a substring.
assert_output_contains() {
    local name="${1}"
    local needle="${2}"

    if [[ "${LAST_OUTPUT}" == *"${needle}"* ]]; then
        report 1 "${name}" ""
    else
        report 0 "${name}" "output does not contain '${needle}'; output: ${LAST_OUTPUT}"
    fi
}

# Assert that the output of the last command does not contain a substring.
assert_output_lacks() {
    local name="${1}"
    local needle="${2}"

    if [[ "${LAST_OUTPUT}" != *"${needle}"* ]]; then
        report 1 "${name}" ""
    else
        report 0 "${name}" "output unexpectedly contains '${needle}'; output: ${LAST_OUTPUT}"
    fi
}

# Fingerprint every file of the fixture by path, size and modification time.
# Used to prove that a dry run wrote nothing at all.
tree_state() {
    find "${WORKDIR}/sysfs" -type f -printf '%p %s %T@\n' | sort
}

# ==========================================================================
# Black box tests: the script as a command
# ==========================================================================

# The reporting commands must keep working exactly as before, including their
# exit codes, because monitoring uses them as pass/fail checks.
test_reporting() {
    assert_status "version exits 0" 0 "${BCACHEMGMT}" version
    assert_output_contains "version prints the version" "bcachemgmt 1."

    assert_status "help exits 0" 0 "${BCACHEMGMT}" help
    assert_output_contains "help lists the apply command" "apply"
    assert_output_contains "help lists the set-cache-mode command" "set-cache-mode"
    assert_output_contains "help lists the replace command" "replace"

    assert_status "unknown command exits 2" 2 "${BCACHEMGMT}" nonsense
    assert_status "unknown option exits 2" 2 "${BCACHEMGMT}" status --nonsense

    assert_status "status exits 0" 0 "${BCACHEMGMT}" status "${COMMON[@]}"
    assert_output_contains "status shows the cached device" "bcache0"
    assert_output_contains "status shows the uncached device" "bcache1"

    assert_status "status filter selects one device" 0 "${BCACHEMGMT}" status "${COMMON[@]}" bcache0
    assert_output_lacks "status filter excludes the other device" "bcache1"

    # A backing device can also be addressed by its stable identifiers.
    assert_status "status filter by backing uuid" 0 \
        "${BCACHEMGMT}" status "${COMMON[@]}" ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee
    assert_output_contains "uuid filter finds bcache1" "bcache1"
    assert_output_lacks "uuid filter excludes bcache0" "/dev/sdb1"

    # doctor returns 1 because the fixture contains an uncached device.
    assert_status "doctor reports the uncached device" 1 "${BCACHEMGMT}" doctor "${COMMON[@]}"
    assert_output_contains "doctor names the uncached device" "running uncached"

    assert_status "status --json exits 0" 0 "${BCACHEMGMT}" status "${COMMON[@]}" --json
    assert_output_contains "json contains the cache mode" '"cache_mode": "writeback"'
}

# The desired state must be compared against the running state correctly,
# including the wildcard layer and the size normalization.
test_diff() {
    local conf="${WORKDIR}/test.conf"

    cat >"${conf}" <<'CONF'
MIN_AVAILABLE=15

device all \
    sequential_cutoff=4M \
    writeback_percent=10

device bcache0 \
    cache_mode=writeback \
    writeback_percent=20

device ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee cache_mode=writearound

cache_set all congested_read_threshold_us=2000
cache_device nvme0n1p1 cache_replacement_policy=fifo
CONF

    assert_status "diff reports drift with exit 1" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "diff finds the cache mode drift" "writearound"
    assert_output_contains "diff finds the policy drift" "cache_replacement_policy"
    assert_output_contains "diff counts four drifting attributes" "4 drifting"

    # 4.0M in sysfs and 4M in the configuration are the same size, so the
    # already correct device must not be reported as drifting.
    assert_output_lacks "matching sizes are not reported as drift" "drift  bcache0         sequential_cutoff"

    # A specific stanza overrides the wildcard layer regardless of order.
    assert_status "diff --verbose lists matches too" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" -v --config "${conf}"
    assert_output_contains "wildcard is overridden by the specific stanza" "drift  bcache0                               writeback_percent            10            20"

    # An empty configuration means there is nothing to be in drift about.
    assert_status "diff without configuration exits 0" 0 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config none
    assert_output_contains "diff says nothing is declared" "nothing is declared"
}

# A broken configuration must be reported where it is written, not where it
# would eventually fail.
test_config_validation() {
    local conf="${WORKDIR}/bad.conf"

    printf 'device bcache0 nonsense=1\n' >"${conf}"
    assert_status "unknown attribute is rejected" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "the unknown attribute is named" "not a configurable bcache attribute"

    printf 'device bcache0 cache_mode=turbo\n' >"${conf}"
    assert_status "invalid enum value is rejected" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "the allowed values are listed" "expected one of"

    printf 'device bcache0 writeback_percent=99\n' >"${conf}"
    assert_status "out of range value is rejected" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "the limit is named" "must not exceed 40"

    printf 'device bcache0 sequential_cutoff=lots\n' >"${conf}"
    assert_status "invalid size is rejected" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "the expected size format is shown" "must be a size"

    printf 'device bcache0 cache_mode\n' >"${conf}"
    assert_status "missing assignment is rejected" 1 \
        "${BCACHEMGMT}" diff "${COMMON[@]}" --config "${conf}"
    assert_output_contains "the malformed word is named" "not an attribute=value assignment"
}

# Nothing may be written while the tool is pointed at a captured tree, and a
# dry run must describe every write it would have made.
test_write_refusals() {
    local conf="${WORKDIR}/test.conf"
    local cmd

    for cmd in apply flush attach detach stop; do
        assert_status "${cmd} refuses a captured sysfs tree" 1 \
            "${BCACHEMGMT}" "${cmd}" "${COMMON[@]}" --config "${conf}" bcache0
        assert_output_contains "${cmd} explains the refusal" "refusing to modify devices"
    done

    assert_status "apply --dry-run exits 0" 0 \
        "${BCACHEMGMT}" apply "${COMMON[@]}" --dry-run --config "${conf}"
    assert_output_contains "dry run announces itself" "Dry run: nothing will be changed"
    assert_output_contains "dry run lists the writes" "would have set cache_mode of bcache1"
    assert_output_contains "dry run counts the writes" "4 attribute(s) would be written"

    # A dry run must leave the tree untouched.
    assert_equal "dry run did not write" "[writethrough] writeback writearound none" \
        "$(cat "${WORKDIR}/sysfs/block/sdc/sdc1/bcache/cache_mode")"

    # ... and not only in content: comparing modification times catches a
    # write path that forgot --dry-run even when it happens to write the
    # value that was already there, which a content check would not notice.
    # The suite runs as root often enough that making the tree read-only
    # would prove nothing, so the timestamps are the evidence.
    local before after
    before="$(tree_state)"
    "${BCACHEMGMT}" flush "${COMMON[@]}" --dry-run --verbose all >/dev/null 2>&1
    "${BCACHEMGMT}" apply "${COMMON[@]}" --dry-run --config "${conf}" >/dev/null 2>&1
    "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run bcache0 >/dev/null 2>&1
    "${BCACHEMGMT}" stop "${COMMON[@]}" --dry-run --force bcache0 >/dev/null 2>&1
    "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run bcache1 >/dev/null 2>&1
    after="$(tree_state)"
    assert_equal "no dry run touched a single file" "${before}" "${after}"

    # The commands that need a device must say so instead of doing nothing.
    assert_status "flush without a device exits 2" 2 "${BCACHEMGMT}" flush "${COMMON[@]}"
    assert_status "attach without a device exits 2" 2 "${BCACHEMGMT}" attach "${COMMON[@]}"
    assert_status "make without a device exits 2" 2 "${BCACHEMGMT}" make "${COMMON[@]}"
    assert_status "replace without --new exits 2" 2 "${BCACHEMGMT}" replace "${COMMON[@]}"
    assert_status "make rejects positional arguments" 2 "${BCACHEMGMT}" make "${COMMON[@]}" sdb1

    assert_status "an unknown device is reported" 1 \
        "${BCACHEMGMT}" flush "${COMMON[@]}" --dry-run nosuchdevice
    assert_output_contains "the unknown device is named" "no bcache backing device matches 'nosuchdevice'"
}

# The non-destructive cache mode change. It must refuse a captured tree like
# every other changing command, and its dry run must describe the switch
# precisely enough to be reviewed before the same call is made for real.
test_set_cache_mode() {
    local before after

    assert_status "set-cache-mode refuses a captured sysfs tree" 1 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --cache-mode writethrough bcache0
    assert_output_contains "set-cache-mode explains the refusal" "refusing to modify devices"

    assert_status "set-cache-mode without --cache-mode exits 2" 2 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run bcache0
    assert_output_contains "the missing mode is named" "needs --cache-mode MODE"

    assert_status "set-cache-mode without a device exits 2" 2 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode none
    assert_output_contains "the missing device is named" "needs at least one device"

    assert_status "an invalid mode exits 2" 2 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode turbo bcache0
    assert_output_contains "the allowed modes are listed" \
        "expected writethrough, writeback, writearound or none"

    # The dry run has to name the device, the old value and the new one:
    # that triple is what makes it reviewable.
    assert_status "set-cache-mode --dry-run exits 0" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode writethrough bcache0
    assert_output_contains "the dry run announces itself" "Dry run: nothing will be changed"
    assert_output_contains "the dry run describes the switch" \
        "would have set cache_mode of bcache0 (/dev/sdb1) from 'writeback' to 'writethrough'"
    assert_output_contains "the dry run counts the devices" "1 device(s) would be changed"

    # Leaving writeback must point at the dirty data that stays behind.
    assert_output_contains "the dirty data is called out" "of dirty data stays in the cache"

    # Entering writeback must state what a failing cache device now costs.
    assert_status "switching to writeback exits 0" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode writeback bcache1
    assert_output_contains "the writeback risk is stated" "losing that device"
    assert_output_contains "the missing cache is stated" "no cache attached"

    # A device that already has the mode is a no-op, not an error.
    assert_status "an unchanged mode exits 0" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode writeback bcache0
    assert_output_contains "the no-op is named" "cache mode is already writeback"
    assert_output_contains "the no-op counts as no change" "0 device(s) would be changed"

    # "all" addresses every backing device in one call.
    assert_status "set-cache-mode all exits 0" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode writearound all
    assert_output_contains "all reaches bcache0" "cache_mode of bcache0"
    assert_output_contains "all reaches bcache1" "cache_mode of bcache1"
    assert_output_contains "all counts both devices" "2 device(s) would be changed"

    # The mode is settable by environment variable like every other option.
    assert_status "the mode can come from the environment" 0 \
        env BCACHEMGMT_CACHE_MODE=none "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run bcache0
    assert_output_contains "the environment value is used" "to 'none'"

    # And none of it may have touched a single byte of the fixture.
    before="$(tree_state)"
    "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --verbose --cache-mode none all \
        >/dev/null 2>&1
    after="$(tree_state)"
    assert_equal "set-cache-mode --dry-run wrote nothing" "${before}" "${after}"
}

# The layered precedence must hold: command line over environment over
# configuration file over built-in default.
test_precedence() {
    local conf="${WORKDIR}/prec.conf"

    printf 'MIN_AVAILABLE=55\n' >"${conf}"

    # Configuration beats the built-in default of 10.
    assert_status "config sets min-available" 1 \
        "${BCACHEMGMT}" doctor "${COMMON[@]}" --config "${conf}"
    assert_output_contains "config value is used" "threshold 55%"

    # Environment beats the configuration.
    assert_status "environment beats config" 1 \
        env BCACHEMGMT_MIN_AVAILABLE=66 "${BCACHEMGMT}" doctor "${COMMON[@]}" --config "${conf}"
    assert_output_contains "environment value is used" "threshold 66%"

    # The command line beats both.
    assert_status "command line beats environment" 1 \
        env BCACHEMGMT_MIN_AVAILABLE=66 "${BCACHEMGMT}" doctor "${COMMON[@]}" --config "${conf}" -m 77
    assert_output_contains "command line value is used" "threshold 77%"

    # A configuration file must not be able to disarm the safety prompts.
    printf 'ASSUME_YES=1\nFORCE=1\n' >"${conf}"
    assert_status "config cannot set --yes" 1 \
        "${BCACHEMGMT}" stop "${COMMON[@]}" --config "${conf}" bcache1
    assert_output_contains "the prompt is still required" "refusing to modify devices"
}

# ==========================================================================
# White box tests: functions in isolation
# ==========================================================================

# Source the script. It defines everything without running a command, so its
# functions can be called directly. This is the only way to exercise the
# write path, which real invocations refuse against a captured tree.
load_script() {
    # shellcheck source=/dev/null
    . "${BCACHEMGMT}"
    # The sourced script turns errexit on for its own benefit; the test suite
    # deliberately runs commands that fail, so it is turned back off here.
    set +e
    SYSFS_ROOT="${WORKDIR}/sysfs"
    DRY_RUN=0
    VERBOSE=0   # the script's own verbosity, not the suite's
    LIVE_SYSTEM=0
    JSON_OUTPUT=0
    DEVICE_FILTER=()
}

# Sizes are what the kernel reformats behind the tool's back, so their
# normalization is the single most failure prone comparison in the script.
test_size_normalization() {
    assert_equal "plain bytes"        "4096"       "$(size_to_bytes 4096)"
    assert_equal "kilobytes"          "1024"       "$(size_to_bytes 1k)"
    assert_equal "kernel style zero"  "0"          "$(size_to_bytes 0.0k)"
    assert_equal "megabytes"          "4194304"    "$(size_to_bytes 4M)"
    assert_equal "kernel style float" "4194304"    "$(size_to_bytes 4.0M)"
    assert_equal "fractional size"    "1610612736" "$(size_to_bytes 1.5G)"
    assert_equal "terabytes"          "1099511627776" "$(size_to_bytes 1T)"
    assert_equal "leading zero digit" "8"          "$(size_to_bytes 08)"
    assert_equal "garbage is unknown" ""           "$(size_to_bytes lots)"
    assert_equal "empty is unknown"   ""           "$(size_to_bytes '')"

    if size_is_zero "0.0k"; then report 1 "0.0k counts as zero" ""; else report 0 "0.0k counts as zero" "not detected"; fi
    if size_is_zero "1.2G"; then report 0 "1.2G is not zero" "wrongly detected"; else report 1 "1.2G is not zero" ""; fi

    if attr_values_equal backing sequential_cutoff "4.0M" "4M"; then
        report 1 "4.0M equals 4M" ""
    else
        report 0 "4.0M equals 4M" "reported as different"
    fi
    if attr_values_equal backing cache_mode "writeback" "writearound"; then
        report 0 "different modes differ" "reported as equal"
    else
        report 1 "different modes differ" ""
    fi
}

# Reading a multiple-choice attribute must yield the selected word, and the
# collected state must contain what the fixture declares.
test_collection() {
    collect_state
    assert_equal "two backing devices found" "2" "${#BDEV_ORDER[@]}"
    assert_equal "one cache device found"    "1" "${#CDEV_ORDER[@]}"
    assert_equal "one cache set found"       "1" "${#CSET_ORDER[@]}"
    assert_equal "the selected cache mode is read" "writeback" "${BDEV[0|cache_mode]}"
    assert_equal "the bcache device is resolved"   "bcache0"   "${BDEV[0|bcache_dev]}"
    assert_equal "the cache set link is resolved"  "5a3c1f2e-8b7d-4c11-9a2f-000000000001" "${BDEV[0|cache_set]}"
    assert_equal "the uncached device has no set"  ""          "${BDEV[1|cache_set]}"
}

# The write path: plan, write, verify. Writing is exercised through
# sysfs_write, one level below the guard that refuses a captured tree.
test_write_path() {
    local conf="${WORKDIR}/test.conf"
    local i drift_before drift_after

    CONFIG_LOADED="${conf}"
    WANT_SCOPE=(); WANT_KEY=(); WANT_ATTR=(); WANT_VALUE=()
    # shellcheck source=/dev/null
    . "${conf}"

    build_plan
    drift_before="$(plan_count drift)"
    assert_equal "the plan finds four drifting attributes" "4" "${drift_before}"

    # Perform the writes the plan asks for.
    for i in "${!PLAN_STATE[@]}"; do
        [ "${PLAN_STATE[i]}" = "drift" ] || continue
        sysfs_write "${PLAN_PATH[i]}" "${PLAN_DESIRED[i]}"
    done

    assert_equal "the cache mode was written" "writearound" \
        "$(cat "${WORKDIR}/sysfs/block/sdc/sdc1/bcache/cache_mode")"
    assert_equal "the writeback percent was written" "20" \
        "$(cat "${WORKDIR}/sysfs/block/sdb/sdb1/bcache/writeback_percent")"

    # After the writes the same configuration must report no drift at all.
    BDEV=(); BDEV_ORDER=(); CDEV=(); CDEV_ORDER=(); CSET=(); CSET_ORDER=()
    FLASH_VOLUMES=(); REGISTERED=()
    collect_state
    build_plan
    drift_after="$(plan_count drift)"
    assert_equal "no drift is left after applying" "0" "${drift_after}"
    assert_equal "everything is now in sync" "8" "$(plan_count match)"
}

# The write half of "set-cache-mode", exercised one level below the guard
# that refuses a captured tree. It must write cache_mode and nothing else,
# and it must recognize a device that is already in the wanted mode.
test_set_cache_mode_write() {
    local before after

    # The plan test above changed the tree, so the state is collected again.
    BDEV=(); BDEV_ORDER=(); CDEV=(); CDEV_ORDER=(); CSET=(); CSET_ORDER=()
    FLASH_VOLUMES=(); REGISTERED=()
    collect_state

    CACHE_MODE_CHANGED=0
    before="$(tree_state)"
    set_cache_mode_one 0 "${BDEV[0|cache_mode]}" >/dev/null
    after="$(tree_state)"
    assert_equal "an unchanged mode is not counted" "0" "${CACHE_MODE_CHANGED}"
    assert_equal "an unchanged mode writes nothing"  "${before}" "${after}"

    set_cache_mode_one 0 writearound >/dev/null
    assert_equal "the new mode was written" "writearound" \
        "$(cat "${WORKDIR}/sysfs/block/sdb/sdb1/bcache/cache_mode")"
    assert_equal "the change was counted" "1" "${CACHE_MODE_CHANGED}"

    # Only cache_mode may move. writeback_percent is the neighbour a write
    # aimed at the wrong path would most plausibly hit; the plan test left
    # it at 20, so an unchanged 20 proves the write stayed where it belongs.
    assert_equal "the neighbouring attribute is untouched" "20" \
        "$(cat "${WORKDIR}/sysfs/block/sdb/sdb1/bcache/writeback_percent")"

    # Reading it back through the collector must yield the selected word.
    BDEV=(); BDEV_ORDER=(); CDEV=(); CDEV_ORDER=(); CSET=(); CSET_ORDER=()
    FLASH_VOLUMES=(); REGISTERED=()
    collect_state
    assert_equal "the written mode is read back" "writearound" "${BDEV[0|cache_mode]}"
}

# The guards are what stand between "stop the device I am done with" and data
# loss, so each one is checked for the refusal and for the --force override.
test_guards() {
    local out rc

    # bcache0 holds 1.2G of dirty data in the fixture.
    out="$( (guard_dirty_data 0 "stop") 2>&1 )"
    rc="$?"
    assert_equal "a dirty device is refused" "1" "${rc}"
    if [[ "${out}" == *"dirty data"* ]]; then
        report 1 "the refusal names the dirty data" ""
    else
        report 0 "the refusal names the dirty data" "got: ${out}"
    fi

    FORCE=1
    out="$( (guard_dirty_data 0 "stop") 2>&1 )"
    rc="$?"
    assert_equal "--force allows a dirty device" "0" "${rc}"
    if [[ "${out}" == *"warning"* ]]; then
        report 1 "--force still warns" ""
    else
        report 0 "--force still warns" "got: ${out}"
    fi
    FORCE=0

    # The clean device must pass without --force.
    out="$( (guard_dirty_data 1 "stop") 2>&1 )"
    rc="$?"
    assert_equal "a clean device passes" "0" "${rc}"

    # Without a terminal, a confirmation must abort rather than assume yes.
    out="$( (confirm "Really?") </dev/null 2>&1 )"
    rc="$?"
    assert_equal "confirm aborts without a terminal" "1" "${rc}"
    if [[ "${out}" == *"--yes"* ]]; then
        report 1 "confirm points at --yes" ""
    else
        report 0 "confirm points at --yes" "got: ${out}"
    fi

    ASSUME_YES=1
    if (confirm "Really?") </dev/null >/dev/null 2>&1; then
        report 1 "--yes confirms non-interactively" ""
    else
        report 0 "--yes confirms non-interactively" "still refused"
    fi
    ASSUME_YES=0
}

# The guards of "make" decide whether a device gets formatted, so they are
# checked against real block devices rather than against the fixture. That
# needs root and loop device support, so the whole block is skipped when
# either is missing.
test_device_guards() {
    local img="${WORKDIR}/loop.img"
    local loop out rc

    if [ "$(id -u)" -ne 0 ] || ! command -v losetup >/dev/null 2>&1; then
        tmsg "skip device guard tests: not root or no losetup"
        return 0
    fi
    dd if=/dev/zero of="${img}" bs=1M count=16 status=none 2>/dev/null || return 0
    loop="$(losetup -f --show "${img}" 2>/dev/null)" || {
        tmsg "skip device guard tests: no loop device available"
        return 0
    }

    SYSFS_ROOT=/sys
    LIVE_SYSTEM=1
    FORCE=0
    DO_WIPE=0

    # An empty device is the one case that must pass.
    out="$( (guard_fresh_device "${loop}" "cache device") 2>&1 )"
    rc="$?"
    assert_equal "an empty device is accepted" "0" "${rc}"

    # A device carrying a filesystem must be refused by name.
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        mkfs.ext4 -q "${loop}" >/dev/null 2>&1
        out="$( (guard_fresh_device "${loop}" "cache device") 2>&1 )"
        rc="$?"
        assert_equal "a formatted device is refused" "1" "${rc}"
        if [[ "${out}" == *"ext4 signature"* ]]; then
            report 1 "the refusal names the filesystem" ""
        else
            report 0 "the refusal names the filesystem" "got: ${out}"
        fi

        # lsblk reports nothing without a populated udev database, so this
        # also proves the signature comes from a direct probe.
        FORCE=1
        out="$( (guard_fresh_device "${loop}" "cache device") 2>&1 )"
        rc="$?"
        assert_equal "--force overrides the signature" "0" "${rc}"
        FORCE=0
        wipefs -a "${loop}" >/dev/null 2>&1
    fi

    # A mounted device must be refused whatever else is true of it.
    out="$( (guard_fresh_device "/dev/$(findmnt -no SOURCE / | xargs -r basename)" "cache device") 2>&1 )"
    rc="$?"
    if [ "${rc}" -eq 1 ] && [[ "${out}" == *"mounted on"* ]]; then
        report 1 "a mounted device is refused" ""
    else
        report 0 "a mounted device is refused" "rc=${rc}, got: ${out}"
    fi

    losetup -d "${loop}" >/dev/null 2>&1
    rm -f -- "${img}"
    SYSFS_ROOT="${WORKDIR}/sysfs"
    LIVE_SYSTEM=0
}

# ==========================================================================
# Main
# ==========================================================================

main() {
    local created=0

    if [ ! -x "${BCACHEMGMT}" ]; then
        printf '%s: not executable: %s\n' "${SCRIPT_NAME}" "${BCACHEMGMT}" >&2
        exit 1
    fi

    if [ -z "${WORKDIR}" ]; then
        WORKDIR="$(mktemp -d -t bcachemgmt-tests.XXXXXX)"
        created=1
    else
        mkdir -p "${WORKDIR}"
    fi
    tmsg "working directory: ${WORKDIR}"

    "${TESTS_DIR}/make-fixture.sh" --dir "${WORKDIR}/sysfs" >/dev/null

    # Every invocation reads the fixture, never the real system, and never a
    # configuration file that happens to exist on the test machine.
    COMMON=(--sysfs-root "${WORKDIR}/sysfs" --no-color --config none)

    test_reporting
    test_diff
    test_config_validation
    test_write_refusals
    test_set_cache_mode
    test_precedence

    # The white box tests replace this shell's globals, so they run last.
    load_script
    test_size_normalization
    test_collection
    test_write_path
    test_set_cache_mode_write
    test_guards
    test_device_guards

    printf '\n%d test(s) run, %d failed\n' "${TESTS_RUN}" "${TESTS_FAILED}"

    if [ "${created}" -eq 1 ] && [ "${KEEP}" != "1" ]; then
        rm -rf -- "${WORKDIR}"
    elif [ "${KEEP}" = "1" ]; then
        printf 'working directory kept: %s\n' "${WORKDIR}"
    fi

    [ "${TESTS_FAILED}" -eq 0 ]
}

main
