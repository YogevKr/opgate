# opgate — scoped, cached 1Password secrets for shells and AI agents.
#
# Exported secrets are inherited by every descendant process — including
# sandboxed agent jobs, whose sandbox governs files and network but not the
# environment. opgate hands values only to the command that needs them:
#
#   opgate personal curl -H "Authorization: Bearer $TOKEN" ...
#   opgate agents buzz post ...
#   opagents buzz post ...          # convenience function, one per profile
#
# A profile is an env file at $OPGATE_DIR/<name>.env (default
# ~/.config/opgate) holding references, never values. Two sources resolve:
#
#   HA_TOKEN=op://<vault>/<item>/field        1Password
#   GH_TOKEN=keychain://<service>[/<account>] macOS login keychain
#
# and anything else passes through as a literal. Two directive comments choose
# how the 1Password half authenticates:
#
#   # opgate:account my.1password.com     resolve via your op session
#   # opgate:token-file ~/.config/opgate/agents.token
#                                         resolve via a service account
#
# The token-file form is the point of this tool: give agents a profile backed
# by a 1Password service account that can read exactly one vault, and they can
# use those secrets — with no Touch ID, no desktop app, headless — while your
# real account session, and everything it can read, stays out of their reach.
#
# keychain:// is the local-only source, for the machine-bound secrets that
# should never leave it. It needs no account, no network and no `op`: a profile
# with no op:// reference never invokes `op` at all. Keychain values are
# resolved on every call and never written to the caches below — the keychain
# keeps them encrypted at rest, and mirroring them into a 0600 file would undo
# precisely that. `opgate keychain set` puts a value in.
#
# Three cache tiers sit in front of `op run`, because op's own authorization
# only lasts 10 idle minutes per terminal:
#
#   1. shell memory  — non-exported assoc arrays; children only see values for
#                      the lifetime of a wrapped command, same as `op run`.
#   2. session file  — 0600 under $TMPDIR, keyed by the session this shell
#                      belongs to (Claude Code session, else Codex thread,
#                      else the terminal app). Agent harnesses run every
#                      command in a fresh shell, so tier 1 never survives one.
#                      12h TTL, matching op's own hard session cap.
#   3. persistent    — 0600 under ~/.cache/opgate, shared by every session on
#                      the box and surviving reboots. OFF unless
#                      OPGATE_CACHE_TTL_DAYS is set; it exists for machines
#                      where approving is expensive (a headless box over SSH,
#                      where op's desktop-app integration cannot prompt), not
#                      for a laptop with Touch ID.
#
# Editing a profile invalidates every tier for it (mtime is stored alongside
# the values). `opgate flush` drops all three and forces a fresh approval.
#
# Trade-offs, accepted deliberately: op run's stdout masking is gone, so a
# wrapped command that prints a secret lands it in scrollback; and resolved
# values persist outside this shell, so anything running as this user can read
# the cached files. Scope what a profile can reach accordingly — that is what
# token-file profiles are for. Knobs: OPGATE_CACHE_TTL_DAYS=<days> enables
# tier 3, OPGATE_SESSION_CACHE=agents keeps terminals memory-only, and
# OPGATE_SESSION_CACHE=off / OPGATE_NO_SESSION_CACHE=1 disables tiers 2 and 3.
#
# Failure posture, measured against a real outage (a shared service-account
# bucket ran dry mid-day and a launchd gateway hung in `op run` for hours):
# blobs carry a content hash, so a touched-but-unchanged env file revalidates
# instead of spending a resolve; `op run` is killed after OPGATE_OP_TIMEOUT
# seconds (default 120, 0 = unbounded); and when op fails or times out, the
# persistent blob is served stale with a stderr warning rather than failing
# the caller (OPGATE_STALE_FALLBACK=0 restores fail-hard). Stale serves stay
# in memory only. Failed resolves share a retry delay across processes.
#
# Approval holder: the desktop-app integration ties an authorization to the
# process session op runs in, and an agent tool call is a fresh session with
# no terminal — so every op call from an agent was a new terminal to the app,
# and a new Touch ID prompt. Without a terminal on stdin, account-profile op
# calls run inside one long-lived session per agent session instead (see
# _opg_holder_main): approve once, and the rest of the session rides it.

# All state lives here rather than at file scope: some agent harnesses
# (Claude Code) snapshot the shell by dumping functions and exported env, so
# plain globals set at source time are gone by the time a tool call runs.
typeset -g OPGATE_VERSION=0.5.1

_opg_init() {
    # ${:-} guards throughout: this must survive a sourcing shell that has
    # `setopt no_unset`.
    zmodload zsh/datetime 2>/dev/null
    # b: loads only the zstat builtin, leaving the external `stat` untouched.
    # zstat replaces the stat(1) call: BSD and GNU stat disagree on flags
    # (GNU -f is filesystem mode and still prints before failing, corrupting
    # a $(A || B) capture).
    zmodload -F zsh/stat b:zstat 2>/dev/null
    typeset -gA _opg_vals    # "<profile>:<VAR>" -> value
    typeset -gA _opg_names   # "<profile>" -> "VAR1 VAR2 ..." (cached tiers only)
    typeset -gA _opg_kcnames # "<profile>" -> keychain-sourced VARs, never cached
    typeset -gA _opg_mtime   # "<profile>" -> env-file mtime at load
    typeset -gA _opg_hash    # "<profile>" -> env-file content hash at load
    [[ -n "${_opg_dir:-}" ]]         || typeset -g _opg_dir="${OPGATE_DIR:-$HOME/.config/opgate}"
    [[ -n "${_opg_session_dir:-}" ]] || typeset -g _opg_session_dir="${TMPDIR:-/tmp}/opgate-session"
    [[ -n "${_opg_session_ttl:-}" ]] || typeset -g _opg_session_ttl="${OPGATE_SESSION_TTL:-43200}"   # 12h
    [[ -n "${_opg_persist_dir:-}" ]] || typeset -g _opg_persist_dir="${OPGATE_CACHE_DIR:-$HOME/.cache/opgate}"
    typeset -g _opg_persist_ttl=$(( ${OPGATE_CACHE_TTL_DAYS:-0} * 86400 ))
    # Decided here, at the entry point: the resolver runs op from a background
    # job, and a background job never has the terminal on stdin.
    typeset -g _opg_stdin_tty=0
    [[ -t 0 ]] && _opg_stdin_tty=1
    # A revision change invalidates caches in other, already-running shells.
    local revision=""
    [[ -r "$_opg_persist_dir/revision" ]] && read -r revision < "$_opg_persist_dir/revision"
    if [[ "$revision" != "${_opg_revision:-}" ]]; then
        _opg_vals=() _opg_names=() _opg_kcnames=() _opg_mtime=() _opg_hash=()
    fi
    typeset -g _opg_revision="$revision"
}

_opg_profile_file() { print -r -- "$_opg_dir/$1.env" }

_opg_profiles() {
    local f
    for f in "$_opg_dir"/*.env(N); print -r -- "${${f:t}%.env}"
}

# Auth mode for a profile, from its directive comments. Prints one of:
#   "token <path>" | "account <account>" | "default"
_opg_auth() {
    local file="$1" tok acct
    tok="$(sed -n 's/^# *opgate:token-file *//p' "$file" 2>/dev/null | head -1)"
    acct="$(sed -n 's/^# *opgate:account *//p' "$file" 2>/dev/null | head -1)"
    if [[ -n "$tok" && -n "$acct" ]]; then
        print -u2 -- "opgate: $file declares both opgate:account and opgate:token-file — pick one"
        return 1
    fi
    if [[ -n "$tok" ]]; then
        print -r -- "token ${tok/#\~\//$HOME/}"
    elif [[ -n "$acct" ]]; then
        print -r -- "account $acct"
    else
        print -r -- "default"
    fi
}

# Splits a profile env file into its two sources. Fills, for the caller:
#   _opg_p_names  every declared VAR, in file order
#   _opg_p_kc     flat "VAR ref VAR ref ..." for keychain:// values
#   _opg_p_op     VARs left for `op run` — op:// references and literals
#   _opg_p_lit    flat "VAR value ..." for the literals among those
#   _opg_p_needop 1 when `op run` has to be invoked at all
# Deliberately fork-free ($(<file) is a builtin substitution, not a subshell):
# this runs on every call, including cache hits, where the whole point is that
# nothing is spawned.
#
# The value rules mirror op's own env-file parser, measured against op 2.x
# rather than assumed, because a mismatch here silently changes a value:
#   VAR=a#b            -> "a"          unquoted values end at the first #
#   VAR=hi   # note    -> "hi"         trailing blanks go with it
#   VAR="a#b"          -> "a#b"        quotes protect the #
#   VAR='$HOME'        -> "$HOME"      single quotes suppress expansion
#   VAR=$HOME/x        -> expanded     unquoted and double-quoted do not
# Expansion is the one rule not reproduced here, so any value that would be
# expanded is marked as needing op instead of being resolved locally.
_opg_parse() {
    emulate -L zsh
    setopt extended_glob
    local env_file="$1" content line var raw val quote
    content="$(<"$env_file")" || return 1
    typeset -ga _opg_p_names _opg_p_kc _opg_p_op _opg_p_lit _opg_p_refs
    typeset -g  _opg_p_needop
    _opg_p_names=() _opg_p_kc=() _opg_p_op=() _opg_p_lit=() _opg_p_refs=() _opg_p_needop=0
    for line in ${(f)content}; do
        # A line is a declaration only if it starts at column 1 with a bare name
        # and an =. Comments, blanks and indented lines fall out here, including
        # the "#VAR=..." hints in the scaffolded template.
        [[ "$line" == *=* ]] || continue
        var="${line%%=*}"
        [[ "$var" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || continue
        raw="${${line#*=}##[[:blank:]]#}"
        if [[ "$raw" == \"*\"* ]]; then
            val="${${raw#\"}%%\"*}"; quote=double
        elif [[ "$raw" == \'*\'* ]]; then
            val="${${raw#\'}%%\'*}"; quote=single
        else
            val="${${raw%%\#*}%%[[:blank:]]#}"; quote=none
        fi
        _opg_p_names+=("$var")
        if [[ "$val" == keychain://* ]]; then
            _opg_p_kc+=("$var" "$val")
        else
            _opg_p_op+=("$var")
            if [[ "$val" == op://* ]]; then
                _opg_p_needop=1
                _opg_p_refs+=("$var" "$val")
            else
                # Resolve a literal here only when op would hand back exactly
                # these bytes. Single quotes always stop it substituting; short
                # of that, a $ it would expand or a backslash it might read as
                # an escape goes through op rather than be guessed at.
                [[ "$quote" != single && "$val" == *[\$\\]* ]] && _opg_p_needop=1
                _opg_p_lit+=("$var" "$val")
            fi
        fi
    done
    return 0
}

# keychain://<service>[/<account>] -> "<service>\t<account>". The account
# defaults to the login name, which is what a bare `security add-generic-password
# -s NAME -w` writes, so single-secret items need only the service.
_opg_kc_parse() {
    local ref="${1#keychain://}" svc acct
    svc="${ref%%/*}"
    if [[ "$ref" == */* ]]; then acct="${ref#*/}"; else acct="${OPGATE_KEYCHAIN_ACCOUNT:-${USER:-$LOGNAME}}"; fi
    [[ -n "$svc" && -n "$acct" ]] || return 1
    print -r -- "$svc"$'\t'"$acct"
}

# Hex back to bytes, without a fork. no_multibyte so ${(#)} maps 0x00-0xFF to
# one byte each instead of encoding them as UTF-8 characters — the point is to
# return the stored bytes, whatever they were.
_opg_unhex() {
    local hex="$1" i n out=""
    setopt local_options no_multibyte
    for (( i = 1; i < ${#hex}; i += 2 )); do
        n=$(( 16#${hex[i,i+1]} ))
        out+="${(#)n}"
    done
    typeset -g REPLY="$out"
}

# Reads one generic-password item into REPLY. `security` exits non-zero on a
# missing item and on a locked keychain (an SSH session, where the login
# keychain is never unlocked) — it fails fast either way rather than hanging
# for GUI auth the way `op` does, which is why the read path may call it and
# may not call `op`. REPLY rather than stdout: a value ending in a newline
# would not survive a second round of command substitution.
#
# The trap: `-w` prints the password raw only when every byte is printable
# ASCII. One newline, tab or accented character in there and it silently prints
# lowercase hex instead, with nothing in the output to mark the difference — so
# a PEM key or an SSH key read naively comes back as its own hex dump. A value
# that is genuinely plain hex ("deadbeef") is indistinguishable from an encoded
# one, so when the output could be read either way, `-g` decides it: that form
# prefixes real hex with 0x. The second call only happens in that narrow case.
_opg_kc_get() {
    local svc="$1" acct="$2" out
    # `&& printf X` carries the exit status out of the substitution, and the
    # sentinel keeps a value's own trailing newlines; security adds exactly one.
    out="$(security find-generic-password -s "$svc" -a "$acct" -w 2>/dev/null && printf X)"
    [[ "$out" == *X ]] || return 1
    out="${out%X}"
    out="${out%$'\n'}"
    if (( ${#out} > 0 && ${#out} % 2 == 0 )) && [[ "$out" =~ '^[0-9a-f]+$' ]] &&
       security find-generic-password -g -s "$svc" -a "$acct" 2>&1 >/dev/null |
           grep -q '^password: 0x'; then
        _opg_unhex "$out"
        return 0
    fi
    typeset -g REPLY="$out"
}

_opg_kc_set() {
    local svc="$1" acct="$2" val="$3"
    # -U updates in place; without it a second write fails on the existing item.
    # No -A: the item stays readable only through this tool path, not by any
    # app that asks.
    #
    # -w with a value puts the secret in argv, where any process running as this
    # user can read it out of `ps` for the lifetime of the call — the same
    # exposure `opgate keychain set` prompts to avoid, so it would be pointless to
    # close the front door and leave this one open. security(1) says as much:
    # "Use of the -p or -w options is insecure. Specify -w as the last option to
    # be prompted." Prompted, it reads the value from stdin, twice, and confirms.
    #
    # That form cannot carry a newline: the prompt is line-based, so a multiline
    # value fails its own retype check. Those still go through argv — measured,
    # not assumed. The keychain positional is dropped in the prompted form too,
    # since -w would swallow it as the password; nothing passes one today.
    if [[ "$val" != *$'\n'* ]]; then
        printf '%s\n%s\n' "$val" "$val" |
            security add-generic-password -U -s "$svc" -a "$acct" -j "opgate" -w 2>&1
    else
        security add-generic-password -U -s "$svc" -a "$acct" -j "opgate" -w "$val" 2>&1
    fi
}

_opg_kc_load() {
    local profile="$1" var="$2" ref="$3" pair svc acct
    if ! (( ${+commands[security]} )); then
        print -u2 -- "opgate: $var wants $ref but this is not macOS (no security(1))"
        return 1
    fi
    if ! pair="$(_opg_kc_parse "$ref")"; then
        print -u2 -- "opgate: $var: malformed reference '$ref' (want keychain://<service>[/<account>])"
        return 1
    fi
    svc="${pair%%$'\t'*}"; acct="${pair#*$'\t'}"
    if ! _opg_kc_get "$svc" "$acct"; then
        print -u2 -- "opgate: $var: cannot read keychain item $svc/$acct — opgate keychain set $svc/$acct"
        return 1
    fi
    _opg_vals[$profile:$var]="$REPLY"
    unset REPLY
}

# Every tab of a terminal is its own shell, so the in-memory cache alone means
# a prompt per tab. All tabs and panes descend from one long-lived process —
# the terminal app itself, or the tmux server — so keying on that gives one
# prompt per terminal launch. Its start time is folded in so a recycled PID
# can't inherit a stale cache. /bin/ps is deliberate: `ps` may be aliased.
_opg_terminal_key() {
    local pid=${1:-$$} parent comm start depth=0   # arg is for testing the walk
    while (( depth++ < 12 )); do
        parent="$(/bin/ps -o ppid= -p $pid 2>/dev/null | tr -d ' ')"
        [[ -n "$parent" ]] && (( parent > 1 )) || return 1
        comm="$(/bin/ps -o comm= -p $parent 2>/dev/null)"
        case "${${comm##*/}#-}" in
            zsh|bash|sh|dash|ksh|fish|login|env|script|nohup) pid=$parent ;;
            *)  start="$(/bin/ps -o lstart= -p $parent 2>/dev/null)"
                print -r -- "term-${parent}-${start//[^0-9]/}"
                return 0 ;;
        esac
    done
    return 1
}

# Which session this shell belongs to. Agent runners that pass the full parent
# env (Codex does) key a child job to the parent session and reuse its cache;
# a standalone run keys to its own thread; a plain terminal to its app.
_opg_session_key() {
    _opg_cache_enabled || return 1
    _opg_session_key_raw
}

# The key without the cache switch: the approval holder is keyed the same way
# but is not a cache, so OPGATE_NO_SESSION_CACHE must not disable it.
_opg_session_key_raw() {
    [[ -n "${_opg_session_key_cached:-}" ]] && { print -r -- "$_opg_session_key_cached"; return 0 }
    local key
    if   [[ -n "${OPGATE_SESSION_KEY:-}" ]];      then key="$OPGATE_SESSION_KEY"
    elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]];  then key="claude-$CLAUDE_CODE_SESSION_ID"
    elif [[ -n "${CODEX_THREAD_ID:-}" ]];         then key="codex-$CODEX_THREAD_ID"
    elif [[ "${OPGATE_SESSION_CACHE:-all}" == all ]]; then key="$(_opg_terminal_key)" || return 1
    else return 1
    fi
    typeset -g _opg_session_key_cached="${key//[^A-Za-z0-9._-]/_}"
    print -r -- "$_opg_session_key_cached"
}

_opg_cache_enabled() {
    [[ -z "${OPGATE_NO_SESSION_CACHE:-}" && "${OPGATE_SESSION_CACHE:-all}" != (off|none|0) ]]
}

_opg_session_file() {
    local key
    key="$(_opg_session_key)" || return 1
    print -r -- "$_opg_session_dir/${key}.${1}.v4"
}

# Env-file content hash, for revalidating a blob whose mtime no longer
# matches. One fork, but only on paths that already fork (a write happens
# after `op run`; a read computes it only after the fork-free mtime check has
# missed). Truncated: this distinguishes edits, it doesn't resist an attacker
# who can already write the 0600 file.
_opg_env_hash() {
    local file="$1" out
    if (( ${+commands[shasum]} )); then out="$(shasum -a 256 "$file" 2>/dev/null)"
    elif (( ${+commands[sha256sum]} )); then out="$(sha256sum "$file" 2>/dev/null)"
    else return 1
    fi
    [[ -n "$out" ]] || return 1
    print -r -- "${out[1,32]}"
}

# Blob layout: "#mtime <env-file mtime>", "#hash <env-file content hash>",
# "#ts <resolved at>", then "<VAR> <base64 value>" per variable, then "#end".
# The trailer proves the blob is complete, and base64 keeps it inert data
# rather than sourceable code.
_opg_blob_encode() {
    local profile="$1" var
    print -r -- "#mtime ${_opg_mtime[$profile]}"
    [[ -n "${_opg_hash[$profile]:-}" ]] && print -r -- "#hash ${_opg_hash[$profile]}"
    print -r -- "#ts $EPOCHSECONDS"
    print -r -- "#revision ${_opg_revision:-}"
    for var in ${=_opg_names[$profile]}; do
        print -r -- "$var $(printf '%s' "${_opg_vals[$profile:$var]}" | base64 | tr -d '\n')"
    done
    print -r -- "#end"
}

# Reads a blob on stdin. max_age 0 means "don't check" (the file tier stamps
# freshness with the file's own mtime instead). A blob is valid when its
# recorded mtime matches — or, failing that, when the caller supplies the
# current content hash and it matches the recorded one: a touched or
# edited-and-reverted env file revalidates instead of forcing `op run`.
# env_mtime "-" skips both checks; that is the stale-fallback path, which
# owns its own warning.
_opg_blob_decode() {
    local profile="$1" env_mtime="$2" max_age="${3:-0}" env_hash="${4:-}"
    local line var enc decoded ended=0 ts=0 mtime_ok=0 hash_ok=0 blob_hash="" revision=""
    local -a names vals
    [[ "$env_mtime" == "-" ]] && mtime_ok=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        var="${line%% *}"
        enc="${line#* }"
        case "$var" in
            '#mtime') if [[ "$enc" == "$env_mtime" ]]; then mtime_ok=1
                      # Without a hash to fall back on, a wrong mtime already
                      # decides it — keep the old early exit for that path.
                      elif [[ -z "$env_hash" && "$env_mtime" != "-" ]]; then return 1
                      fi; continue ;;
            '#hash')  blob_hash="$enc"
                      [[ -n "$env_hash" && "$enc" == "$env_hash" ]] && hash_ok=1
                      continue ;;
            '#ts')    ts="$enc"; continue ;;
            '#revision') revision="$enc"; continue ;;
            '#end')   ended=1; continue ;;
        esac
        [[ "$enc" =~ '^[A-Za-z0-9+/=]+$' ]] || return 1
        # trailing-X sentinel: command substitution eats trailing newlines
        decoded="$(print -r -- "$enc" | base64 -d 2>/dev/null; printf X)"
        names+=("$var")
        vals+=("${decoded%X}")
    done
    [[ "$revision" == "${_opg_revision:-}" ]] || return 1
    (( mtime_ok || hash_ok )) || return 1
    (( ended && ${#names} )) || return 1
    if (( max_age > 0 )); then
        (( ts > 0 && EPOCHSECONDS - ts < max_age )) || return 1
    fi
    # Commit only after the blob has proven itself, so an invalid one cannot
    # leave half its values behind.
    local i
    for (( i = 1; i <= ${#names}; i++ )); do
        _opg_vals[$profile:${names[i]}]="${vals[i]}"
    done
    _opg_names[$profile]="${(j: :)names}"
    [[ "$env_mtime" != "-" ]] && _opg_mtime[$profile]="$env_mtime"
    [[ -n "$blob_hash" ]] && _opg_hash[$profile]="$blob_hash"
    typeset -g _opg_blob_ts="$ts"
    return 0
}

_opg_session_read() {
    local profile="$1" env_mtime="$2" env_hash="${3:-}" file file_mtime
    file="$(_opg_session_file "$profile")" || return 1
    # Read legacy caches only before the first explicit invalidation. New files
    # use a separate namespace so old shell snapshots cannot overwrite them.
    if [[ ! -r "$file" && -z "${_opg_revision:-}" ]]; then file="${file%.v4}"; fi
    [[ -r "$file" ]] || return 1
    file_mtime="$(zstat +mtime "$file" 2>/dev/null)" || return 1
    if (( EPOCHSECONDS - file_mtime >= _opg_session_ttl )); then
        rm -f "$file"
        return 1
    fi
    _opg_blob_decode "$profile" "$env_mtime" 0 "$env_hash" < "$file"
}

_opg_session_write() {
    local profile="$1" file tmp
    file="$(_opg_session_file "$profile")" || return 0
    mkdir -p "$_opg_session_dir" 2>/dev/null || return 0
    chmod 700 "$_opg_session_dir" 2>/dev/null
    tmp="$file.$$"
    ( umask 077; _opg_blob_encode "$profile" >| "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 0 }
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
    # sweep caches from sessions that ended without a flush
    find "$_opg_session_dir" -type f -mmin +$(( _opg_session_ttl / 60 )) -delete 2>/dev/null
    return 0
}

# Persistent tier, off unless OPGATE_CACHE_TTL_DAYS is set. A plain 0600 file
# rather than the login keychain, which an SSH session cannot read.
_opg_persist_file() { print -r -- "$_opg_persist_dir/${1}.v4.cache" }

_opg_persist_read_file() {
    REPLY="$(_opg_persist_file "$1")"
    if [[ ! -r "$REPLY" && -z "${_opg_revision:-}" ]]; then
        REPLY="$_opg_persist_dir/${1}.cache"
    fi
}

_opg_persist_read() {
    local profile="$1" env_mtime="$2" env_hash="${3:-}" file
    (( _opg_persist_ttl > 0 )) || return 1
    _opg_cache_enabled || return 1
    _opg_persist_read_file "$profile"; file="$REPLY"
    [[ -r "$file" ]] || return 1
    _opg_blob_decode "$profile" "$env_mtime" "$_opg_persist_ttl" "$env_hash" < "$file"
}

# Last resort, only after `op run` itself has failed: serve the persistent
# blob with the mtime and TTL checks waived. A rate-limited account or a dead
# network turning into a refused boot is strictly worse than yesterday's
# values with a warning — the values were good enough to cache, and the
# authorization model is unchanged (same 0600 file, same user). Variables
# added to the env file since the blob was written are reported missing, not
# invented. The stale result stays in memory only; the tiers are not
# rewritten. A separate failure marker limits retries across processes.
# OPGATE_STALE_FALLBACK=0 restores fail-hard.
_opg_stale_read() {
    local profile="$1" file
    [[ "${OPGATE_STALE_FALLBACK:-1}" != (0|off|no) ]] || return 1
    _opg_cache_enabled || return 1
    _opg_persist_read_file "$profile"; file="$REPLY"
    [[ -r "$file" ]] || return 1
    _opg_blob_decode "$profile" "-" 0 < "$file" || return 1
    local age="" missing="" var
    (( ${_opg_blob_ts:-0} > 0 )) && age=" from $(( (EPOCHSECONDS - _opg_blob_ts) / 3600 ))h ago"
    for var in ${_opg_p_op}; do
        [[ " ${_opg_names[$profile]} " == *" $var "* ]] || missing+=" $var"
    done
    print -u2 -- "opgate: op run failed; serving stale cache for '$profile'$age${missing:+ (missing:$missing)}"
    return 0
}

_opg_persist_write() {
    local profile="$1" file tmp
    (( _opg_persist_ttl > 0 )) || return 0
    _opg_cache_enabled || return 0
    file="$(_opg_persist_file "$profile")"
    mkdir -p "$_opg_persist_dir" 2>/dev/null || return 0
    chmod 700 "$_opg_persist_dir" 2>/dev/null
    tmp="$file.$$"
    ( umask 077; _opg_blob_encode "$profile" >| "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 0 }
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
    return 0
}

# This file contains only a timestamp and profile hash, never secret values.
# Share failures even with a cold cache: fresh agent shells otherwise retry
# every reference on every command during a quota or network outage.
_opg_retry_file() { print -r -- "$_opg_persist_dir/${1}.v4.retry" }

_opg_retry_wait() {
    local profile="$1" hash="$2" file ts saved_hash revision
    local delay="${OPGATE_RETRY_SECONDS:-3600}"
    [[ "$delay" == <-> ]] && (( delay > 0 )) || return 1
    _opg_cache_enabled || return 1
    file="$(_opg_retry_file "$profile")"
    if [[ ! -r "$file" && -z "${_opg_revision:-}" ]]; then file="$_opg_persist_dir/$profile.retry"; fi
    [[ -r "$file" ]] || return 1
    read -r ts saved_hash revision < "$file" || return 1
    [[ "$revision" == "${_opg_revision:-}" ]] || return 1
    [[ "$ts" == <-> && "$saved_hash" == "$hash" ]] || return 1
    local left=$(( ts + delay - EPOCHSECONDS ))
    (( left > 0 && left <= delay )) || return 1
    print -u2 -- "opgate: retry delayed for '$profile' (${left}s remaining)"
    return 0
}

_opg_retry_record() {
    local profile="$1" hash="$2" file tmp
    _opg_cache_enabled || return 0
    file="$(_opg_retry_file "$profile")"
    tmp="$file.$$"
    mkdir -p "$_opg_persist_dir" 2>/dev/null || return 0
    chmod 700 "$_opg_persist_dir" 2>/dev/null
    ( umask 077; print -r -- "$EPOCHSECONDS $hash ${_opg_revision:-}" >| "$tmp" ) 2>/dev/null || return 0
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
    return 0
}

_opg_load() {
    local profile="$1" env_file="$2"
    local mtime i
    mtime="$(zstat +mtime "$env_file" 2>/dev/null)" || mtime=0

    _opg_parse "$env_file" || { print -u2 -- "opgate: cannot read $env_file"; return 1 }
    if (( ${#_opg_p_names} == 0 )); then
        print -u2 -- "opgate: no variables declared in $env_file"
        return 1
    fi

    # Keychain values are resolved on every call and never cached. Reading them
    # is silent and local, so there is no prompt to amortise — and the caches
    # are 0600 plaintext, so mirroring them there would strip the encryption at
    # rest that is the whole reason to keep a secret in the keychain.
    local -a kcnames
    for (( i = 1; i <= ${#_opg_p_kc}; i += 2 )); do
        _opg_kc_load "$profile" "${_opg_p_kc[i]}" "${_opg_p_kc[i+1]}" || return 1
        kcnames+=("${_opg_p_kc[i]}")
    done
    _opg_kcnames[$profile]="${(j: :)kcnames}"

    local -a names; names=(${_opg_p_op})
    if (( ${#names} == 0 )); then
        # Keychain-only profile: nothing to cache, and `op` is never involved.
        _opg_names[$profile]=""
        _opg_mtime[$profile]="$mtime"
        return 0
    fi

    if [[ -n "${_opg_names[$profile]}" && "${_opg_mtime[$profile]}" == "$mtime" ]]; then
        return 0
    fi
    _opg_session_read "$profile" "$mtime" && return 0
    # Persistent hit: mirror into the session file so the rest of the session
    # keeps the cheaper path.
    if _opg_persist_read "$profile" "$mtime"; then
        _opg_session_write "$profile"
        return 0
    fi
    # The fork-free mtime checks have all missed. Before conceding to `op`,
    # one fork to hash the content: a `touch`, a re-save, or an edit that was
    # reverted leaves the bytes identical, and the blob revalidates. A hash
    # hit rewrites the tiers under the current mtime, so the next call is
    # back on the fork-free path.
    local hash
    if hash="$(_opg_env_hash "$env_file")"; then
        if _opg_session_read "$profile" "$mtime" "$hash" ||
           _opg_persist_read "$profile" "$mtime" "$hash"; then
            _opg_mtime[$profile]="$mtime"
            _opg_hash[$profile]="$hash"
            _opg_session_write "$profile"
            _opg_persist_write "$profile"
            return 0
        fi
    fi

    # Nothing here needs op: the remaining values are literals that op would
    # hand back unchanged, so resolve them and leave `op` — which may not even
    # be installed — alone.
    if (( _opg_p_needop == 0 )); then
        for (( i = 1; i <= ${#_opg_p_lit}; i += 2 )); do
            _opg_vals[$profile:${_opg_p_lit[i]}]="${_opg_p_lit[i+1]}"
        done
        _opg_names[$profile]="${(j: :)names}"
        _opg_mtime[$profile]="$mtime"
        _opg_hash[$profile]="${hash:-}"
        _opg_session_write "$profile"
        _opg_persist_write "$profile"
        return 0
    fi

    if _opg_retry_wait "$profile" "${hash:-}"; then
        _opg_stale_read "$profile" && return 0
        return 1
    fi

    local auth
    auth="$(_opg_auth "$env_file")" || return 1
    # Resolve through op run itself so semantics match exactly; --no-masking
    # only affects this internal dump, which is captured, never printed.
    local dump rc=0 _opg_preserve_sessions=0
    # Legacy manual sign-in requires its session token. Explicit human exec
    # already removed inherited tokens before reaching this resolver.
    [[ "$auth" == account\ * ]] && _opg_preserve_sessions=1
    if [[ "$auth" == default ]]; then
        _opg_op_dump "$env_file" || rc=$?
        dump="$REPLY"; unset REPLY
    else
        dump="$(_opg_auth_run "$auth" _opg_capture_print _opg_op run --no-masking --env-file="$env_file" -- /usr/bin/env -0)" || rc=$?
    fi
    if (( rc != 0 )); then
        _opg_retry_record "$profile" "${hash:-}"
        # op said no (or never answered). Yesterday's blob beats a dead boot.
        _opg_stale_read "$profile" && return 0
        return 1
    fi
    rm -f "$(_opg_retry_file "$profile")" "$_opg_persist_dir/$profile.retry" 2>/dev/null
    local kv var
    for kv in ${(0)dump}; do
        [[ -z "$kv" ]] && continue
        var="${kv%%=*}"
        if (( ${names[(Ie)$var]} )); then
            # NB: assignment subscripts must be unquoted — quotes become part
            # of the key in zsh.
            _opg_vals[$profile:$var]="${kv#*=}"
        fi
    done
    _opg_names[$profile]="${(j: :)names}"
    _opg_mtime[$profile]="$mtime"
    _opg_hash[$profile]="${hash:-}"
    _opg_session_write "$profile"
    _opg_persist_write "$profile"
}

# `op run`, bounded. op can sit forever on a wedged cache-daemon socket or an
# authorization that will never arrive, and a resolver that hangs is worse
# than one that fails — the failure path above can still serve stale values,
# a hang serves nothing and takes the caller (a gateway boot, a cron) down
# with it. The subshell keeps job-control chatter out of interactive shells;
# the dump lands in a 0600 file under the session dir — the same exposure
# class as the cache blob it is about to become — and is removed either way.
# OPGATE_OP_TIMEOUT=<seconds> tunes it; 0 restores the unbounded call.
_opg_op_dump() {
    local env_file="$1"
    _opg_capture _opg_op run --no-masking --env-file="$env_file" -- /usr/bin/env -0
}

_opg_capture() {
    local tmo="${OPGATE_OP_TIMEOUT:-120}"
    typeset -g REPLY=""
    if (( tmo <= 0 )); then
        REPLY="$("$@")"
        return $?
    fi
    local dir="${_opg_session_dir:-${TMPDIR:-/tmp}/opgate-session}" out rc
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null
    # zsh keeps $$ in sibling subshells. A status probe must not overwrite a
    # simultaneous resolver capture or remove its output before it is consumed.
    out="$(umask 077; mktemp "$dir/op-dump.XXXXXXXX")" || return 1
    (
        setopt local_options no_monitor no_notify
        umask 077
        "$@" >| "$out" &
        pid=$!; waited=0   # `local` is a function-only builtin; this is a subshell
        while kill -0 $pid 2>/dev/null && (( waited < tmo )); do
            sleep 1; (( waited += 1 ))
        done
        if kill -0 $pid 2>/dev/null; then
            kill -TERM $pid 2>/dev/null
            sleep 1
            kill -KILL $pid 2>/dev/null
            wait $pid 2>/dev/null
            exit 124
        fi
        wait $pid
    )
    rc=$?
    (( rc == 124 )) && print -u2 -- "opgate: op run exceeded ${tmo}s and was killed"
    if (( rc == 0 )); then
        REPLY="$(<"$out")"
    fi
    rm -f "$out"
    return $rc
}

_opg_run() {
    local profile="$1"; shift
    local env_file
    env_file="$(_opg_profile_file "$profile")"
    if [[ ! -r "$env_file" ]]; then
        print -u2 -- "opgate: no such profile '$profile' (no $env_file)"
        local -a have; have=($(_opg_profiles))
        (( ${#have} )) && print -u2 -- "profiles: ${(j:, :)have}"
        return 1
    fi
    if (( $# == 0 )); then
        print -u2 -- "usage: opgate $profile [--] <command> [args...]"
        return 2
    fi
    _opg_load "$profile" "$env_file" || return 1
    local var
    local -a assigns
    for var in ${=_opg_names[$profile]:-} ${=_opg_kcnames[$profile]:-}; do
        assigns+=("$var=${_opg_vals[$profile:$var]}")
    done
    (
        [[ "${_opg_clean_child:-0}" == 1 ]] && _opg_scrub_credentials
        # Bare export prints the inherited environment when the profile is empty.
        if (( ${#assigns} )); then export "${assigns[@]}"; fi
        exec "$@"
    )
}

# Cache-only lookup of a single variable: prints the value and never invokes
# `op`. This is what a launchd/cron-managed service must use — under launchd
# op would need GUI auth and hangs rather than failing — so a resolver that
# can only ever read the cache is the safe shape there. token-file profiles
# are checked first: they are the ones that can always be re-warmed silently.
_opg_read() {
    local var="$1" profile env_file auth mtime
    [[ -n "$var" ]] || { print -u2 -- "usage: opgate read <VAR>"; return 2 }
    local -a ordered rest
    for profile in $(_opg_profiles); do
        env_file="$(_opg_profile_file "$profile")"
        auth="$(_opg_auth "$env_file" 2>/dev/null)" || continue
        case "$auth" in
            token\ *) ordered+=("$profile") ;;
            *)        rest+=("$profile") ;;
        esac
    done
    local i
    for profile in $ordered $rest; do
        env_file="$(_opg_profile_file "$profile")"
        _opg_parse "$env_file" || continue
        (( ${_opg_p_names[(Ie)$var]} )) || continue
        # keychain-sourced values are never cached, so resolve one here. This
        # keeps the promise that matters under launchd — `op` is not invoked —
        # because `security` fails fast on a locked keychain instead of hanging.
        for (( i = 1; i <= ${#_opg_p_kc}; i += 2 )); do
            [[ "${_opg_p_kc[i]}" == "$var" ]] || continue
            _opg_kc_load "$profile" "$var" "${_opg_p_kc[i+1]}" || return 1
            print -rn -- "${_opg_vals[$profile:$var]}"
            return 0
        done
        mtime="$(zstat +mtime "$env_file" 2>/dev/null)" || mtime=0
        if [[ -n "${_opg_names[$profile]}" ]] ||
           _opg_session_read "$profile" "$mtime" ||
           _opg_persist_read "$profile" "$mtime"; then
            print -rn -- "${_opg_vals[$profile:$var]}"
            return 0
        fi
        print -u2 -- "opgate: no cached value for $var (profile $profile) — run opgate approve"
        return 1
    done
    print -u2 -- "opgate: $var is not declared in any profile under $_opg_dir"
    return 1
}

# Forget everything — memory, this session's files, and the persistent cache —
# so the next call re-approves. `opgate flush --session` keeps the persistent
# tier and only drops this session's copy.
_opg_flush() {
    _opg_vals=() _opg_names=() _opg_kcnames=() _opg_mtime=()
    local key profile
    if key="$(_opg_session_key)" && [[ -d "$_opg_session_dir" ]]; then
        rm -f "$_opg_session_dir/${key}."*(N.)   # files only; the holder dir stays
    fi
    [[ "$1" == (--session|-s) ]] && return 0
    for profile in $(_opg_profiles); do
        rm -f "$(_opg_persist_file "$profile")" 2>/dev/null
        rm -f "$_opg_persist_dir/$profile.cache" 2>/dev/null
        rm -f "$_opg_session_dir/"*."$profile"(N) "$_opg_session_dir/"*."$profile.v4"(N) 2>/dev/null
        rm -f "$_opg_persist_dir/$profile.retry" 2>/dev/null
        rm -f "$_opg_persist_dir/fnox-$profile.retry" 2>/dev/null
        rm -f "$(_opg_retry_file "$profile")" "$(_opg_retry_file "fnox-$profile")" 2>/dev/null
    done
    return 0
}

# Sign in and refill every tier in one go. On a box with OPGATE_CACHE_TTL_DAYS
# set this is the once-a-month gesture: `op signin` there is classic password
# auth on stdin (no desktop app answering for it), so it works over SSH — and
# where the app *does* answer, the signin is a harmless no-op and the resolve
# below triggers the usual Touch ID prompt. token-file profiles never need
# approval; they are just warmed.
_opg_approve_one() {
    local profile="$1"
    local env_file auth
    env_file="$(_opg_profile_file "$profile")"
    [[ -r "$env_file" ]] || return 1
    # Nothing that reaches op means nothing to approve — signing in would be
    # pure friction. Resolving is still the check that every keychain item is
    # there and the keychain is unlocked. The test is "does op get invoked",
    # the same one _opg_load uses; keying it on the absence of literals instead
    # would send a profile carrying one plain URL through op signin.
    if _opg_parse "$env_file" && (( _opg_p_needop == 0 )); then
        _opg_load "$profile" "$env_file" || return 1
        if (( ${#_opg_p_kc} )); then
            print -r -- "$profile: keychain OK, $(( ${#_opg_p_kc} / 2 )) secrets readable (no approval needed)"
        else
            print -r -- "$profile: no op:// references, nothing to approve"
        fi
        return 0
    fi
    auth="$(_opg_auth "$env_file")" || return 1
    case "$auth" in
        token\ *)
            unset "_opg_names[$profile]"
            _opg_load "$profile" "$env_file" || return 1
            print -r -- "$profile: service account OK (no approval needed)"
            return 0
            ;;
        account\ *)
            local account="${auth#account }"
            if ! op account list 2>/dev/null | grep -q -- "$account"; then
                print -u2 -- "skipping $profile — no account '$account' on this machine (op account add)"
                return 1
            fi
            eval "$(_opg_op signin --account "$account" 2>/dev/null)" 2>/dev/null
            ;;
    esac
    unset "_opg_names[$profile]"
    if ! _opg_load "$profile" "$env_file"; then
        if [[ ! -t 0 ]] && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file"; then
            print -u2 -- "  (op needs a terminal to take the password — run this from an interactive session)"
        fi
        return 1
    fi
    if (( _opg_persist_ttl > 0 )); then
        print -r -- "$profile: approved, cached for $(( _opg_persist_ttl / 86400 )) days"
    else
        print -r -- "$profile: approved, cached for this session"
    fi
}

_opg_approve() {
    local profile tried=0 ok=0
    for profile in $(_opg_profiles); do
        tried=1
        _opg_approve_one "$profile" && ok=1
    done
    (( tried )) || { print -u2 -- "opgate: no profiles in $_opg_dir (opgate init <name> ...)"; return 1 }
    (( ok ))
}

_opg_ls() {
    local profile env_file auth state mtime nvars fnox_state
    local -a have; have=($(_opg_profiles))
    (( ${#have} )) || { print -u2 -- "opgate: no profiles in $_opg_dir (opgate init <name> ...)"; return 1 }
    local nkc nop
    for profile in $have; do
        env_file="$(_opg_profile_file "$profile")"
        _opg_parse "$env_file" || continue
        nvars=${#_opg_p_names}
        nkc=$(( ${#_opg_p_kc} / 2 ))
        nop=${#_opg_p_op}
        mtime="$(zstat +mtime "$env_file" 2>/dev/null)" || mtime=0
        if (( nop == 0 )); then
            # Nothing to authenticate and nothing to cache: every value is read
            # from the keychain at call time.
            auth="keychain"
            state="live (keychain)"
        else
            # Report the source that is actually used, not the directive the
            # file happens to carry: a profile whose values never reach op is
            # local whatever its opgate:account line says.
            if (( _opg_p_needop )); then
                auth="$(_opg_auth "$env_file" 2>/dev/null)" || auth="INVALID"
            else
                auth="local"
            fi
            (( nkc )) && auth="$auth + keychain"
            if   [[ -n "${_opg_names[$profile]}" ]];   then state="warm (memory)"
            elif _opg_session_read "$profile" "$mtime"; then state="warm (session)"
            elif _opg_persist_read "$profile" "$mtime"; then state="warm (persistent)"
            else state="cold"
            fi
        fi
        fnox_state="$(_opg_fnox_profile_status "$profile" "$env_file")"
        printf '%-14s %-38s %2s vars   native: %s; fnox: %s\n' "$profile" "[${auth}]" "$nvars" "$state" "$fnox_state"
    done
    _opg_fnox_status
    _opg_approval_line
}

# opgate keychain set|rm|ls — the write side of the keychain source. There is
# no `get`: printing a secret is what a wrapped command is for, and `ls` says
# whether a reference resolves without putting the value on a terminal.
_opg_keychain() {
    local sub="${1:-}"; (( $# )) && shift
    local pair svc acct target
    case "$sub" in
        set)
            target="${1:-}"
            [[ -n "$target" ]] || { print -u2 -- "usage: opgate keychain set <service>[/<account>]"; return 2 }
            pair="$(_opg_kc_parse "$target")" || { print -u2 -- "opgate: malformed '$target'"; return 2 }
            svc="${pair%%$'\t'*}"; acct="${pair#*$'\t'}"
            local val out
            if [[ -t 0 ]]; then
                # Prompt rather than take an argument: a value on the command
                # line lands in shell history and in `ps` output.
                read -rs "val?value for $svc/$acct: " && print
            else
                # Piped in — `op read ... | opgate keychain set ...` is the
                # migration path off 1Password. One trailing newline is dropped,
                # since that is what echo and most CLIs add.
                IFS= read -rd '' val
                val="${val%$'\n'}"
            fi
            [[ -n "$val" ]] || { print -u2 -- "opgate: empty value, nothing stored"; return 1 }
            if ! out="$(_opg_kc_set "$svc" "$acct" "$val")"; then
                print -u2 -- "opgate: keychain write failed: $out"
                return 1
            fi
            print -r -- "stored keychain://$svc/$acct — reference it as VAR=keychain://$svc/$acct"
            ;;
        rm|delete)
            target="${1:-}"
            [[ -n "$target" ]] || { print -u2 -- "usage: opgate keychain rm <service>[/<account>]"; return 2 }
            pair="$(_opg_kc_parse "$target")" || { print -u2 -- "opgate: malformed '$target'"; return 2 }
            svc="${pair%%$'\t'*}"; acct="${pair#*$'\t'}"
            if ! security delete-generic-password -s "$svc" -a "$acct" >/dev/null 2>&1; then
                print -u2 -- "opgate: no keychain item $svc/$acct"
                return 1
            fi
            print -r -- "deleted keychain://$svc/$acct"
            ;;
        ls|list)
            # Every keychain reference declared by a profile, and whether it
            # resolves. The keychain itself cannot be enumerated without a
            # prompt, so the profiles are the index.
            local profile env_file i var ref state found=0
            for profile in $(_opg_profiles); do
                env_file="$(_opg_profile_file "$profile")"
                _opg_parse "$env_file" || continue
                for (( i = 1; i <= ${#_opg_p_kc}; i += 2 )); do
                    found=1
                    var="${_opg_p_kc[i]}"; ref="${_opg_p_kc[i+1]}"
                    pair="$(_opg_kc_parse "$ref")" || { printf '%-14s %-22s %-34s %s\n' "$profile" "$var" "$ref" "malformed"; continue }
                    if _opg_kc_get "${pair%%$'\t'*}" "${pair#*$'\t'}"; then state="ok"; else state="MISSING"; fi
                    unset REPLY   # it holds the secret; nothing here wants it
                    printf '%-14s %-22s %-34s %s\n' "$profile" "$var" "$ref" "$state"
                done
            done
            (( found )) || print -u2 -- "opgate: no keychain:// references in any profile under $_opg_dir"
            ;;
        *)
            print -u2 -- "usage: opgate keychain set|rm|ls [<service>[/<account>]]"
            return 2
            ;;
    esac
}

_opg_template() {
    local auth_line="$1"
    cat <<EOF
# opgate profile — references only, never values.
${auth_line}
#
# One VAR per line. op:// and keychain:// refs resolve at runtime; plain values
# pass through. With a service account, reference items by vault and item ID —
# an op read by name costs 3 rate-limit requests, by ID it costs 1.
#EXAMPLE_TOKEN=op://<vault-id>/<item-id>/credential
#
# keychain:// reads the macOS login keychain: local, silent, never cached, and
# it needs no op session. Put a value in with: opgate keychain set <service>
#EXAMPLE_LOCAL_KEY=keychain://<service>
#EXAMPLE_URL=https://example.invalid
EOF
}

_opg_initcmd() {
    local profile="" account="" tokfile=""
    while (( $# )); do
        case "$1" in
            --account)    account="$2"; shift 2 ;;
            --token-file) tokfile="$2"; shift 2 ;;
            -*) print -u2 -- "opgate init: unknown option $1"; return 2 ;;
            *)  profile="$1"; shift ;;
        esac
    done
    if [[ -z "$profile" ]]; then
        print -u2 -- "usage: opgate init <profile> [--account <account> | --token-file <path>]"
        return 2
    fi
    if [[ -n "$account" && -n "$tokfile" ]]; then
        print -u2 -- "opgate init: --account and --token-file are mutually exclusive"
        return 2
    fi
    local env_file
    env_file="$(_opg_profile_file "$profile")"
    if [[ -e "$env_file" ]]; then
        print -u2 -- "opgate: profile '$profile' already exists at $env_file"
        return 1
    fi
    mkdir -p "$_opg_dir"
    chmod 700 "$_opg_dir" 2>/dev/null
    local auth_line="#"
    [[ -n "$account" ]] && auth_line="# opgate:account $account"
    [[ -n "$tokfile" ]] && auth_line="# opgate:token-file $tokfile"
    ( umask 077; _opg_template "$auth_line" >| "$env_file" )
    print -r -- "created $env_file — add your op:// references, then: opgate $profile <command>"
}

# Explicit interfaces keep account access separate from cached environment values.
_opg_select_profile() {
    local profile="$1"
    [[ "$profile" =~ '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' ]] || {
        print -u2 -- "opgate: invalid profile name"; return 2
    }
    REPLY="$(_opg_profile_file "$profile")"
    [[ -r "$REPLY" ]] || { print -u2 -- "opgate: no such profile '$profile'"; return 1 }
}

# Call only inside a child/subshell. Never modify the caller's authorization.
_opg_scrub_credentials() {
    local name
    for name in ${(k)parameters}; do
        case "$name" in
            OP_SESSION|OP_SESSION_*)
                [[ "${1:-0}" == 1 ]] || unset "$name" ;;
            OP_ACCOUNT|OP_SERVICE_ACCOUNT_TOKEN|OP_CONNECT_*|FNOX_*) unset "$name" ;;
        esac
    done
    return 0
}

_opg_auth_run() (
    local auth="$1" tokfile; shift
    # Never let an inherited service token select the wrong account.
    _opg_scrub_credentials "${_opg_preserve_sessions:-0}"
    case "$auth" in
        token\ *)
            tokfile="${auth#token }"
            [[ -r "$tokfile" && -s "$tokfile" ]] || {
                print -u2 -- "opgate: service account token is unavailable"; return 1
            }
            export OP_SERVICE_ACCOUNT_TOKEN="$(<"$tokfile")"
            [[ -n "${OP_SERVICE_ACCOUNT_TOKEN//[[:space:]]/}" ]] || {
                print -u2 -- "opgate: service account token is empty"; return 1
            }
            ;;
        account\ *) export OP_ACCOUNT="${auth#account }" ;;
        *) print -u2 -- "opgate: this interface requires an explicit account or token-file directive"; return 2 ;;
    esac
    "$@"
)

# --- approval holder -------------------------------------------------------
# The desktop-app integration ties an authorization to the process session
# `op` runs in: a terminal's for a human and — measured against op 2.35 with
# 1Password 8 on 2026-09-11 — the process session id when there is no tty.
# Agent harnesses (Claude Code, Codex) run every tool call in a fresh session
# with no tty, so each op call arrived as a new terminal and the app asked for
# Touch ID again, for every command:
#
#   op vault list                  no tty     NmRequestAuthorization, each shell
#   setsid op vault list           no tty     a new request (session-keyed)
#   op vault list </dev/ttys008    no tty     still a new request per shell
#   op inside one long-lived session         one request; later calls ride it
#
# So without a terminal on stdin, account-profile op calls go through a
# holder: a forked copy of the shell in its own session (a zpty child, which
# is what a terminal is to the kernel), keyed like the session cache — Claude Code
# session, else Codex thread, else the terminal app. It runs op on the
# caller's behalf and relays stdin, stdout, stderr and the exit status through
# 0600 files under the session directory. One approval per agent session. The
# holder exits with the session (`opgate flush --session`, the SessionEnd
# hook) or at the 12h session TTL, and keeps the approval from idling out with
# `op whoami` every OPGATE_APPROVAL_KEEPALIVE seconds (default 480, 0 = off).
# Service-account profiles never use it: they never prompt. A terminal on
# stdin never uses it: that terminal is already its own session.
# OPGATE_APPROVAL=call restores the bare call.
#
# Exposure, stated plainly: while the holder lives, any process running as
# this user that can write under the session directory can run op on the
# approved account through it. That is the class the terminal session and the
# session cache already sit in, not a new one — but it is the whole account,
# not one scoped vault, so agents that only need a service account should
# keep using one.

_opg_holder_dir() {
    local key
    key="$(_opg_session_key_raw)" || return 1
    print -r -- "$_opg_session_dir/${key}.holder"
}

# Both layers are forks of the caller and inherit every open descriptor,
# including the write end of whatever command substitution or pipe the
# caller was inside — which would then never see EOF. Close them all.
_opg_holder_close_fds() {
    local fd
    for fd in {3..255}; do exec {fd}>&- 2>/dev/null; done
    return 0
}

# Runs inside the holder, a zpty child: zpty forks the calling shell and
# evals its argument there, so every function and variable of the caller is
# already present — and so is the caller's EXIT trap, which must go first
# (a test suite's `rm -rf $work` on exit is the kind of thing it would run).
_opg_holder_main() {
    emulate -L zsh
    setopt local_options no_monitor no_notify
    local dir="$1" ttl="$2" keep="$3" q id acct cwd oppath tmo rc cpid waited tick
    local start=$SECONDS   # a zpty child inherits SECONDS; measure from here
    local -a argv envs
    local -A last_seen     # account -> SECONDS of its last op call or keepalive
    trap - EXIT; trap '' HUP
    _opg_vals=()   # no resolved values idle in a long-lived process
    _opg_holder_close_fds
    exec </dev/null >>"$dir/log" 2>&1 || exit 1
    # Read-write on the FIFO: never EOF when a writer leaves, and read -t can
    # wake on its own to check the TTL, the pid file, and the keepalive.
    exec {q}<>"$dir/queue" || exit 1
    print -r -- $$ >| "$dir/pid" || exit 1
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') holder $$ started: ttl=${ttl}s keepalive=${keep}s"
    tick=60; (( keep > 0 && keep < tick )) && tick=$keep
    while :; do
        (( ttl > 0 && SECONDS - start > ttl )) && { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') holder $$ exit: session TTL reached"; break }
        [[ -r "$dir/pid" && "$(<"$dir/pid")" == "$$" ]] || { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') holder $$ exit: pid file gone"; break }
        # A caller killed mid-wait leaves its request, result included, behind.
        rm -rf "$dir"/req-*(N/mm+10)
        id=""
        if ! read -r -t "$tick" -u $q id; then
            if (( keep > 0 )); then
                for acct in ${(k)last_seen}; do
                    (( SECONDS - last_seen[$acct] >= keep )) || continue
                    OP_ACCOUNT="$acct" command op whoami >/dev/null 2>&1
                    last_seen[$acct]=$SECONDS
                done
            fi
            continue
        fi
        [[ "$id" =~ '^[A-Za-z0-9._-]+$' && -r "$dir/req-$id/cmd" ]] || continue
        argv=() acct="" cwd="" oppath="" tmo=0
        source "$dir/req-$id/cmd"
        # op runs with the caller's environment, not the holder's: per-call
        # variables (OP_ACCOUNT, the fake's knobs in the test suite) must
        # reach it as if the caller had run op itself. Exported from inside
        # the child, never as env(1) arguments a process listing could show.
        # XPC_* are launchd's per-process markers, and exporting one from a
        # variable inside a forked zsh aborts the shell on macOS (zsh 5.9).
        envs=(${${(0)"$(<"$dir/req-$id/env")"}:#XPC_*})
        ( cd -q -- "${cwd:-/}" 2>/dev/null || cd -q /
          # op must see the caller's environment, not the holder's: the
          # long-lived holder inherited its spawner's env, and any variable of
          # its own would leak into every request (a preserved OP_SESSION, a
          # test's OP_FAKE_*). Clear our exports, then apply only the caller's
          # — the same environment op would have seen run in the caller. Values
          # go through the environment, never argv, so no secret reaches ps.
          local _v
          for _v in ${(k)parameters[(R)*export*]}; do unset "$_v" 2>/dev/null; done
          (( ${#envs} )) && export "${envs[@]}" 2>/dev/null
          exec "${oppath:-op}" "${argv[@]}" ) <"$dir/req-$id/in" >|"$dir/req-$id/out" 2>|"$dir/req-$id/err" &
        # Bounded, like _opg_capture: a request that never answers must not
        # take every later request on this holder down with it.
        cpid=$! waited=0
        while kill -0 $cpid 2>/dev/null; do
            if (( tmo > 0 && waited >= tmo * 5 )); then
                kill -TERM $cpid 2>/dev/null; command sleep 1; kill -KILL $cpid 2>/dev/null
                break
            fi
            command sleep 0.2; (( ++waited ))
        done
        wait $cpid 2>/dev/null; rc=$?
        (( tmo > 0 && waited >= tmo * 5 )) && rc=124
        # rc appears complete or not at all: the caller polls for the file.
        print -r -- "$rc" >| "$dir/req-$id/rc.tmp" && mv -f "$dir/req-$id/rc.tmp" "$dir/req-$id/rc"
        [[ -n "$acct" ]] && last_seen[$acct]=$SECONDS
    done
    rm -rf "$dir"/req-*(N)
    rm -f "$dir/pid"
    exit 0
}

# The outer of two zpty layers. zpty gives the holder its own session, the
# way a terminal does, but once the spawner is gone the pty's master side is
# closed — and on macOS any zsh started in a session whose pty master is
# closed blocks forever in open("/dev/tty") (measured: the test suite's fake
# op hung in open(2)). So this keeper opens a second pty for the real holder
# and holds its master until the holder exits. It runs nothing else, so the
# dead master of its own pty never bites it. It also drains that master once
# a second: a session leader's exit waits for its tty output to drain, and
# with nobody reading the holder sat in the kernel's exiting state forever.
_opg_holder_keeper() {
    emulate -L zsh
    local line
    trap - EXIT; trap '' HUP
    # zpty rebinds stdin and stdout to the pty but leaves stderr, which would
    # keep the spawner's terminal (or a test wrapper's pty) open for 12h.
    exec </dev/null >/dev/null 2>&1
    _opg_holder_close_fds
    zpty -b inner "_opg_holder_main ${(q)1} ${(q)2} ${(q)3}" || exit 1
    while zpty -t inner 2>/dev/null; do
        zpty -r inner line 2>/dev/null
        command sleep 1
    done
    exit 0
}

_opg_holder_spawn() {
    local dir="$1" name i=0
    zmodload zsh/zpty 2>/dev/null || return 1
    [[ -p "$dir/queue" ]] || mkfifo -m 600 "$dir/queue" || return 1
    : >| "$dir/log" && chmod 600 "$dir/log" || return 1
    rm -f "$dir/pid"
    name="opgh$$$RANDOM"
    zpty -b "$name" "_opg_holder_keeper ${(q)dir} ${_opg_session_ttl:-43200} ${OPGATE_APPROVAL_KEEPALIVE:-480}" || return 1
    while [[ ! -s "$dir/pid" ]] && (( i++ < 100 )); do sleep 0.05; done
    # The keeper ignores HUP; closing its master leaves both layers running.
    zpty -d "$name" 2>/dev/null
    [[ -s "$dir/pid" ]]
}

# REPLY: the holder directory, spawning the holder if this session has none.
_opg_holder_ensure() {
    local dir pid i=0 rc=0
    dir="$(_opg_holder_dir)" || return 1
    if [[ -r "$dir/pid" ]]; then
        pid="$(<"$dir/pid")"
        [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null && { REPLY="$dir"; return 0 }
    fi
    mkdir -p "$dir" && chmod 700 "$dir" || return 1
    # One spawner at a time; a second caller waits for the first's pid file.
    if ! mkdir "$dir/spawn.lock" 2>/dev/null; then
        while [[ -d "$dir/spawn.lock" ]] && (( i++ < 100 )); do sleep 0.05; done
        if [[ -r "$dir/pid" ]] && kill -0 "$(<"$dir/pid")" 2>/dev/null; then REPLY="$dir"; return 0; fi
        rmdir "$dir/spawn.lock" 2>/dev/null   # abandoned by a spawner that died
        mkdir "$dir/spawn.lock" 2>/dev/null || return 1
    fi
    # Another caller may have finished spawning between our check and the lock.
    if [[ -r "$dir/pid" ]] && kill -0 "$(<"$dir/pid")" 2>/dev/null; then
        rmdir "$dir/spawn.lock" 2>/dev/null; REPLY="$dir"; return 0
    fi
    _opg_holder_spawn "$dir" || rc=$?
    rmdir "$dir/spawn.lock" 2>/dev/null
    (( rc == 0 )) || { print -u2 -- "opgate: could not start the approval holder; running op directly"; return 1 }
    REPLY="$dir"
}

_opg_holder_stop() {
    local dir pid
    dir="$(_opg_holder_dir)" || return 0
    [[ -d "$dir" ]] || return 0
    if [[ -r "$dir/pid" ]]; then
        pid="$(<"$dir/pid")"
        [[ "$pid" == <-> ]] && kill -TERM "$pid" 2>/dev/null
    fi
    rm -rf "$dir"
}

# op takes a template or file on stdin for these; the holder must relay it.
_opg_op_reads_stdin() {
    local arg
    for arg in "$@"; do [[ "$arg" == - ]] && return 0; done
    case "$1 ${2:-}" in
        'item create'|'item edit'|'document create'|'document edit') return 0 ;;
    esac
    return 1
}

# Run one op command in the holder and relay its result.
_opg_holder_call() {
    local dir="$1" id req pid fd i=0 rc=1 tmo="${OPGATE_OP_TIMEOUT:-120}"; shift
    [[ "$tmo" == <-> ]] || tmo=120
    zmodload zsh/system 2>/dev/null || return 1
    pid="$(<"$dir/pid")" 2>/dev/null || return 1
    while :; do
        id="$$-$RANDOM$RANDOM"; req="$dir/req-$id"
        mkdir -m 700 "$req" 2>/dev/null && break
        (( i++ < 5 )) || return 1
    done
    if _opg_op_reads_stdin "$@" && [[ -p /dev/fd/0 || -f /dev/fd/0 ]]; then
        cat >| "$req/in"
    else
        : >| "$req/in"
    fi
    chmod 600 "$req/in"
    ( umask 077; /usr/bin/env -0 >| "$req/env" ) || { rm -rf "$req"; return 1 }
    print -r -- "argv=( ${(qq)@} ) acct=${(qq)${OP_ACCOUNT:-}} cwd=${(qq)PWD} oppath=${(qq)${commands[op]:-op}} tmo=${(qq)tmo}" >| "$req/cmd" || { rm -rf "$req"; return 1 }
    # Killed while waiting (the resolver's watchdog does that): take the
    # request, and the result the holder may still write into it, along.
    trap 'rm -rf "$req"; exit 143' TERM INT HUP
    # A non-blocking open fails with ENXIO when no holder keeps the FIFO open.
    if ! sysopen -w -o nonblock -u fd "$dir/queue" 2>/dev/null; then
        rm -rf "$req"; print -u2 -- "opgate: approval holder is gone"; return 1
    fi
    print -u $fd -r -- "$id"
    exec {fd}>&-
    i=0
    while [[ ! -e "$req/rc" ]]; do
        (( tmo > 0 && i >= tmo * 20 )) && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05; (( ++i ))
    done
    if [[ -e "$req/rc" ]]; then
        cat "$req/out"; cat "$req/err" >&2
        rc="$(<"$req/rc")"
        [[ "$rc" == <-> ]] || rc=1
    else
        print -u2 -- "opgate: approval holder did not answer"
        rc=1
    fi
    rm -rf "$req"
    return $rc
}

# Every op invocation that can prompt goes through here.
_opg_op() {
    if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN-}" && "${_opg_stdin_tty:-1}" == 0 \
          && "${OPGATE_APPROVAL:-session}" != (call|off|0) ]] && _opg_holder_ensure; then
        _opg_holder_call "$REPLY" "$@"
    else
        command op "$@"
    fi
}

_opg_approval_line() {
    local dir pid
    if [[ "${OPGATE_APPROVAL:-session}" == (call|off|0) ]]; then
        print -r -- "approval: per op call (OPGATE_APPROVAL=call)"
    elif (( ${_opg_stdin_tty:-1} )); then
        print -r -- "approval: this terminal"
    elif ! dir="$(_opg_holder_dir)"; then
        print -r -- "approval: per op call (no session key)"
    elif [[ -r "$dir/pid" ]] && pid="$(<"$dir/pid")" && kill -0 "$pid" 2>/dev/null; then
        print -r -- "approval: holder pid $pid for session ${${dir:t}%.holder}"
    else
        print -r -- "approval: holder starts on the first account call (session ${${dir:t}%.holder})"
    fi
}

_opg_invalidate() {
    # Publish before cache removal. Old in-flight resolves retain the old revision.
    local tmp
    mkdir -p "$_opg_persist_dir" || return 1
    chmod 700 "$_opg_persist_dir" || return 1
    tmp="$(umask 077; mktemp "$_opg_persist_dir/revision.XXXXXX")" || return 1
    # RANDOM can repeat in sibling zsh subshells. mktemp supplies a fresh name.
    ( umask 077; print -r -- "${tmp:t}" >| "$tmp" ) || return 1
    mv -f "$tmp" "$_opg_persist_dir/revision" || return 1
    _opg_flush
    _opg_init
}

_opg_native() {
    local profile="$1" env_file auth arg mutation=0 rc=0; shift
    _opg_select_profile "$profile" || return $?
    env_file="$REPLY"
    auth="$(_opg_auth "$env_file")" || return 1
    (( $# )) || { print -u2 -- "usage: opgate op --profile <name> -- <op arguments>"; return 2 }
    for arg in "$@"; do
        case "$arg" in
            --account|--account=*|--session|--session=*)
                print -u2 -- "opgate: select the account with --profile"; return 2 ;;
        esac
    done
    case "$1 ${2:-}" in
        'account list'|'account ls')
            # Device account inventory is metadata, not access to this profile's vaults.
            shift 2; _opg_accounts "$@"; return $? ;;
        'item get'|'item list'|'vault get'|'vault list'|'document get'|'document list'|'read '*|'whoami '*)
            ;;
        'item create'|'item edit'|'item delete'|'item archive'|'item move'|'item copy'|'document create'|'document edit'|'document delete')
            mutation=1 ;;
        *) print -u2 -- "opgate: supported operations are item/document reads and writes, vault reads, read, whoami, and account list"; return 2 ;;
    esac
    (( mutation )) && { _opg_invalidate || return 1 }
    _opg_auth_run "$auth" _opg_op "$@" || rc=$?
    # Invalidate on failure too: a timeout can follow a committed remote write.
    if (( mutation )); then
        _opg_invalidate || { print -u2 -- "opgate: cache invalidation failed after a vault operation"; return 1 }
    fi
    return $rc
}

_opg_session() {
    local profile="$1" env_file auth; shift
    _opg_select_profile "$profile" || return $?
    env_file="$REPLY"
    auth="$(_opg_auth "$env_file")" || return 1
    [[ "$auth" == account\ * ]] || { print -u2 -- "opgate: session requires an account profile"; return 2 }
    (( $# )) || { print -u2 -- "usage: opgate session --profile personal|work -- <command>"; return 2 }
    # Native desktop approval authorizes the account. Cached values cannot authorize it.
    _opg_auth_run "$auth" _opg_session_command "$@"
}

_opg_session_command() {
    _opg_op vault list --format=json >/dev/null || return $?
    "$@"
}

_opg_toml_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    print -rn -- "\"$value\""
}

_opg_fnox_validate() {
    _opg_parse "$1" || return 1
    (( ${#_opg_p_kc} == 0 )) || { print -u2 -- "opgate: fnox backend does not support keychain references; use native"; return 2 }
    local value var
    for var in "${_opg_p_names[@]}"; do
        case "$var" in OP_*|FNOX_*) print -u2 -- "opgate: reserved variable '$var' in fnox profile"; return 2 ;; esac
    done
    for value in "${_opg_p_refs[@]}" "${_opg_p_lit[@]}"; do
        [[ "$value" != *[\$\\]* ]] || { print -u2 -- "opgate: fnox backend requires values without shell expansion or escapes"; return 2 }
    done
    return 0
}

# Pure path calculation: listing must not generate configs or resolve secrets.
_opg_fnox_config_path() {
    local profile="$1" env_file="$2" ttl="${OPGATE_FNOX_TTL:-3600}" hash provider
    [[ "$ttl" == <-> ]] && (( ttl > 0 && ttl <= 86400 )) || {
        print -u2 -- "opgate: OPGATE_FNOX_TTL must be 1 through 86400 seconds"; return 2
    }
    hash="$(_opg_env_hash "$env_file")" || return 1
    provider="op_${_opg_revision//[^A-Za-z0-9_]/_}_$(( EPOCHSECONDS / ttl ))"
    REPLY="$_opg_persist_dir/fnox/config/$profile-$hash-$provider.toml"
}

_opg_fnox_profile_status() (
    local profile="$1" env_file="$2" auth
    (( ${+commands[fnox]} )) || { print 'not installed'; return }
    auth="$(_opg_auth "$env_file" 2>/dev/null)" || { print 'invalid profile'; return }
    [[ "$auth" == token\ * ]] && _opg_fnox_validate "$env_file" 2>/dev/null || {
        print 'unsupported'; return
    }
    _opg_fnox_config_path "$profile" "$env_file" 2>/dev/null || { print 'invalid TTL'; return }
    if [[ -r "$REPLY" ]]; then print 'configured'
    else
        local -a configs=("$_opg_persist_dir/fnox/config/$profile-"*.toml(N))
        if (( ${#configs} )); then print 'stale config'; else print 'unused'; fi
    fi
)

_opg_fnox_status() (
    (( ${+commands[fnox]} )) || { print 'fnox daemon: not installed'; return }
    _opg_scrub_credentials
    export FNOX_CONFIG_DIR="$_opg_persist_dir/fnox/config"
    export FNOX_STATE_DIR="$_opg_persist_dir/fnox/state"
    export XDG_RUNTIME_DIR="$_opg_persist_dir/fnox/runtime"
    export FNOX_PROFILE=default
    local OPGATE_OP_TIMEOUT=2 report entries
    if ! _opg_capture command fnox --config "$FNOX_CONFIG_DIR/status.toml" --non-interactive --if-missing error daemon status 2>/dev/null; then
        print 'fnox daemon: unavailable'; return
    fi
    report="$REPLY"
    case "$report" in
        'fnox daemon not running') print 'fnox daemon: stopped' ;;
        'fnox daemon running'$'\n'*)
            entries="${report##*$'\n'cached_entries: }"
            if [[ "$entries" == <-> ]]; then
                print -r -- "fnox daemon: running; $entries cached entries (shared; per-profile warmth unknown)"
            else print 'fnox daemon: running; cache count unknown'; fi ;;
        *) print 'fnox daemon: unknown status' ;;
    esac
)

_opg_fnox_config() {
    local profile="$1" env_file="$2" i
    _opg_fnox_validate "$env_file" || return $?
    _opg_fnox_config_path "$profile" "$env_file" || return $?
    local file="$REPLY" provider="${${REPLY:t}#${profile}-}"
    provider="${${provider#*-}%.toml}"
    local dir="$_opg_persist_dir/fnox" tmp
    mkdir -p "$dir/config" "$dir/state" "$dir/runtime" || return 1
    chmod 700 "$dir" "$dir/config" "$dir/state" "$dir/runtime" || return 1
    # Immutable config names prevent concurrent callers from replacing each other's config.
    if [[ ! -r "$file" ]]; then
        tmp="$(umask 077; mktemp "$dir/config/build.XXXXXX")" || return 1
        (
            umask 077
            print -r -- '[daemon]'
            print -r -- 'enabled = true'
            print -r -- 'idle_timeout = "1h"'
            print -r -- "[providers.$provider]"
            print -r -- 'type = "1password"'
            print -r -- '[providers.literal]'
            print -r -- 'type = "plain"'
            print -r -- '[secrets]'
            for (( i = 1; i <= ${#_opg_p_refs}; i += 2 )); do
                print -rn -- "${_opg_p_refs[i]} = { provider = \"$provider\", value = "
                _opg_toml_string "${_opg_p_refs[i+1]}"
                print -r -- ' }'
            done
            for (( i = 1; i <= ${#_opg_p_lit}; i += 2 )); do
                print -rn -- "${_opg_p_lit[i]} = { provider = \"literal\", value = "
                _opg_toml_string "${_opg_p_lit[i+1]}"
                print -r -- ' }'
            done
        ) >| "$tmp" || { rm -f "$tmp"; return 1 }
        mv -f "$tmp" "$file" || return 1
    fi
    REPLY="$file"
}

_opg_capture_print() {
    _opg_capture "$@" || return $?
    print -rn -- "$REPLY"
}

_opg_account_exec() {
    # Explicit human environment delivery must consult native authorization.
    # Literal-only and keychain-only profiles never reach op through _opg_load.
    _opg_op vault list --format=json >/dev/null || return $?
    local OPGATE_NO_SESSION_CACHE=1
    _opg_vals=() _opg_names=() _opg_kcnames=() _opg_mtime=() _opg_hash=()
    _opg_run "$@"
}

_opg_fnox_resolve() {
    local file="$1"
    export FNOX_CONFIG_DIR="$_opg_persist_dir/fnox/config"
    export FNOX_STATE_DIR="$_opg_persist_dir/fnox/state"
    export XDG_RUNTIME_DIR="$_opg_persist_dir/fnox/runtime"
    export FNOX_PROFILE=default
    _opg_capture command fnox --config "$file" --non-interactive --if-missing error exec -- /usr/bin/env -0 || return $?
    print -rn -- "$REPLY"
}

_opg_fnox_exec() {
    local profile="$1" env_file auth file hash dump kv var; shift
    _opg_select_profile "$profile" || return $?
    env_file="$REPLY"
    auth="$(_opg_auth "$env_file")" || return 1
    [[ "$auth" == token\ * ]] || { print -u2 -- "opgate: fnox caching requires a service account profile"; return 2 }
    (( ${+commands[fnox]} )) || { print -u2 -- "opgate: install fnox to use this backend"; return 1 }
    _opg_fnox_config "$profile" "$env_file" || return $?
    file="$REPLY"
    hash="$(_opg_env_hash "$env_file")" || return 1
    _opg_retry_wait "fnox-$profile" "$hash" && return 1
    dump="$(_opg_auth_run "$auth" _opg_fnox_resolve "$file")" || {
        _opg_retry_record "fnox-$profile" "$hash"; return 1
    }
    rm -f "$(_opg_retry_file "fnox-$profile")" "$_opg_persist_dir/fnox-$profile.retry"
    local -A values
    for kv in ${(0)dump}; do
        var="${kv%%=*}"
        (( ${_opg_p_names[(Ie)$var]} )) && values[$var]="${kv#*=}"
    done
    local -a assigns
    for var in "${_opg_p_names[@]}"; do
        (( ${+values[$var]} )) || { print -u2 -- "opgate: fnox did not resolve '$var'"; return 1 }
        assigns+=("$var=${values[$var]}")
    done
    # The selected application receives values, never the resolver's service token.
    (
        _opg_scrub_credentials
        # Bare export prints the inherited environment, including unrelated secrets.
        if (( ${#assigns} )); then export "${assigns[@]}"; fi
        "$@"
    )
}

_opg_explicit() {
    local mode="$1" profile="" backend=native; shift
    while (( $# )); do
        case "$1" in
            -h|--help) _opg_help "$mode"; return $? ;;
            --profile|--backend)
                (( $# >= 2 )) || { print -u2 -- "opgate: missing option value"; return 2 }
                if [[ "$1" == --profile ]]; then profile="$2"; else backend="$2"; fi
                shift 2 ;;
            --) shift; break ;;
            *) print -u2 -- "opgate: expected --profile <name> [--backend native|fnox] -- <command>"; return 2 ;;
        esac
    done
    # Only exact help forms bypass authentication. Do not mistake option values
    # (for example an item title of '--help') for a request to display help.
    if [[ "$mode" == op ]] && _opg_is_native_help "$@"; then
        ( _opg_scrub_credentials; command op "$@" ); return $?
    fi
    [[ -n "$profile" && $# -gt 0 ]] || { print -u2 -- "opgate: profile and command are required (opgate $mode --help)"; return 2 }
    [[ "$backend" == (native|fnox) ]] || { print -u2 -- "opgate: unknown backend '$backend'"; return 2 }
    _opg_select_profile "$profile" || return $?
    if [[ "$mode" != exec && "$backend" != native ]]; then
        print -u2 -- "opgate: --backend applies only to exec"; return 2
    fi
    case "$mode" in
        op) _opg_native "$profile" "$@" ;;
        session) _opg_session "$profile" "$@" ;;
        exec)
            local _opg_clean_child=1
            if [[ "$backend" == fnox ]]; then _opg_fnox_exec "$profile" "$@"
            else
                local auth
                auth="$(_opg_auth "$REPLY")" || return 1
                [[ "$auth" != default ]] || {
                    print -u2 -- "opgate: explicit exec requires an account or token-file directive"; return 2
                }
                if [[ "$auth" == account\ * ]]; then
                    _opg_auth_run "$auth" _opg_account_exec "$profile" "$@"
                else
                    _opg_run "$profile" "$@"
                fi
            fi ;;

    esac
}

_opg_is_native_help() {
    case "$*" in
        --help|-h|'item --help'|'item -h'|'vault --help'|'vault -h'|'document --help'|'document -h'|'account --help'|'account -h'|'read --help'|'read -h'|'whoami --help'|'whoami -h')
            # The argument count prevents quoted command strings from matching.
            (( $# <= 2 )) || return 1 ;;
        *)
            (( $# == 3 )) && [[ "$3" == (-h|--help) ]] || return 1
            case "$1 $2" in
                'item get'|'item list'|'item create'|'item edit'|'item delete'|'item archive'|'item move'|'item copy'|'vault get'|'vault list'|'document get'|'document list'|'document create'|'document edit'|'document delete'|'account list'|'account ls') ;;
                *) return 1 ;;
            esac ;;
    esac
    return 0
}

_opg_accounts() (
    while (( $# )); do
        case "$1" in
            -h|--help) _opg_help accounts; return $? ;;
            --format=json|--format=table) break ;;
            --format)
                [[ "${2:-}" == (json|table) ]] && (( $# == 2 )) && break
                print -u2 'opgate accounts: use --format json|table'; return 2 ;;
            *) print -u2 'opgate accounts: use --format json|table'; return 2 ;;
        esac
    done
    if (( $# > 1 )) && [[ "$1" != --format ]]; then
        print -u2 'opgate accounts: unexpected arguments'; return 2
    fi
    # account list inspects local CLI account metadata. It does not sign in or
    # enumerate service accounts, and must not inherit resolver credentials.
    local -a native_args=("$@")
    # 1Password calls its table format "human-readable".
    if [[ "${1:-}" == --format=table ]]; then native_args=(--format=human-readable)
    elif [[ "${1:-}" == --format && "${2:-}" == table ]]; then native_args=(--format human-readable)
    fi
    _opg_scrub_credentials
    command op account list "${native_args[@]}"
)

_opg_help() {
    case "${1:-}" in
        '') _opg_usage ;;
        exec) cat <<'EOF'
usage: opgate exec --profile <name> [--backend native|fnox] -- <command> [args...]
Inject the profile's environment values into one command.
native is the default. fnox requires a service-account profile with static references.
Account profiles require native approval. Help never requests approval.
Example: opgate exec --profile agent --backend fnox -- some-tool
EOF
            ;;
        op) cat <<'EOF'
usage: opgate op --profile <name> -- <op arguments>
Read or change items/documents, list/read vaults, read a reference, or run whoami.
Use account list for local CLI account metadata, not service-account vault permissions.
Writes invalidate local caches. Results can contain secrets; consume them within the command.
Examples:
  opgate op --profile agent -- vault list
  opgate op --profile agent -- item list --vault agents
  opgate op -- item create --help
EOF
            ;;
        session) cat <<'EOF'
usage: opgate session --profile personal|work -- <command> [args...]
Request native approval for the selected account, then start the command.
Requires an account profile; service-account profiles cannot open account sessions.
Native approval can expire or be revoked during the command.
Without a terminal on stdin the approval lives in this session's holder; the
command inherits it only for op calls it makes through opgate, not for bare op.
Example: opgate session --profile personal -- codex
EOF
            ;;
        accounts|account) cat <<'EOF'
usage: opgate accounts [--format json|table]
alias: opgate account list [--format json|table]
List users and accounts configured in the local 1Password CLI, without signing in.
This is not a list of service accounts or vault permissions.
Use opgate ls for environment profiles, or opgate op --profile agent -- vault list for accessible vaults.
EOF
            ;;
        ls|list) cat <<'EOF'
usage: opgate ls
List profiles, environment sources, native cache state, and fnox configuration state.
The fnox footer shows its isolated daemon and shared cache entry count.
configured means the current fnox configuration exists; it does not prove cached values exist for that profile.
Listing never resolves secrets, starts the daemon, or requests 1Password approval.
EOF
            ;;
        init) print 'usage: opgate init <profile> [--account <account> | --token-file <path>]'; print 'Create a new reference profile without overwriting an existing profile.' ;;
        read) print 'usage: opgate read <VAR>'; print 'Print one native cached value without invoking 1Password. Do not print secrets in agent transcripts.' ;;
        approve) print 'usage: opgate approve'; print 'Sign in and warm all native profile caches. This can request approval and consume provider requests.' ;;
        flush) print 'usage: opgate flush [--session]'; print 'Invalidate both local backends. --session removes only the current native session cache.' ;;
        invalidate) print 'usage: opgate invalidate'; print 'Invalidate local caches after external or remote vault changes. This does not synchronize machines.' ;;
        keychain) print 'usage: opgate keychain set|rm|ls [<service>[/<account>]]'; print 'Manage keychain references. set reads a secret through protected input; ls reports availability without values.' ;;
        version) print 'usage: opgate version | --version'; print 'Print the installed opgate version.' ;;
        help) print 'usage: opgate help [command]'; print 'Commands also accept -h and --help.' ;;
        *) print -u2 -- "opgate: unknown help topic '$1'"; return 2 ;;
    esac
}

_opg_usage() {
    cat <<'EOF'
opgate — scoped, cached 1Password secrets for shells and AI agents

usage:
  opgate <profile> [--] <command> [args...]   run command with the profile's secrets
  opgate exec --profile <name> [--backend native|fnox] -- <command>
                                              inject selected environment values
  opgate op --profile <name> -- <op arguments>  read or change vault items
  opgate session --profile personal|work -- <command>
                                              approve native account access
  opgate invalidate                           invalidate all local profile caches
  opgate ls                                   list profiles and native/fnox cache state
  opgate accounts [--format json|table]        list local CLI accounts (no sign-in)
  opgate account list                        alias for accounts
  opgate read <VAR>                           print one value (never invokes op)
  opgate approve                              sign in and warm every profile
  opgate flush [--session]                    drop caches (--session: this session only)
  opgate init <profile> [--account <a> | --token-file <f>]
                                              scaffold a new profile
  opgate keychain set|rm|ls [<service>[/<account>]]
                                              manage the macOS keychain source
  opgate help [command] | version
  opgate <command> --help                    command help without authentication

Profiles live in $OPGATE_DIR (default ~/.config/opgate) as <name>.env files of
references, never values. Two sources resolve, mixable in one profile:

  VAR=op://<vault>/<item>/field         1Password
  VAR=keychain://<service>[/<account>]  macOS login keychain (account: $USER)

Sourcing opgate.zsh in an interactive shell also defines one op<profile>
convenience function per profile (opagents, oppersonal, ...).
EOF
}

opgate() {
    # -L: default zsh semantics for the whole call tree, whatever options the
    # calling shell runs with (no_unset, err_return, sh_word_split, ...).
    emulate -L zsh
    _opg_init
    local cmd="${1:-}"
    # Handle help before any command that could authenticate, mutate, or read values.
    case "$cmd" in
        ls|list|accounts|account|read|approve|flush|invalidate|init|keychain|version|help)
            if [[ "${2:-}" == (-h|--help) ]]; then _opg_help "$cmd"; return $?; fi ;;
    esac
    if [[ "$cmd" == keychain && "${3:-}" == (-h|--help) ]]; then _opg_help keychain; return $?; fi
    case "$cmd" in
        ""|-h|--help) _opg_usage ;;
        help) shift; (( $# <= 1 )) || { print -u2 'usage: opgate help [command]'; return 2; }; _opg_help "${1:-}" ;;
        version|-v|--version) print -r -- "opgate $OPGATE_VERSION" ;;
        ls|list)  _opg_ls ;;
        accounts) shift; _opg_accounts "$@" ;;
        account)
            shift
            [[ "${1:-}" == (list|ls) ]] || { _opg_help accounts >&2; return 2; }
            shift; _opg_accounts "$@" ;;
        exec|op|session) shift; _opg_explicit "$cmd" "$@" ;;
        invalidate) _opg_invalidate ;;
        keychain) shift; _opg_keychain "$@" ;;
        read)     shift; _opg_read "$@" ;;
        approve)  shift; _opg_approve "$@" ;;
        flush)
            shift
            # The holder goes with the caches here, never on invalidate: vault
            # writes invalidate, and a write must not cost the next approval.
            _opg_holder_stop
            if [[ "${1:-}" == (--session|-s) ]]; then _opg_flush "$@"
            else _opg_invalidate; fi ;;

        init)     shift; _opg_initcmd "$@" ;;
        *)
            shift
            [[ "$1" == -- ]] && shift
            _opg_run "$cmd" "$@"
            ;;
    esac
}

# One convenience function per profile — `opagents ...` for profile `agents` —
# defined only where they don't shadow an existing command or function.
# OPGATE_NO_FUNCTIONS=1 disables. Profile names are already filesystem-safe;
# only [A-Za-z0-9_] names can become functions.
if [[ -z "${OPGATE_NO_FUNCTIONS:-}" ]]; then
    _opg_init
    for _opg_p in $(_opg_profiles); do
        [[ "$_opg_p" =~ '^[A-Za-z0-9_]+$' ]] || continue
        (( ${+commands[op$_opg_p]} || ${+functions[op$_opg_p]} )) && continue
        eval "op${_opg_p}() { opgate ${_opg_p} \"\$@\" }"
    done
    unset _opg_p
fi
