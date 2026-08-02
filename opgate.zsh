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

# All state lives here rather than at file scope: some agent harnesses
# (Claude Code) snapshot the shell by dumping functions and exported env, so
# plain globals set at source time are gone by the time a tool call runs.
typeset -g OPGATE_VERSION=0.2.0

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
    [[ -n "${_opg_dir:-}" ]]         || typeset -g _opg_dir="${OPGATE_DIR:-$HOME/.config/opgate}"
    [[ -n "${_opg_session_dir:-}" ]] || typeset -g _opg_session_dir="${TMPDIR:-/tmp}/opgate-session"
    [[ -n "${_opg_session_ttl:-}" ]] || typeset -g _opg_session_ttl="${OPGATE_SESSION_TTL:-43200}"   # 12h
    [[ -n "${_opg_persist_dir:-}" ]] || typeset -g _opg_persist_dir="${OPGATE_CACHE_DIR:-$HOME/.cache/opgate}"
    typeset -g _opg_persist_ttl=$(( ${OPGATE_CACHE_TTL_DAYS:-0} * 86400 ))
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
    typeset -ga _opg_p_names _opg_p_kc _opg_p_op _opg_p_lit
    typeset -g  _opg_p_needop
    _opg_p_names=() _opg_p_kc=() _opg_p_op=() _opg_p_lit=() _opg_p_needop=0
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
    [[ -n "${_opg_session_key_cached:-}" ]] && { print -r -- "$_opg_session_key_cached"; return 0 }
    local key
    _opg_cache_enabled || return 1
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
    print -r -- "$_opg_session_dir/${key}.${1}"
}

# Blob layout: "#mtime <env-file mtime>", "#ts <resolved at>", then
# "<VAR> <base64 value>" per variable, then "#end". The trailer proves the
# blob is complete, and base64 keeps it inert data rather than sourceable code.
_opg_blob_encode() {
    local profile="$1" var
    print -r -- "#mtime ${_opg_mtime[$profile]}"
    print -r -- "#ts $EPOCHSECONDS"
    for var in ${=_opg_names[$profile]}; do
        print -r -- "$var $(printf '%s' "${_opg_vals[$profile:$var]}" | base64 | tr -d '\n')"
    done
    print -r -- "#end"
}

# Reads a blob on stdin. max_age 0 means "don't check" (the file tier stamps
# freshness with the file's own mtime instead).
_opg_blob_decode() {
    local profile="$1" env_mtime="$2" max_age="${3:-0}"
    local line var enc decoded ended=0 ts=0
    local -a names
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        var="${line%% *}"
        enc="${line#* }"
        case "$var" in
            '#mtime') [[ "$enc" == "$env_mtime" ]] || return 1; continue ;;
            '#ts')    ts="$enc"; continue ;;
            '#end')   ended=1; continue ;;
        esac
        [[ "$enc" =~ '^[A-Za-z0-9+/=]+$' ]] || return 1
        # trailing-X sentinel: command substitution eats trailing newlines
        decoded="$(print -r -- "$enc" | base64 -d 2>/dev/null; printf X)"
        _opg_vals[$profile:$var]="${decoded%X}"
        names+=("$var")
    done
    (( ended && ${#names} )) || return 1
    if (( max_age > 0 )); then
        (( ts > 0 && EPOCHSECONDS - ts < max_age )) || return 1
    fi
    _opg_names[$profile]="${(j: :)names}"
    _opg_mtime[$profile]="$env_mtime"
}

_opg_session_read() {
    local profile="$1" env_mtime="$2" file file_mtime
    file="$(_opg_session_file "$profile")" || return 1
    [[ -r "$file" ]] || return 1
    file_mtime="$(zstat +mtime "$file" 2>/dev/null)" || return 1
    if (( EPOCHSECONDS - file_mtime >= _opg_session_ttl )); then
        rm -f "$file"
        return 1
    fi
    _opg_blob_decode "$profile" "$env_mtime" < "$file"
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
_opg_persist_file() { print -r -- "$_opg_persist_dir/${1}.cache" }

_opg_persist_read() {
    local profile="$1" env_mtime="$2" file
    (( _opg_persist_ttl > 0 )) || return 1
    _opg_cache_enabled || return 1
    file="$(_opg_persist_file "$profile")"
    [[ -r "$file" ]] || return 1
    _opg_blob_decode "$profile" "$env_mtime" "$_opg_persist_ttl" < "$file"
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

    # Nothing here needs op: the remaining values are literals that op would
    # hand back unchanged, so resolve them and leave `op` — which may not even
    # be installed — alone.
    if (( _opg_p_needop == 0 )); then
        for (( i = 1; i <= ${#_opg_p_lit}; i += 2 )); do
            _opg_vals[$profile:${_opg_p_lit[i]}]="${_opg_p_lit[i+1]}"
        done
        _opg_names[$profile]="${(j: :)names}"
        _opg_mtime[$profile]="$mtime"
        _opg_session_write "$profile"
        _opg_persist_write "$profile"
        return 0
    fi

    local auth
    auth="$(_opg_auth "$env_file")" || return 1
    # Resolve through op run itself so semantics match exactly; --no-masking
    # only affects this internal dump, which is captured, never printed.
    local dump tokfile
    case "$auth" in
        token\ *)
            tokfile="${auth#token }"
            if [[ ! -r "$tokfile" ]]; then
                print -u2 -- "opgate: missing service-account token: $tokfile"
                return 1
            fi
            dump="$(OP_SERVICE_ACCOUNT_TOKEN="$(<"$tokfile")" op run --no-masking --env-file="$env_file" -- /usr/bin/env -0)" || return 1
            ;;
        account\ *)
            dump="$(OP_ACCOUNT="${auth#account }" op run --no-masking --env-file="$env_file" -- /usr/bin/env -0)" || return 1
            ;;
        *)
            dump="$(op run --no-masking --env-file="$env_file" -- /usr/bin/env -0)" || return 1
            ;;
    esac
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
    _opg_session_write "$profile"
    _opg_persist_write "$profile"
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
    ( export "${assigns[@]}"; exec "$@" )
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
        rm -f "$_opg_session_dir/${key}."*(N)
    fi
    [[ "$1" == (--session|-s) ]] && return 0
    for profile in $(_opg_profiles); do
        rm -f "$(_opg_persist_file "$profile")" 2>/dev/null
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
            eval "$(op signin --account "$account" 2>/dev/null)" 2>/dev/null
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
    local profile env_file auth state mtime nvars
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
        printf '%-14s %-38s %2s vars   %s\n' "$profile" "[${auth}]" "$nvars" "$state"
    done
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

_opg_usage() {
    cat <<'EOF'
opgate — scoped, cached 1Password secrets for shells and AI agents

usage:
  opgate <profile> [--] <command> [args...]   run command with the profile's secrets
  opgate ls                                   list profiles, source, cache state
  opgate read <VAR>                           print one value (never invokes op)
  opgate approve                              sign in and warm every profile
  opgate flush [--session]                    drop caches (--session: this session only)
  opgate init <profile> [--account <a> | --token-file <f>]
                                              scaffold a new profile
  opgate keychain set|rm|ls [<service>[/<account>]]
                                              manage the macOS keychain source
  opgate help | version

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
    case "$cmd" in
        ""|help|-h|--help) _opg_usage ;;
        version|-v|--version) print -r -- "opgate $OPGATE_VERSION" ;;
        ls|list)  _opg_ls ;;
        keychain) shift; _opg_keychain "$@" ;;
        read)     shift; _opg_read "$@" ;;
        approve)  shift; _opg_approve "$@" ;;
        flush)    shift; _opg_flush "$@" ;;
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
