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
# and passes plain values through. The env-file value rules below were measured
# against the real op 2.x and must stay in step with _opg_parse — an indulgent
# fake here is how a parser divergence reaches a real profile.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/op" <<'FAKE'
#!/bin/zsh
emulate -L zsh
setopt extended_glob
print -r -- "argv=$* acct=${OP_ACCOUNT:-} satok=${OP_SERVICE_ACCOUNT_TOKEN:+SET}" >> "$OP_FAKE_LOG"
case "$1" in
    run)
        # Outage knobs for the failure-posture tests: OP_FAKE_FAIL simulates a
        # rate-limited account, OP_FAKE_HANG a resolver that never answers.
        [[ -n "${OP_FAKE_FAIL:-}" ]] && { print -u2 -- "op: too many requests (fake)"; exit 9 }
        (( ${OP_FAKE_HANG:-0} )) && sleep "$OP_FAKE_HANG"
        local envfile arg
        for arg in "$@"; do
            [[ "$arg" == --env-file=* ]] && envfile="${arg#--env-file=}"
        done
        local line var raw val
        local -a assigns
        while IFS= read -r line; do
            [[ "$line" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]] || continue
            var="${line%%=*}"
            raw="${${line#*=}##[[:blank:]]#}"
            if [[ "$raw" == \"*\"* ]]; then                 # double: expands
                val="${(e)${${raw#\"}%%\"*}}"
            elif [[ "$raw" == \'*\'* ]]; then               # single: literal
                val="${${raw#\'}%%\'*}"
            else                                            # bare: # ends it
                val="${(e)${${raw%%\#*}%%[[:blank:]]#}}"
            fi
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

# --- fake security ---------------------------------------------------------
# One file per <service>/<account> under $KC_STORE, so the suite runs on Linux
# and never touches the real login keychain on macOS. It reproduces the real
# binary's one trap faithfully: `-w` prints the password raw only when every
# byte is printable ASCII, and lowercase hex otherwise, while `-g` marks real
# hex with an 0x prefix on stderr. Verified against security(1) on macOS 15.
cat > "$work/fakebin/security" <<'FAKE'
#!/bin/zsh
emulate -L zsh
local cmd="$1"; shift
# Records what actually reached argv. The point of the stdin write path is that a
# secret never lands here, where any same-user `ps` could read it; asserting that
# needs the real argument vector, not the parsed result.
[[ -n "${SECURITY_ARGV_LOG:-}" ]] && print -r -- "$cmd $*" >> "$SECURITY_ARGV_LOG"
local svc="" acct="" val="" want_w=0 want_g=0
while (( $# )); do
    case "$1" in
        -s) svc="$2"; shift 2 ;;
        -a) acct="$2"; shift 2 ;;
        -j|-l) shift 2 ;;
        -w) if [[ -n "${2:-}" && "$2" != -* ]]; then val="$2"; shift 2; else want_w=1; shift; fi ;;
        -g) want_g=1; shift ;;
        -U|-A) shift ;;
        *) shift ;;
    esac
done
local item="$KC_STORE/${svc}%${acct}"
mkdir -p "$KC_STORE"
# printable-ASCII-only decides raw vs hex, exactly as security(1) does
needs_hex() { [[ "$1" == *[^\ -~]* ]] }
tohex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n' }
case "$cmd" in
    add-generic-password)
        # Bare -w makes the real security(1) prompt, and it takes the value from
        # stdin twice and confirms the two match. That path is line-based, so a
        # value carrying a newline fails its own retype check — reproduced here,
        # because opgate leans on exactly that split: single-line secrets go over
        # stdin to stay out of argv, multiline ones have nowhere else to go.
        if (( want_w )); then
            local first second
            IFS= read -r first || { print -u2 "security: no password supplied"; exit 1 }
            IFS= read -r second || second=""
            [[ "$first" == "$second" ]] || { print -u2 "passwords don't match"; exit 1 }
            val="$first"
        fi
        printf '%s' "$val" > "$item" ;;
    find-generic-password)
        [[ -r "$item" ]] || { print -u2 "security: SecKeychainSearchCopyNext: not found"; exit 44 }
        local stored; stored="$(cat "$item"; printf X)"; stored="${stored%X}"
        if (( want_g )); then
            print -r -- "svc=$svc"
            if needs_hex "$stored"; then
                print -u2 -r -- "password: 0x$(tohex "$stored" | tr 'a-f' 'A-F')  \"...\""
            else
                print -u2 -r -- "password: \"$stored\""
            fi
        elif (( want_w )); then
            needs_hex "$stored" && print -r -- "$(tohex "$stored")" || print -r -- "$stored"
        else
            print -r -- "svc=$svc"
        fi
        ;;
    delete-generic-password)
        [[ -e "$item" ]] || { print -u2 "security: not found"; exit 44 }
        rm -f "$item" ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$work/fakebin/security"

# --- environment -----------------------------------------------------------
export PATH="$work/fakebin:$PATH"
export OP_FAKE_LOG="$work/op.log"
export OPGATE_DIR="$work/profiles"
export TMPDIR="$work/tmp/"          # session tier lands under here
export OPGATE_CACHE_DIR="$work/persist"
export OPGATE_SESSION_KEY="test-session"
export KC_STORE="$work/keychain"
export SECURITY_ARGV_LOG="$work/security-argv.log"
export OPGATE_KEYCHAIN_ACCOUNT="testuser"
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

# keychain-only profile, and one mixing both sources
mkdir -p "$KC_STORE"
printf 'kc-secret' > "$KC_STORE/local-key%testuser"
printf 'kc-scoped' > "$KC_STORE/svc2%bob"

print -r -- "KCONLY=keychain://local-key"          > "$work/profiles/kconly.env"
print -r -- "KCACCT=keychain://svc2/bob"          >> "$work/profiles/kconly.env"

print -r -- "# opgate:account test.1password.com"  > "$work/profiles/mixed.env"
print -r -- "MIXOP=op://vault/item/field"         >> "$work/profiles/mixed.env"
print -r -- "MIXKC=keychain://local-key"          >> "$work/profiles/mixed.env"

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

# 7. a touch alone no longer costs a resolve: the mtime check misses, the
#    content hash revalidates the blob and heals the recorded mtime. An
#    actual edit still invalidates through the hash.
sleep 1; touch "$work/profiles/personal.env"
before="$(opcalls)"
opgate personal /usr/bin/true
t "touch revalidates by hash" "$before" "$(opcalls)"
sleep 1; print -r -- "PLAIN2=hello2" >> "$work/profiles/personal.env"
before="$(opcalls)"
opgate personal /usr/bin/true
t "content change invalidates" "$(( before + 1 ))" "$(opcalls)"

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

# --- keychain source -------------------------------------------------------

# 14. keychain refs resolve, both the bare and the explicit-account form
t "keychain resolves"        "kc-secret" "$(opgate kconly /bin/sh -c 'echo $KCONLY')"
t "keychain explicit acct"   "kc-scoped" "$(opgate kconly /bin/sh -c 'echo $KCACCT')"

# 15. a keychain-only profile never invokes op — that is what makes it usable
#     with no account, no network and no op installed at all
before="$(opcalls)"
opgate flush
zsh -c "source '$root/opgate.zsh'; opgate kconly /usr/bin/true"
t "keychain-only is op-free" "$before" "$(opcalls)"

# 16. mixed profile: both sources land in the same environment, one op call
before="$(opcalls)"
t "mixed op half" "resolved:MIXOP" "$(opgate mixed /bin/sh -c 'echo $MIXOP')"
t "mixed kc half" "kc-secret"      "$(opgate mixed /bin/sh -c 'echo $MIXKC')"
t "mixed op calls" "$(( before + 1 ))" "$(opcalls)"

# 17. the security property: keychain values are never written to a cache file.
#     The op-sourced half of the same profile is cached as usual.
out="$(cat "$work/tmp/opgate-session/test-session.mixed" 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ "$(grep -rl 'kc-secret' "$work/tmp" "$work/persist" 2>/dev/null | wc -l | tr -d ' ')" == 0 ]] \
    && t "keychain value uncached" "yes" "yes" || t "keychain value uncached" "yes" "no"
grep -q 'MIXOP' "$work/tmp/opgate-session/test-session.mixed" 2>/dev/null \
    && t "op value still cached" "yes" "yes" || t "op value still cached" "yes" "no"

# 18. read serves keychain values live, still without invoking op
before="$(opcalls)"
t "read keychain var"  "kc-secret" "$(opgate read KCONLY)"
t "read stays op-free" "$before"   "$(opcalls)"

# 19. a missing item fails with a pointer to the fix, not a silent empty value
out="$(opgate kconly /usr/bin/true 2>&1)"   # warm first, then break it
rm -f "$KC_STORE/local-key%testuser"
opgate flush
out="$(zsh -c "source '$root/opgate.zsh'; opgate kconly /usr/bin/true" 2>&1)" \
    && t "missing item rc" "nonzero" "zero" || t "missing item rc" "nonzero" "nonzero"
[[ "$out" == *"keychain set"* ]] && t "missing item hint" "yes" "yes" || t "missing item hint" "yes" "no"

# 20. keychain set|ls|rm round-trip
print -rn -- "written-value" | opgate keychain set local-key >/dev/null
t "keychain set round-trip" "written-value" "$(opgate kconly /bin/sh -c 'echo $KCONLY')"
out="$(opgate keychain ls)"
[[ "$out" == *KCONLY*ok* ]] && t "keychain ls ok" "yes" "yes" || t "keychain ls ok" "yes" "no"
opgate keychain rm local-key >/dev/null
out="$(opgate keychain ls)"
[[ "$out" == *MISSING* ]] && t "keychain ls missing" "yes" "yes" || t "keychain ls missing" "yes" "no"

# 20b. the write path must not leak the secret through argv, where a same-user
#      `ps` can read it — security(1) says so itself ("Use of the -p or -w options
#      is insecure"), and prompting the user only to hand the value straight to
#      security on the command line would defeat the prompt. A single-line value
#      goes over stdin instead. Assert against the recorded argument vector.
: > "$SECURITY_ARGV_LOG"
print -rn -- "argv-must-not-see-me" | opgate keychain set argv-probe >/dev/null
grep -q -- "argv-must-not-see-me" "$SECURITY_ARGV_LOG" \
    && t "single-line secret stays out of argv" "absent" "PRESENT" \
    || t "single-line secret stays out of argv" "absent" "absent"
t "single-line write still round-trips" "argv-must-not-see-me" \
    "$(cat "$KC_STORE/argv-probe%testuser" 2>/dev/null)"
opgate keychain rm argv-probe >/dev/null 2>&1

# 20c. a multiline value cannot use that path: security(1)'s prompt is line-based
#      and fails its own retype check. It falls back to argv, deliberately, and the
#      value must still arrive byte-exact. Documented here so the tradeoff is a
#      decision on record rather than an oversight.
: > "$SECURITY_ARGV_LOG"
print -rn -- $'multi\nline-secret' | opgate keychain set argv-multi >/dev/null
grep -q -- "line-secret" "$SECURITY_ARGV_LOG" \
    && t "multiline falls back to argv" "PRESENT" "PRESENT" \
    || t "multiline falls back to argv" "PRESENT" "absent"
t "multiline write byte-exact" "$(print -rn -- $'multi\nline-secret')" \
    "$(cat "$KC_STORE/argv-multi%testuser" 2>/dev/null)"
opgate keychain rm argv-multi >/dev/null 2>&1

# 21. byte fidelity: security(1) hands back hex for anything that is not pure
#     printable ASCII, so a PEM key must survive the round trip intact — and a
#     value that merely looks like hex must not be decoded
printf 'line1\nline2\ttab\ncaf\xc3\xa9\n' > "$KC_STORE/pem%testuser"
printf 'deadbeef'                          > "$KC_STORE/hexish%testuser"
print -r -- "PEMKEY=keychain://pem"        > "$work/profiles/bytes.env"
print -r -- "HEXISH=keychain://hexish"    >> "$work/profiles/bytes.env"
t "multiline byte-exact" "$(printf 'line1\nline2\ttab\ncaf\xc3\xa9')" \
                         "$(opgate bytes /bin/sh -c 'printf %s "$PEMKEY"')"
t "hex-looking literal"  "deadbeef" "$(opgate bytes /bin/sh -c 'printf %s "$HEXISH"')"

# 22. env-file value rules match op's, so a reference is not silently altered.
#     The inline-comment case is the one that bites: an unstripped comment goes
#     into the keychain service name and the lookup misses.
printf 'commented' > "$KC_STORE/svc-commented%testuser"
cat > "$work/profiles/dotenv.env" <<'EOF'
KCCOMMENT=keychain://svc-commented   # trailing comment
BARE_HASH=abc#def
QUOTED_HASH="a#b"
SQ_DOLLAR='$HOME'
EOF
t "inline comment stripped" "commented" "$(opgate dotenv /bin/sh -c 'echo $KCCOMMENT')"
t "hash ends bare value"    "abc"       "$(opgate dotenv /bin/sh -c 'echo $BARE_HASH')"
t "quotes protect hash"     'a#b'       "$(opgate dotenv /bin/sh -c 'echo $QUOTED_HASH')"
t "single quotes literal"   '$HOME'     "$(opgate dotenv /bin/sh -c 'echo $SQ_DOLLAR')"

# none of those needed op — they are values op would hand back untouched
before="$(opcalls)"
opgate flush
zsh -c "source '$root/opgate.zsh'; opgate dotenv /usr/bin/true"
t "plain literals are op-free" "$before" "$(opcalls)"

# 23. a value op would expand is not guessed at locally — it goes through op
cat > "$work/profiles/expand.env" <<'EOF'
KCX=keychain://svc-commented
EXPANDED=$OPGATE_TEST_HOME/x
EOF
export OPGATE_TEST_HOME="/tmp/th"
before="$(opcalls)"
t "expandable literal value" "/tmp/th/x" "$(opgate expand /bin/sh -c 'echo $EXPANDED')"
t "expandable literal uses op" "$(( before + 1 ))" "$(opcalls)"

# 24. approve does not sign in for a profile whose values never reach op, even
#     when it carries an account directive and a literal
cat > "$work/profiles/noop.env" <<'EOF'
# opgate:account test.1password.com
KCN=keychain://svc-commented
BASE_URL=https://example.invalid
EOF
mkdir -p "$work/only-noop"
cp "$work/profiles/noop.env" "$work/only-noop/noop.env"
before="$(grep -c '^argv=' "$OP_FAKE_LOG")"
out="$(OPGATE_DIR="$work/only-noop" zsh -c "source '$root/opgate.zsh'; opgate approve")"
t "no-op profile skips op"   "$before" "$(grep -c '^argv=' "$OP_FAKE_LOG")"
[[ "$out" == *"no approval needed"* ]] \
    && t "no-op profile message" "yes" "yes" || t "no-op profile message" "yes" "no"

# 25. ls labels the source
print -rn -- "back" | opgate keychain set local-key >/dev/null
out="$(opgate ls)"
[[ "$out" == *"[keychain]"* ]]     && t "ls keychain label" "yes" "yes" || t "ls keychain label" "yes" "no"
[[ "$out" == *"+ keychain]"* ]]    && t "ls mixed label"    "yes" "yes" || t "ls mixed label"    "yes" "no"

# --- failure posture -------------------------------------------------------
# Measured against a real outage: a shared service-account bucket ran dry and
# a launchd job hung in `op run` for hours. When op fails, the persistent blob
# is served stale with a warning; when op hangs, it is killed after
# OPGATE_OP_TIMEOUT; OPGATE_STALE_FALLBACK=0 restores fail-hard.

# 26. warm the persistent tier, then break op with the env file changed so
#     every honest tier misses and only the stale path can answer
print -r -- "# opgate:account test.1password.com" > "$work/profiles/outage.env"
print -r -- "OUT1=op://vault/item/f1" >> "$work/profiles/outage.env"
out="$(OPGATE_CACHE_TTL_DAYS=30 zsh -c "source '$root/opgate.zsh'; opgate outage /bin/sh -c 'echo \$OUT1'")"
t "outage: warm" "resolved:OUT1" "$out"

sleep 1; print -r -- "OUT2=op://vault/item/f2" >> "$work/profiles/outage.env"
out="$(OPGATE_CACHE_TTL_DAYS=30 OP_FAKE_FAIL=1 zsh -c "source '$root/opgate.zsh'; opgate outage /bin/sh -c 'echo \$OUT1'" 2>"$work/stale.err")" \
    && t "outage: stale rc" "zero" "zero" || t "outage: stale rc" "zero" "nonzero"
t "outage: stale value served" "resolved:OUT1" "$out"
grep -q "serving stale" "$work/stale.err" \
    && t "outage: stale warns" "yes" "yes" || t "outage: stale warns" "yes" "no"
grep -q "missing: OUT2" "$work/stale.err" \
    && t "outage: missing vars named" "yes" "yes" || t "outage: missing vars named" "yes" "no"

# 27. the knob: fail-hard is still available
OPGATE_CACHE_TTL_DAYS=30 OP_FAKE_FAIL=1 OPGATE_STALE_FALLBACK=0 \
    zsh -c "source '$root/opgate.zsh'; opgate outage /usr/bin/true" 2>/dev/null \
    && t "outage: fallback off fails" "nonzero" "zero" \
    || t "outage: fallback off fails" "nonzero" "nonzero"

# 28. a hung op is killed, and the stale path still answers afterwards
out="$(OPGATE_CACHE_TTL_DAYS=30 OP_FAKE_HANG=60 OPGATE_OP_TIMEOUT=2 zsh -c "source '$root/opgate.zsh'; opgate outage /bin/sh -c 'echo \$OUT1'" 2>"$work/hang.err")"
t "outage: hung op killed, stale served" "resolved:OUT1" "$out"
grep -q "exceeded 2s" "$work/hang.err" \
    && t "outage: timeout warns" "yes" "yes" || t "outage: timeout warns" "yes" "no"

print
print -r -- "passed $pass, failed $fail"
(( fail == 0 ))
