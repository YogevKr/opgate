#!/bin/zsh
# Discovery must not resolve secrets, authenticate, or mutate caches.
emulate -L zsh
setopt err_return no_unset pipe_fail
local root="${0:A:h:h}" work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export ZDOTDIR="$work/zdot" OPGATE_DIR="$work/profiles" OPGATE_CACHE_DIR="$work/cache"
export TMPDIR="$work/tmp/" DISCOVERY_LOG="$work/calls"
mkdir -p "$ZDOTDIR" "$OPGATE_DIR" "$TMPDIR" "$work/bin" "$OPGATE_CACHE_DIR"
cat > "$work/bin/op" <<'FAKE'
#!/bin/zsh
print -r -- "op:${*}:account=${OP_ACCOUNT-unset}:token=${OP_SERVICE_ACCOUNT_TOKEN-unset}:session=${OP_SESSION-unset}:${OP_SESSION_test-unset}" >> "$DISCOVERY_LOG"
case "$*" in
    'account list'*) print 'configured-accounts'; exit "${DISCOVERY_ACCOUNT_RC:-0}" ;;
    *--help|*-h) print 'native-help'; exit "${DISCOVERY_HELP_RC:-0}" ;;
    *) exit 90 ;;
esac
FAKE
cat > "$work/bin/fnox" <<'FAKE'
#!/bin/zsh
print -r -- "fnox:${*}:runtime=${XDG_RUNTIME_DIR}:profile=${FNOX_PROFILE}:token=${OP_SERVICE_ACCOUNT_TOKEN-unset}" >> "$DISCOVERY_LOG"
[[ "${DISCOVERY_STATUS:-}" == hang ]] && sleep 10
print 'fnox daemon not running'
FAKE
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
export OP_ACCOUNT=wrong OP_SERVICE_ACCOUNT_TOKEN=wrong OP_SESSION=wrong OP_SESSION_test=wrong FNOX_PROFILE=wrong
# No token exists: metadata and help must not need one.
print -r -- "# opgate:token-file $work/missing-token" > "$OPGATE_DIR/agent.env"
print 'TOKEN=op://vault/item/field' >> "$OPGATE_DIR/agent.env"
print -r -- '# opgate:account personal.example' > "$OPGATE_DIR/personal.env"
unset _opg_dir _opg_session_dir _opg_session_key_cached _opg_persist_dir _opg_revision
unset _opg_vals _opg_names _opg_kcnames _opg_mtime _opg_hash
source "$root/opgate.zsh"
local pass=0 fail=0 out rc before mode
check() {
    if [[ "$2" == "$3" ]]; then (( ++pass )); print -r -- "ok    $1"
    else (( ++fail )); print -r -- "FAIL  $1: expected [$2] got [$3]"; fi
}
for mode in exec op session accounts account ls list init read approve flush invalidate keychain version help; do
    out="$(opgate "$mode" --help)"
    check "$mode has help" yes "$( [[ "$out" == usage:* ]] && print yes || print no )"
    check "$mode help topic matches" "$out" "$(opgate help "$mode")"
done
check 'help never calls a provider' no "$( [[ -e "$DISCOVERY_LOG" ]] && print yes || print no )"
check 'help does not invalidate caches' no "$( [[ -e "$OPGATE_CACHE_DIR/revision" ]] && print yes || print no )"
check 'help after profile needs no token' "$(opgate help exec)" "$(opgate exec --profile missing --help)"
opgate help unknown >/dev/null 2>&1 && rc=0 || rc=$?
check 'unknown help topic fails' 2 "$rc"

out="$(opgate accounts)"
check 'accounts metadata' configured-accounts "$out"
check 'accounts scrubs inherited credentials' 'op:account list:account=unset:token=unset:session=unset:unset' "$(tail -1 "$DISCOVERY_LOG")"
check 'account list alias' "$out" "$(opgate account list)"
check 'scoped account list needs no service token' "$out" "$(opgate op --profile agent -- account list)"
check 'accounts JSON option' "$out" "$(opgate accounts --format json)"
check 'account ls equals-format option' "$out" "$(opgate account ls --format=table)"
check 'table maps to native human-readable format' 'op:account list --format=human-readable:account=unset:token=unset:session=unset:unset' "$(tail -1 "$DISCOVERY_LOG")"
opgate accounts --format table >/dev/null
check 'split table format maps to native format' 'op:account list --format human-readable:account=unset:token=unset:session=unset:unset' "$(tail -1 "$DISCOVERY_LOG")"
DISCOVERY_ACCOUNT_RC=8 opgate accounts >/dev/null 2>&1 && rc=0 || rc=$?
check 'accounts preserves native failure' 8 "$rc"
before="$(wc -l < "$DISCOVERY_LOG")"
opgate accounts --account other >/dev/null 2>&1 && rc=0 || rc=$?
check 'accounts rejects account overrides' 2 "$rc"
opgate accounts --format=json --account other >/dev/null 2>&1 && rc=0 || rc=$?
check 'accounts validates all options' 2 "$rc"
opgate op --profile agent -- account forget >/dev/null 2>&1 && rc=0 || rc=$?
check 'account mutation rejected' 2 "$rc"
check 'invalid discovery never calls op' "$before" "$(wc -l < "$DISCOVERY_LOG")"

check 'native item help without profile' native-help "$(opgate op -- item create --help)"
check 'native help with missing profile' native-help "$(opgate op --profile missing -- item create --help)"
check 'native help removes credentials' 'op:item create --help:account=unset:token=unset:session=unset:unset' "$(tail -1 "$DISCOVERY_LOG")"
check 'native help does not invalidate' no "$( [[ -e "$OPGATE_CACHE_DIR/revision" ]] && print yes || print no )"
DISCOVERY_HELP_RC=7 opgate op --profile agent -- item create --help >/dev/null 2>&1 && rc=0 || rc=$?
check 'native help failure is preserved' 7 "$rc"
check 'failed native help does not invalidate' no "$( [[ -e "$OPGATE_CACHE_DIR/revision" ]] && print yes || print no )"
opgate op --profile agent -- item create --title --help >/dev/null 2>&1 && rc=0 || rc=$?
check 'help-like item title still requires authentication' 1 "$rc"
# Clear only the revision created by the rejected write above.
rm -f "$OPGATE_CACHE_DIR/revision"
out="$(opgate exec --profile missing -- /bin/echo --help 2>&1)" && rc=0 || rc=$?
check 'child help cannot bypass profile validation' 1 "$rc"

before="$(grep -c '^op:' "$DISCOVERY_LOG")"
out="$(opgate ls)"
check 'listing labels native cache' yes "$( [[ "$out" == *'native: cold'* ]] && print yes || print no )"
check 'listing labels unused fnox' yes "$( [[ "$out" == *'fnox: unused'* ]] && print yes || print no )"
check 'listing labels stopped daemon' yes "$( [[ "$out" == *'fnox daemon: stopped'* ]] && print yes || print no )"
check 'listing makes no 1Password requests' "$before" "$(grep -c '^op:' "$DISCOVERY_LOG")"
check 'listing creates no fnox configuration' no "$( [[ -e "$OPGATE_CACHE_DIR/fnox/config" ]] && print yes || print no )"
check 'status uses isolated runtime and removes token' yes "$( [[ "$(tail -1 "$DISCOVERY_LOG")" == *"runtime=$OPGATE_CACHE_DIR/fnox/runtime:profile=default:token=unset" ]] && print yes || print no )"
out="$(DISCOVERY_STATUS=hang opgate ls)"
check 'unresponsive daemon cannot block listing' yes "$( [[ "$out" == *'fnox daemon: unavailable'* ]] && print yes || print no )"
# A listing and a resolver can run in sibling subshells with the same zsh PID.
# Their bounded captures must never exchange or remove each other's output.
( _opg_capture /bin/sh -c 'printf first-capture; sleep 1'; print -rn -- "$REPLY" > "$work/first-result" ) &
local first_pid=$!
( _opg_capture /bin/sh -c 'printf second-capture'; print -rn -- "$REPLY" > "$work/second-result" ) &
local second_pid=$!
wait "$first_pid" || true
wait "$second_pid" || true
check 'concurrent first capture is isolated' first-capture "$(<"$work/first-result")"
check 'concurrent second capture is isolated' second-capture "$(<"$work/second-result")"
print -r -- "passed $pass, failed $fail"
(( fail == 0 ))
