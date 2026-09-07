#!/bin/zsh
# Integration test: real fnox, fake 1Password, isolated daemon and references.
emulate -L zsh
setopt err_return no_unset pipe_fail
command -v fnox >/dev/null || { print 'SKIP: fnox is not installed'; exit 0 }
local root="${0:A:h:h}" work
work="$(mktemp -d)"
# Keep user startup files from replacing the fake CLI PATH in child shells.
export ZDOTDIR="$work/zdot"
mkdir -p "$ZDOTDIR"
cleanup() {
    XDG_RUNTIME_DIR="$work/cache/fnox/runtime" FNOX_CONFIG_DIR="$work/cache/fnox/config" FNOX_STATE_DIR="$work/cache/fnox/state" fnox --if-missing error daemon stop >/dev/null 2>&1 || true
    XDG_RUNTIME_DIR="$work/ambient-runtime" fnox --if-missing error daemon stop >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/profiles" "$work/tmp" "$work/ambient-runtime"
export XDG_RUNTIME_DIR="$work/ambient-runtime"
cat > "$work/bin/op" <<'FAKE'
#!/bin/zsh
print -r -- "$1" >> "$OP_FAKE_LOG"
[[ -z "${OP_SESSION:-}${OP_SESSION_test:-}" ]] || exit 7
[[ -e "$OP_FAKE_STATE/fail" ]] && exit 9
case "$1" in
    read) print -rn -- "$(<"$OP_FAKE_STATE/value")" ;;
    inject)
        while IFS= read -r line; do
            print -r -- "${line%%=*}=$(<"$OP_FAKE_STATE/value")"
        done ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$work/bin/op"
print -r -- 'test-fixture-token' > "$work/token"
print -r -- 'first' > "$work/value"
cat > "$work/profiles/agents.env" <<PROFILE
# opgate:token-file $work/token
FIRST=op://test-vault/test-item/first
SECOND=op://test-vault/test-item/second
LABEL='public "label"'
PROFILE
export PATH="$work/bin:$PATH" OPGATE_DIR="$work/profiles" OPGATE_CACHE_DIR="$work/cache"
export TMPDIR="$work/tmp/" OP_FAKE_LOG="$work/op.log" OP_FAKE_STATE="$work"
export OP_SESSION=fixture OP_SESSION_test=fixture
export OPGATE_OP_TIMEOUT=15 OPGATE_RETRY_SECONDS=3600 OPGATE_SESSION_KEY=fnox-test
unset OPGATE_NO_SESSION_CACHE OPGATE_SESSION_CACHE OPGATE_CACHE_TTL_DAYS
# Host startup files can source an installed opgate before fixture setup.
unset _opg_dir _opg_session_dir _opg_session_key_cached _opg_persist_dir _opg_revision
unset _opg_vals _opg_names _opg_kcnames _opg_mtime _opg_hash
source "$root/opgate.zsh"
local pass=0 fail=0 out before
check() {
    if [[ "$2" == "$3" ]]; then
        (( ++pass )); print -r -- "ok    $1"
    else
        (( ++fail )); print -r -- "FAIL  $1: expected [$2] got [$3]"
    fi
}
run_values() {
    opgate exec --profile agents --backend fnox -- /bin/sh -c 'printf "%s|%s|%s|%s" "$FIRST" "$SECOND" "$LABEL" "${OP_SERVICE_ACCOUNT_TOKEN-unset}"'
}
out="$(opgate ls)"
check 'unused fnox listing' yes "$( [[ "$out" == *'fnox: unused'* && "$out" == *'fnox daemon: stopped'* ]] && print yes || print no )"
check 'cold listing makes no provider call' no "$( [[ -e "$work/op.log" ]] && print yes || print no )"
out="$(run_values)"
check 'real fnox resolves and removes resolver token' 'first|first|public "label"|unset' "$out"
check 'one batched request' 1 "$(wc -l < "$work/op.log" | tr -d ' ')"
out="$(opgate ls)"
check 'fnox listing separates native and daemon states' yes "$( [[ "$out" == *'native: cold; fnox: configured'* && "$out" == *'fnox daemon: running;'* ]] && print yes || print no )"
check 'fnox listing reports shared cache limitation' yes "$( [[ "$out" == *'cached entries (shared; per-profile warmth unknown)'* ]] && print yes || print no )"
check 'warm listing makes no provider call' 1 "$(wc -l < "$work/op.log" | tr -d ' ')"
out="$(OPGATE_FNOX_TTL=2 opgate ls)"
check 'changed period marks config stale' yes "$( [[ "$out" == *'fnox: stale config'* ]] && print yes || print no )"
print -r -- 'second' > "$work/value"
out="$(run_values)"
check 'daemon reuses first values' 'first|first|public "label"|unset' "$out"
check 'no second provider request' 1 "$(wc -l < "$work/op.log" | tr -d ' ')"
# The ambient runtime also belongs to this fixture. Its daemon management
# must not touch opgate's dedicated runtime, even when profile options match.
# No default daemon is also valid; clear reports a missing socket in that case.
fnox --if-missing error daemon clear >/dev/null 2>&1 || true
out="$(run_values)"
check 'unrelated daemon clear leaves opgate cache intact' 'first|first|public "label"|unset' "$out"
check 'isolated daemon makes no provider request' 1 "$(wc -l < "$work/op.log" | tr -d ' ')"
# A new process also uses the daemon.
out="$(zsh -c 'source "$1/opgate.zsh"; opgate exec --profile agents --backend fnox -- /bin/sh -c '\''printf %s "$FIRST"'\''' -- "$root")"
check 'cache shared across processes' first "$out"
check 'still one provider request' 1 "$(wc -l < "$work/op.log" | tr -d ' ')"
out="$(opgate exec --profile agents --backend fnox -- /bin/sh -c 'printf "%s:%s" "${OP_SESSION-unset}" "${OP_SESSION_test-unset}"')"
check 'fnox child receives no manual session tokens' 'unset:unset' "$out"
# Child failures must not mark a provider outage.
local rc=0
opgate exec --profile agents --backend fnox -- /bin/sh -c 'exit 7' || rc=$?
check 'child exit preserved' 7 "$rc"
check 'child error does not set backoff' no "$( [[ -e "$work/cache/fnox-agents.v4.retry" ]] && print yes || print no )"
opgate flush
out="$(run_values)"
check 'invalidation fetches changed values' 'second|second|public "label"|unset' "$out"
check 'one additional request' 2 "$(wc -l < "$work/op.log" | tr -d ' ')"
# Changing the cache period gives a different provider cache identity.
print -r -- 'third' > "$work/value"
out="$(OPGATE_FNOX_TTL=2 run_values)"
check 'new time period fetches current value' 'third|third|public "label"|unset' "$out"
# A clear or stop cannot leave a false per-profile warm claim in listing.
XDG_RUNTIME_DIR="$work/cache/fnox/runtime" FNOX_CONFIG_DIR="$work/cache/fnox/config" FNOX_STATE_DIR="$work/cache/fnox/state" FNOX_PROFILE=default fnox --if-missing error daemon clear >/dev/null
out="$(opgate ls)"
check 'cleared daemon has zero shared cache entries' yes "$( [[ "$out" == *'running; 0 cached entries'* ]] && print yes || print no )"
XDG_RUNTIME_DIR="$work/cache/fnox/runtime" FNOX_CONFIG_DIR="$work/cache/fnox/config" FNOX_STATE_DIR="$work/cache/fnox/state" FNOX_PROFILE=default fnox --if-missing error daemon stop >/dev/null
out="$(opgate ls)"
check 'stopped daemon is reported despite existing configs' yes "$( [[ "$out" == *'fnox daemon: stopped'* ]] && print yes || print no )"
# Failed resolves cannot start the child. Later callers share the backoff.
opgate invalidate
touch "$work/fail"
run_values >/dev/null 2>&1 && check 'outage fails' yes no || check 'outage fails' yes yes
before="$(wc -l < "$work/op.log" | tr -d ' ')"
run_values >/dev/null 2>&1 && check 'second outage fails' yes no || check 'second outage fails' yes yes
check 'outage does not repeat provider calls' "$before" "$(wc -l < "$work/op.log" | tr -d ' ')"
# An authentication-only profile must not turn an empty export into an env dump.
print -r -- "# opgate:token-file $work/token" > "$work/profiles/empty.env"
out="$(OPGATE_INHERITED_FIXTURE=not-a-secret opgate exec --profile empty --backend fnox -- /bin/sh -c 'printf child-only')"
# Compare silently: a regression must never print the inherited environment.
check 'empty profile never prints inherited environment' yes "$( [[ "$out" == child-only ]] && print yes || print no )"
print -r -- "passed $pass, failed $fail"
(( fail == 0 ))
