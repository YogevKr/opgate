#!/bin/zsh
# opgate test suite. Uses a fake `op` on PATH — no 1Password account needed.
# Run: zsh test/run.zsh
emulate -L zsh
setopt err_return no_unset pipe_fail

local here="${0:A:h}"
local root="${here:h}"
local work; work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- fake op ---------------------------------------------------------------
# Logs every invocation; `op run` resolves op://x/y/z refs to "resolved:<VAR>"
# and passes plain values through, mimicking the real semantics we rely on.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/op" <<'FAKE'
#!/bin/zsh
emulate -L zsh
print -r -- "argv=$* acct=${OP_ACCOUNT:-} satok=${OP_SERVICE_ACCOUNT_TOKEN:+SET}" >> "$OP_FAKE_LOG"
case "$1" in
    run)
        local envfile arg
        for arg in "$@"; do
            [[ "$arg" == --env-file=* ]] && envfile="${arg#--env-file=}"
        done
        local line var val
        local -a assigns
        while IFS= read -r line; do
            [[ "$line" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]] || continue
            var="${line%%=*}"; val="${line#*=}"
            [[ "$val" == op://* ]] && val="resolved:$var"
            assigns+=("$var=$val")
        done < "$envfile"
        shift; while (( $# )) && [[ "$1" != -- ]]; do shift; done; shift
        env "${assigns[@]}" "$@"
        ;;
    "account") print -r -- "URL  EMAIL  ID"; print -r -- "test.1password.com x y" ;;
    signin) print -r -- "" ;;
esac
FAKE
chmod +x "$work/fakebin/op"

# --- environment -----------------------------------------------------------
export PATH="$work/fakebin:$PATH"
export OP_FAKE_LOG="$work/op.log"
export OPGATE_DIR="$work/profiles"
export TMPDIR="$work/tmp/"          # session tier lands under here
export OPGATE_CACHE_DIR="$work/persist"
export OPGATE_SESSION_KEY="test-session"
unset OPGATE_CACHE_TTL_DAYS OPGATE_SESSION_CACHE OPGATE_NO_SESSION_CACHE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
mkdir -p "$work/tmp" "$work/profiles"

print -r -- "# opgate:account test.1password.com" > "$work/profiles/personal.env"
print -r -- "FOO=op://vault/item/field" >> "$work/profiles/personal.env"
print -r -- "PLAIN=hello" >> "$work/profiles/personal.env"

print -r -- "$work/sa-token-value" > /dev/null
print -r -- "sa-token-value" > "$work/agents.token"
print -r -- "# opgate:token-file $work/agents.token" > "$work/profiles/agents.env"
print -r -- "BAR=op://vault2/item2/field" >> "$work/profiles/agents.env"

# a profile whose op<name> function cannot collide with anything on the host
print -r -- "# opgate:account test.1password.com" > "$work/profiles/gatetest77.env"
print -r -- "BAZ=op://vault3/item3/field" >> "$work/profiles/gatetest77.env"

local pass=0 fail=0
t() {  # t <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( ++pass )); print -r -- "ok    $1"
    else
        (( ++fail )); print -r -- "FAIL  $1: expected [$2] got [$3]"
    fi
}

opcalls() { grep -c '^argv=run' "$OP_FAKE_LOG" 2>/dev/null || print 0 }

# --- tests -----------------------------------------------------------------
source "$root/opgate.zsh"

# 1. resolution + plain passthrough
t "resolves op:// ref"    "resolved:FOO" "$(opgate personal /bin/sh -c 'echo $FOO')"
t "plain value passes"    "hello"        "$(opgate personal /bin/sh -c 'echo $PLAIN')"

# 2. account mode sets OP_ACCOUNT
t "account mode" "1" "$(grep -c 'argv=run.*acct=test.1password.com' "$OP_FAKE_LOG")"

# 3. memory tier: second call, same shell, no new op invocation
local before; before="$(opcalls)"
t "memory cache value" "resolved:FOO" "$(opgate personal /bin/sh -c 'echo $FOO')"
t "memory cache hits"  "$before" "$(opcalls)"

# 4. session tier: fresh shell, same session key -> no new op invocation
before="$(opcalls)"
local out
out="$(zsh -c "source '$root/opgate.zsh'; opgate personal /bin/sh -c 'echo \$FOO'")"
t "session cache value" "resolved:FOO" "$out"
t "session cache hits"  "$before" "$(opcalls)"

# 5. token-file mode: OP_SERVICE_ACCOUNT_TOKEN set, OP_ACCOUNT not
t "token mode value" "resolved:BAR" "$(opgate agents /bin/sh -c 'echo $BAR')"
t "token mode env"   "1" "$(grep -c 'argv=run.*acct= satok=SET' "$OP_FAKE_LOG")"

# 6. read: cache-only, prefers warm cache, no op invocation
before="$(opcalls)"
t "read from cache" "resolved:BAR" "$(opgate read BAR)"
t "read is op-free" "$before" "$(opcalls)"

# 7. mtime invalidation: touching the env file forces a re-resolve
sleep 1; touch "$work/profiles/personal.env"
before="$(opcalls)"
opgate personal /usr/bin/true
t "mtime invalidates" "$(( before + 1 ))" "$(opcalls)"

# 8. flush: drops session cache -> next fresh-shell call re-resolves
opgate flush
before="$(opcalls)"
zsh -c "source '$root/opgate.zsh'; opgate personal /usr/bin/true"
t "flush forces re-resolve" "$(( before + 1 ))" "$(opcalls)"

# 9. secrets never land in the ambient environment of this shell
t "no ambient export" "" "${FOO:-}"

# 10. unknown profile errors cleanly
out="$(opgate nosuch /usr/bin/true 2>&1)" && t "unknown profile rc" "nonzero" "zero" \
    || t "unknown profile rc" "nonzero" "nonzero"

# 11. convenience functions defined on source (host-collision-proof name)
t "op<profile> function" "resolved:BAZ" "$(opgatetest77 /bin/sh -c 'echo $BAZ')"

# 12. bin/opgate standalone path (no sourced functions)
t "bin shim" "resolved:BAR" "$("$root/bin/opgate" agents /bin/sh -c 'echo $BAR')"

# 13. ls shows both profiles
out="$(opgate ls)"
[[ "$out" == *personal* && "$out" == *agents* ]] \
    && t "ls lists profiles" "yes" "yes" || t "ls lists profiles" "yes" "no"

print
print -r -- "passed $pass, failed $fail"
(( fail == 0 ))
