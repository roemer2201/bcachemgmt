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
# Version: 2.0.1  (2026-09-25)

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

# The reporting command must keep working exactly as before, including its
# exit code, because monitoring uses it.
test_reporting() {
    assert_status "version exits 0" 0 "${BCACHEMGMT}" version
    assert_output_contains "version prints the version" "bcachemgmt 2."

    assert_status "help exits 0" 0 "${BCACHEMGMT}" help
    assert_output_contains "help lists the set-cache-mode command" "set-cache-mode"
    assert_output_contains "help lists the attach command" "attach"
    assert_output_contains "help lists the detach command" "detach"
    assert_output_lacks "help no longer lists doctor" "doctor"

    assert_status "unknown command exits 2" 2 "${BCACHEMGMT}" nonsense
    assert_status "a removed command exits 2" 2 "${BCACHEMGMT}" doctor "${COMMON[@]}"
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

    assert_status "status --long exits 0" 0 "${BCACHEMGMT}" status "${COMMON[@]}" --long
    assert_output_contains "long mode prints the details" "DETAILS"

    assert_status "status --json exits 0" 0 "${BCACHEMGMT}" status "${COMMON[@]}" --json
    assert_output_contains "json contains the cache mode" '"cache_mode": "writeback"'
}

# Nothing may be written while the tool is pointed at a captured tree, and a
# dry run must describe every write it would have made.
test_write_refusals() {
    local before after

    assert_status "attach refuses a captured sysfs tree" 1 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" bcache1
    assert_output_contains "attach explains the refusal" "refusing to modify devices"
    assert_status "detach refuses a captured sysfs tree" 1 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" bcache0
    assert_output_contains "detach explains the refusal" "refusing to modify devices"

    # A dry run must leave the tree untouched, and not only in content:
    # comparing modification times catches a write path that forgot
    # --dry-run even when it happens to write the value that was already
    # there, which a content check would not notice. The suite runs as root
    # often enough that making the tree read-only would prove nothing, so the
    # timestamps are the evidence.
    before="$(tree_state)"
    "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run --stop --force bcache0 >/dev/null 2>&1
    "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run --stop bcache1 >/dev/null 2>&1
    "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run --cache-mode writeback bcache1 >/dev/null 2>&1
    "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode none all >/dev/null 2>&1
    after="$(tree_state)"
    assert_equal "no dry run touched a single file" "${before}" "${after}"

    # The commands that need a device must say so instead of doing nothing.
    assert_status "attach without a device exits 2" 2 "${BCACHEMGMT}" attach "${COMMON[@]}"
    assert_status "detach without a device exits 2" 2 "${BCACHEMGMT}" detach "${COMMON[@]}"

    assert_status "an unknown device is reported" 1 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run nosuchdevice
    assert_output_contains "the unknown device is named" "no bcache backing device matches 'nosuchdevice'"

    # -B formats a disk, so it must not be accepted where it would be ignored.
    assert_status "-B outside attach exits 2" 2 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run -B /dev/sdz bcache0
    assert_output_contains "the misplaced -B is named" "belongs to 'attach'"
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

    # The mode is settable by environment variable like every other option,
    # and the short option works as well.
    assert_status "the mode can come from the environment" 0 \
        env BCACHEMGMT_CACHE_MODE=none "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run bcache0
    assert_output_contains "the environment value is used" "to 'none'"
    assert_status "the short option -m works" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" -n -m writearound bcache0
    assert_output_contains "the short option value is used" "to 'writearound'"

    # The mode is persistent, so the old advice to re-apply it at boot must
    # be gone.
    assert_output_lacks "no reboot advice any more" "runtime setting"

    # And none of it may have touched a single byte of the fixture.
    before="$(tree_state)"
    "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --verbose --cache-mode none all \
        >/dev/null 2>&1
    after="$(tree_state)"
    assert_equal "set-cache-mode --dry-run wrote nothing" "${before}" "${after}"
}

# Addressing a whole cache set in one call. The fixture has bcache0 attached
# to the cache set and bcache1 attached to nothing, so a --cache-set run that
# reaches only bcache0 proves the selection really follows the set instead of
# behaving like "all".
test_set_cache_mode_cache_set() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"
    local before after

    assert_status "set-cache-mode --cache-set exits 0" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run \
        --cache-mode writethrough --cache-set "${uuid}"
    assert_output_contains "the cache set is named" "Cache set ${uuid}"
    assert_output_contains "the number of members is named" "1 attached backing device(s)"
    assert_output_contains "the member is changed" \
        "would have set cache_mode of bcache0 (/dev/sdb1) from 'writeback' to 'writethrough'"
    assert_output_lacks "the unattached device is left alone" "cache_mode of bcache1"

    # A cache device stands in for its set, so the SSD path an operator has
    # in front of them is enough to address everything it caches.
    assert_status "a cache device names the set" 0 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run \
        --cache-mode writearound -c /dev/nvme0n1p1
    assert_output_contains "the resolved set is named" "Cache set ${uuid}"

    # Like every other option it is settable from the environment.
    assert_status "the cache set can come from the environment" 0 \
        env "BCACHEMGMT_CACHE_SET=${uuid}" "${BCACHEMGMT}" set-cache-mode \
        "${COMMON[@]}" --dry-run --cache-mode none
    assert_output_contains "the environment value is used" "Cache set ${uuid}"

    assert_status "an unknown cache set exits 1" 1 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run \
        --cache-mode none --cache-set nosuchset
    assert_output_contains "the unknown cache set is named" "no cache set matches 'nosuchset'"

    # Mixing the two ways of naming targets is a usage error, not a silent
    # decision in favour of one of them.
    assert_status "--cache-set with a device exits 2" 2 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run \
        --cache-mode none --cache-set "${uuid}" bcache0
    assert_output_contains "the conflict is explained" \
        "either --cache-set or device arguments, not both"

    # The missing-device message has to offer the cache set as a way out.
    assert_status "set-cache-mode without a target exits 2" 2 \
        "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --cache-mode none
    assert_output_contains "the cache set is offered" "--cache-set UUID"

    before="$(tree_state)"
    "${BCACHEMGMT}" set-cache-mode "${COMMON[@]}" --dry-run --verbose \
        --cache-mode none --cache-set "${uuid}" >/dev/null 2>&1
    after="$(tree_state)"
    assert_equal "the cache set dry run wrote nothing" "${before}" "${after}"
}

# Adding a registered backing device to a cache set, reviewed as a dry run.
test_attach() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"

    assert_status "attach --dry-run exits 0" 0 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run bcache1
    assert_output_contains "the attach is described" \
        "would have attached /dev/sdc1 (bcache1) to cache set ${uuid}"

    # With exactly one cache set it is found automatically; naming it by its
    # cache device must lead to the same set.
    assert_status "attach to a named cache set exits 0" 0 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run --cache-set /dev/nvme0n1p1 bcache1
    assert_output_contains "the named set is used" "to cache set ${uuid}"

    # --cache-mode sets the mode of the attached device in the same run.
    assert_status "attach with a cache mode exits 0" 0 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run --cache-mode writeback bcache1
    assert_output_contains "the mode is set after attaching" \
        "would have set cache_mode of bcache1 (/dev/sdc1) from 'writethrough' to 'writeback'"
    assert_output_lacks "the device is not reported as uncached" "no cache attached"

    assert_status "an attached device is a no-op" 0 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run bcache0
    assert_output_contains "the no-op is named" "bcache0: already attached"

    # A fresh disk must pass the guards; one that does not exist cannot.
    assert_status "a missing fresh disk is refused" 1 \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run -B /dev/nosuchdisk
    assert_output_contains "the missing disk is named" "device does not exist: /dev/nosuchdisk"

    # The fresh disks can come from the environment as a comma separated
    # list, and the guard still sees each of them.
    assert_status "fresh disks can come from the environment" 1 \
        env BCACHEMGMT_BACKING="/dev/nosuchdisk1, /dev/nosuchdisk2" \
        "${BCACHEMGMT}" attach "${COMMON[@]}" --dry-run
    assert_output_contains "the first listed disk is checked" "/dev/nosuchdisk1"

    # The variable belongs to "attach" only; exported in a shell it must not
    # break the other commands.
    assert_status "the variable does not affect status" 0 \
        env BCACHEMGMT_BACKING=/dev/nosuchdisk1 "${BCACHEMGMT}" status "${COMMON[@]}"
}

# Removing a backing device from its cache set, with and without --stop.
test_detach() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"

    assert_status "detach --dry-run exits 0" 0 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run bcache0
    assert_output_contains "the detach is described" \
        "would have detached /dev/sdb1 (bcache0) from cache set ${uuid}"
    assert_output_lacks "without --stop nothing is stopped" "stopped"

    assert_status "detach --stop --dry-run exits 0" 0 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run --stop bcache0
    assert_output_contains "the detach comes first" "would have detached /dev/sdb1"
    assert_output_contains "the stop follows" "would have stopped bcache device bcache0 on /dev/sdb1"

    # An uncached device has nothing to detach; --stop still stops it.
    assert_status "detach of an uncached device exits 0" 0 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run bcache1
    assert_output_contains "the no-op is named" "bcache1: no cache attached, nothing to detach"
    assert_status "stop of an uncached device exits 0" 0 \
        "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run --stop bcache1
    assert_output_contains "the uncached device is stopped" "would have stopped bcache device bcache1"

    assert_status "--stop can come from the environment" 0 \
        env BCACHEMGMT_STOP=1 "${BCACHEMGMT}" detach "${COMMON[@]}" --dry-run bcache1
    assert_output_contains "the environment value is used" "would have stopped"
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

# Forget the collected state and read the fixture again.
recollect() {
    BDEV=(); BDEV_ORDER=(); CDEV=(); CDEV_ORDER=(); CSET=(); CSET_ORDER=()
    FLASH_VOLUMES=(); REGISTERED=()
    collect_state
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

    # The block size handed to make-bcache for a fresh disk comes from here.
    assert_equal "the cache set block size is read in bytes" "512" \
        "$(cache_set_block_bytes 5a3c1f2e-8b7d-4c11-9a2f-000000000001)"
}

# The write half of "set-cache-mode", exercised one level below the guard
# that refuses a captured tree. It must write cache_mode and nothing else,
# and it must recognize a device that is already in the wanted mode.
test_set_cache_mode_write() {
    local before after neighbour

    recollect
    neighbour="$(cat "${WORKDIR}/sysfs/block/sdb/sdb1/bcache/writeback_percent")"

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
    # aimed at the wrong path would most plausibly hit, so an unchanged value
    # proves the write stayed where it belongs.
    assert_equal "the neighbouring attribute is untouched" "${neighbour}" \
        "$(cat "${WORKDIR}/sysfs/block/sdb/sdb1/bcache/writeback_percent")"
}

# The write half of "attach" and "detach --stop". The kernel reacts to these
# writes by creating or removing links, which a captured tree cannot do, so
# each test puts the tree into the state the kernel would produce before the
# function starts to wait for it. The waits then return at once instead of
# running into their timeout, and what is left to check is the write itself.
test_attach_detach_write() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"
    local sdc="${WORKDIR}/sysfs/block/sdc/sdc1/bcache"
    local sdb="${WORKDIR}/sysfs/block/sdb/sdb1/bcache"

    recollect
    ASSUME_YES=1

    # attach: bcache1 is uncached in the snapshot, the link already exists.
    ln -s "../../../../fs/bcache/${uuid}" "${sdc}/cache"
    attach_one 1 "${uuid}" >/dev/null
    assert_equal "attach writes the cache set uuid" "${uuid}" "$(cat "${sdc}/attach")"
    assert_equal "attach updates the snapshot" "${uuid}" "${BDEV[1|cache_set]}"

    # detach --stop: bcache0 is attached in the snapshot, the link and the
    # block device are already gone.
    rm -f -- "${sdb}/cache"
    mv "${WORKDIR}/sysfs/block/bcache0" "${WORKDIR}/bcache0.moved"
    DO_STOP=1
    detach_one 0 >/dev/null
    DO_STOP=0
    assert_equal "detach writes 1 to detach" "1" "$(cat "${sdb}/detach")"
    assert_equal "--stop writes 1 to stop"   "1" "$(cat "${sdb}/stop")"

    # Put the fixture back for the tests that follow.
    mv "${WORKDIR}/bcache0.moved" "${WORKDIR}/sysfs/block/bcache0"
    ln -s "../../../../fs/bcache/${uuid}" "${sdb}/cache"
    rm -f -- "${sdc}/cache"
    : >"${sdb}/detach"; : >"${sdb}/stop"; : >"${sdc}/attach"
    ASSUME_YES=0
    recollect
}

# An attach must be verified before the command reports success or logs a
# change. The captured tree does not create the kernel link after a write, so
# replace only the wait to reproduce a link that never appears.
test_attach_verification() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"
    local sdc="${WORKDIR}/sysfs/block/sdc/sdc1/bcache"
    local wrong="${WORKDIR}/sysfs/fs/bcache/00000000-0000-0000-0000-000000000002"
    local out rc

    recollect
    out="$(
        wait_for_condition() { return 1; }
        audit() { printf 'AUDITED: %s\n' "$*"; }
        attach_one 1 "${uuid}" 2>&1
    )"
    rc="$?"
    assert_equal "an unverified attach exits non-zero" "1" "${rc}"
    if [[ "${out}" == *"AUDITED:"* ]]; then
        report 0 "an unverified attach is not audited" "got: ${out}"
    else
        report 1 "an unverified attach is not audited" ""
    fi

    # An existing link to a different cache set is not proof of success.
    mkdir -p "${wrong}"
    ln -s "${wrong}" "${sdc}/cache"
    if backing_attached_to_set "${sdc}" "${uuid}"; then
        report 0 "a link to the wrong cache set is refused" "wrong link accepted"
    else
        report 1 "a link to the wrong cache set is refused" ""
    fi
    rm -f -- "${sdc}/cache"
    rmdir -- "${wrong}"
    : >"${sdc}/attach"
    recollect
}

# A cache set with 512-byte blocks can accept a fresh 4Kn backing device only
# if make-bcache is given the larger logical block size. --force must clear
# foreign signatures before it asks make-bcache to format the disk.
test_fresh_format_plan() {
    local uuid="5a3c1f2e-8b7d-4c11-9a2f-000000000001"
    local disk="${WORKDIR}/sysfs/block/sdz"
    local out

    mkdir -p "${disk}/queue" "${disk}/sdz1"
    printf '4096' >"${disk}/queue/logical_block_size"
    : >"${disk}/sdz1/partition"
    assert_equal "partition inherits 4Kn logical block size" "4096" \
        "$(logical_block_bytes /dev/sdz1)"

    NEW_BACKING=(/dev/sdz1)
    DRY_RUN=1
    out="$(format_backing_devices "${uuid}")"
    if [[ "${out}" == *"make-bcache --block 4096 -B /dev/sdz1"* ]]; then
        report 1 "fresh 4Kn disk gets a 4096-byte superblock" ""
    else
        report 0 "fresh 4Kn disk gets a 4096-byte superblock" "got: ${out}"
    fi

    FORCE=1
    out="$(format_backing_devices "${uuid}")"
    if [[ "${out}" == *"wipefs --all --force -- /dev/sdz1"*"make-bcache --block 4096 -B /dev/sdz1"* ]]; then
        report 1 "force wipes signatures before formatting" ""
    else
        report 0 "force wipes signatures before formatting" "got: ${out}"
    fi

    FORCE=0
    DRY_RUN=0
    NEW_BACKING=()
    rm -rf -- "${disk}"
}

# A disk carrying bcache alongside another signature must still require the
# explicit --wipe flag before the --force path can clear all signatures.
test_force_wipe_guard() {
    local out rc

    out="$(
        FORCE=1
        DO_WIPE=0
        wipefs() { printf 'ext4\nbcache\n'; }
        guard_force_wipe_signatures /dev/example 2>&1
    )"
    rc="$?"
    assert_equal "force alone cannot erase a bcache superblock" "1" "${rc}"
    if [[ "${out}" == *"pass --wipe explicitly"* ]]; then
        report 1 "the bcache guard explains --wipe" ""
    else
        report 0 "the bcache guard explains --wipe" "got: ${out}"
    fi
}

# The guards are what stand between "stop the device I am done with" and data
# loss, so each one is checked for the refusal and for the --force override.
test_guards() {
    local out rc
    local holders="${WORKDIR}/sysfs/block/bcache0/holders"

    # A holder such as LVM or LUKS on top of the bcache device means it is in
    # use even when nothing is mounted on it directly.
    mkdir -p "${holders}/dm-0"
    out="$( (guard_device_in_use 0 "stop") 2>&1 )"
    rc="$?"
    assert_equal "a used device is refused" "1" "${rc}"
    if [[ "${out}" == *"in use by dm-0"* ]]; then
        report 1 "the refusal names the holder" ""
    else
        report 0 "the refusal names the holder" "got: ${out}"
    fi

    FORCE=1
    out="$( (guard_device_in_use 0 "stop") 2>&1 )"
    rc="$?"
    assert_equal "--force allows a used device" "0" "${rc}"
    if [[ "${out}" == *"warning"* ]]; then
        report 1 "--force still warns" ""
    else
        report 0 "--force still warns" "got: ${out}"
    fi
    FORCE=0
    rm -rf -- "${holders}"

    # The unused device must pass without --force.
    out="$( (guard_device_in_use 1 "stop") 2>&1 )"
    rc="$?"
    assert_equal "an unused device passes" "0" "${rc}"

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

# A mount on a partition and a holder of that partition both make the base
# bcache device unsafe to stop. Mock only the mount table lookup; the device
# topology itself is traversed through the captured sysfs tree.
test_stacked_device_guards() {
    local partition="${WORKDIR}/sysfs/block/bcache0/bcache0p1"
    local holder="${WORKDIR}/sysfs/block/dm-7"
    local saved_mount_fn out rc

    mkdir -p "${partition}/holders/dm-7" "${holder}"
    : >"${partition}/partition"
    saved_mount_fn="$(declare -f mount_points_of_names)"
    mount_points_of_names() {
        local name
        for name in "$@"; do
            if [ "${name}" = "bcache0p1" ]; then
                printf '/srv/data'
                return 0
            fi
        done
        printf ''
    }

    out="$( (guard_device_in_use 0 stop) 2>&1 )"
    rc="$?"
    assert_equal "a mounted bcache partition blocks stop" "1" "${rc}"
    if [[ "${out}" == *"mounted on /srv/data"* ]]; then
        report 1 "the partition mount is named" ""
    else
        report 0 "the partition mount is named" "got: ${out}"
    fi

    # The mount may instead be on a device-mapper layer above the partition.
    mount_points_of_names() {
        local name
        for name in "$@"; do
            if [ "${name}" = "dm-7" ]; then
                printf '/srv/crypt'
                return 0
            fi
        done
        printf ''
    }
    out="$( (guard_device_in_use 0 stop) 2>&1 )"
    rc="$?"
    assert_equal "a mounted partition holder blocks stop" "1" "${rc}"
    if [[ "${out}" == *"mounted on /srv/crypt"* ]]; then
        report 1 "the holder mount is named" ""
    else
        report 0 "the holder mount is named" "got: ${out}"
    fi

    eval "${saved_mount_fn}"
    out="$( (guard_device_in_use 0 stop) 2>&1 )"
    rc="$?"
    assert_equal "a partition holder blocks stop" "1" "${rc}"
    if [[ "${out}" == *"in use by dm-7"* ]]; then
        report 1 "the partition holder is named" ""
    else
        report 0 "the partition holder is named" "got: ${out}"
    fi

    rm -rf -- "${partition}" "${holder}"
}

# The guards of "attach -B" decide whether a device gets formatted, so they
# are checked against real block devices rather than against the fixture.
# That needs root and loop device support, so the whole block is skipped when
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
    out="$( (guard_fresh_device "${loop}" "backing device") 2>&1 )"
    rc="$?"
    assert_equal "an empty device is accepted" "0" "${rc}"

    # A device carrying a filesystem must be refused by name.
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        mkfs.ext4 -q "${loop}" >/dev/null 2>&1
        out="$( (guard_fresh_device "${loop}" "backing device") 2>&1 )"
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
        out="$( (guard_fresh_device "${loop}" "backing device") 2>&1 )"
        rc="$?"
        assert_equal "--force overrides the signature" "0" "${rc}"
        FORCE=0
        wipefs -a "${loop}" >/dev/null 2>&1
    fi

    # A mounted device must be refused whatever else is true of it.
    out="$( (guard_fresh_device "/dev/$(findmnt -no SOURCE / | xargs -r basename)" "backing device") 2>&1 )"
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

    # Every invocation reads the fixture, never the real system.
    COMMON=(--sysfs-root "${WORKDIR}/sysfs" --no-color)

    test_reporting
    test_write_refusals
    test_set_cache_mode
    test_set_cache_mode_cache_set
    test_attach
    test_detach

    # The white box tests replace this shell's globals, so they run last.
    load_script
    test_size_normalization
    test_collection
    test_set_cache_mode_write
    test_attach_detach_write
    test_attach_verification
    test_fresh_format_plan
    test_force_wipe_guard
    test_guards
    test_stacked_device_guards
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
