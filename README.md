# opgate

[![test](https://github.com/YogevKr/opgate/actions/workflows/test.yml/badge.svg)](https://github.com/YogevKr/opgate/actions/workflows/test.yml)

Scoped, cached secrets for shells and AI agents, from 1Password and the macOS
keychain.

`opgate` provides three access modes:

- Personal account access uses native 1Password approval.
- Work account access uses separate native 1Password approval.
- Unattended agents use a service account restricted to the `agents` vault.

The agent service account needs `read_items,write_items` to read, create, edit,
and delete items. 1Password enforces these permissions. Environment profiles
select variables; they do not define vault permissions.

```sh
# Start an agent with personal or work account access.
opgate session --profile personal -- codex
opgate session --profile work -- claude

# Query or change items without loading a fixed list of environment variables.
opgate op --profile agent -- item list --vault agents
opgate op --profile agent -- item get <item-id> --vault agents
opgate op --profile agent -- item edit <item-id> --vault agents

# Give selected environment values to one command.
opgate exec --profile agent --backend fnox -- some-tool
opgate exec --profile agent --backend native -- some-tool
```

The existing `opgate <profile> <command>` and `op<profile>` shortcuts remain
available. They load environment values through the original cache system.
They do not open full account sessions. Use `opgate session` for that purpose.

## Help and discovery

Help does not require a profile, credentials, or native approval:

```sh
opgate --help
opgate exec --help
opgate op --help
opgate session --help
opgate help accounts
opgate op -- item create --help
```

All built-in commands accept `-h` and `--help`. Explicit modes accept help before
the `--` command delimiter. Arguments after that delimiter belong to the child.
Exact native help forms such as `item create --help` also bypass authentication
and cache invalidation. Failed help preserves the native exit code.

```sh
opgate accounts
opgate accounts --format json
opgate account list
opgate op --profile agent -- account list
opgate ls
opgate op --profile agent -- vault list
```

`accounts` lists user accounts configured in the local 1Password CLI. It does not
sign in, list service accounts, or prove vault access. The scoped `account list`
form returns the same device metadata without loading the profile's token.
Use `ls` for environment profiles and `vault list` for accessible vaults.

Profile listing labels native cache state separately from fnox configuration.
The fnox column reports `configured`, `stale config`, `unused`, `unsupported`,
or configuration errors. `configured` means the current configuration file exists;
it does not prove that the daemon holds that profile's values.

The footer queries the isolated fnox daemon without resolving values or starting
the daemon. It reports stopped, unavailable, or running with a shared cache count.
Fnox exposes only an aggregate count, so per-profile cache warmth remains unknown.
The probe has a two-second timeout. No listing command makes secret-provider reads.
See the [fnox daemon status implementation](https://github.com/jdx/fnox/blob/v1.35.1/src/commands/daemon.rs).

## Authentication

Profiles live in `~/.config/opgate/<name>.env`. Each explicit access mode needs
one authentication directive:

```sh
# ~/.config/opgate/agent.env
# opgate:token-file ~/.config/opgate/agent.token
HA_TOKEN=op://<vault-id>/<item-id>/token
```

```sh
# ~/.config/opgate/personal.env
# opgate:account my.1password.com
```

The `agents` vault must be a separate vault within the personal account.
A service account cannot access the built-in Personal or Private vault.
The profile name can be `agent`, `agents`, or another name.

1Password cannot change an existing service account's vault permissions.
Create a replacement account for write access. Keep the existing account
until both machines use the replacement and pass their checks.
See [service account management](https://www.1password.dev/service-accounts/manage-service-accounts).

`opgate session` checks native account access before starting its command.
It ignores inherited service account tokens, Connect credentials, and CLI
session tokens. The child receives the selected account name. Native desktop
approval remains responsible for account authorization.

Native approval expires after ten minutes of inactivity, after twelve hours,
or when 1Password locks. Starting another terminal also requires approval.
The wrapper does not extend these limits or use secret caches as approval.
See [native approval rules](https://www.1password.dev/cli/app-integration-security).

### One approval per agent session

The desktop app ties an approval to the process session `op` runs in. For a
human that is the terminal. An agent tool call is a fresh process session with
no terminal, so each `op` call from an agent arrived as a new terminal and
1Password asked for Touch ID again, for every command.

Without a terminal on stdin, opgate runs account-profile `op` calls through a
holder: one small zsh process per session, in its own process session, keyed
like the session cache (Claude Code session, else Codex thread, else the
terminal app). The holder runs `op` on the caller's behalf and relays stdin,
stdout, stderr, and the exit status. Approve once, and every later
`opgate op`, `opgate session`, `opgate exec`, or profile resolve from that
agent session reuses the approval.

- The holder exits with the session (`opgate flush --session`, the SessionEnd
  hook) or at the 12h session TTL.
- It sends `op whoami` every `OPGATE_APPROVAL_KEEPALIVE` seconds (default
  480) so the approval does not idle out. `0` turns the keepalive off.
- Service-account profiles never use it; they never prompt. A shell with a
  terminal on stdin never uses it; that terminal is already its own session.
- Without a terminal, `opgate session` approves the holder, not the child's
  own process session. The child inherits the approval for `op` calls it
  makes through opgate (`opgate op`, `opgate exec`, profile shortcuts). A
  bare `op` inside the child still runs in its own session and prompts.
- A request is bounded by `OPGATE_OP_TIMEOUT` inside the holder too, so one
  unanswered call cannot block the calls behind it.
- `OPGATE_APPROVAL=call` restores the bare per-call behavior.
- `opgate ls` reports the holder state. Vault writes through `opgate op`
  invalidate caches but keep the holder.

Exposure: while the holder lives, any process running as this user that can
write under the session directory can run `op` on the approved account
through it. That is the class the terminal session and the session cache
already sit in, but it is the whole account, not one scoped vault. Agents
that only need a service account should keep using one.

## fnox backend

Install [fnox](https://fnox.jdx.dev/providers/1password.html) separately:

```sh
brew install fnox
opgate exec --profile agent --backend fnox -- some-tool
```

The adapter requires a service account profile. It generates configuration from
the existing references and literals. It does not copy the service account
token into that configuration. It removes resolver credentials before starting
the selected command. That command can access its injected secret values.

The adapter uses an isolated fnox configuration directory and daemon state
under `$OPGATE_CACHE_DIR/fnox`. It selects a dedicated daemon runtime directory
through `XDG_RUNTIME_DIR`. The daemon caches resolved values in memory.
Generated configuration contains references and literals. fnox does not write
resolved values to its cache. The bounded resolver can use a temporary 0600
capture file, which it removes when resolution finishes.

`OPGATE_FNOX_TTL` sets the maximum cache reuse period in seconds. It defaults
to 3600 and accepts 1 through 86400. Time periods determine cache identity,
so a value can refresh earlier than the maximum. The daemon exits after one
hour without requests. A restart requires another provider read.

A failed resolution shares the existing retry delay across processes.
Command failures do not set this delay. fnox can fall back from a failed
batch read to individual reads within the first attempt.

This adapter supports static `op://` references and literals. It rejects
`keychain://` references, shell expansion, escapes, and `OP_*` or `FNOX_*`
variable names. Use the native backend for those profiles. fnox uses its own
text resolution rules; do not use this adapter for binary secret values.

## Writes and invalidation

`opgate op` supports item and document reads and writes, vault reads,
`read`, and `whoami`. Select the account with `--profile`; account overrides
inside native arguments are rejected.
`account list` and `account ls` return local CLI account metadata without authentication.

Writes invalidate local profile caches before and after the native operation.
Failures also invalidate caches because the remote operation might have finished.
A revision marker invalidates caches in other shells and changes fnox cache
identity. In-flight reads can finish, but later calls reject their old cache
revision. Writes affect all local profiles to cover shared references.

```sh
# Run after changing an item outside opgate.
opgate invalidate
# A full flush also invalidates both backends.
opgate flush
```

Native vault queries and writes make 1Password requests. Use cached environment
injection for repeated programmatic reads.

Invalidation applies to the current machine and cache directory. Changes on
another machine need local invalidation or the next cache expiration.
Writes can overlap reads; this interface does not provide transactional reads.
Version 0.4 uses separate cache filenames. It can read older cache files before
the first invalidation. Reload existing shell functions after installation;
older loaded versions cannot enforce the new invalidation rules.

The fnox adapter currently uses memory caching. Existing native persistent
caches remain available for scripts that need restart survival. Encrypted
`fnox sync` snapshots need a separate key and refresh policy; this adapter
does not create or manage them.

## Two sources

A profile holds references, never values, and two schemes resolve. Mix them in
one file:

```sh
API_KEY=op://<vault-id>/<item-id>/credential   # 1Password
SIGNING_KEY=keychain://my-signing-key          # macOS login keychain
BASE_URL=https://example.invalid               # literal, passed through
```

`keychain://<service>` reads a generic-password item, with the account
defaulting to `$USER`; write `keychain://<service>/<account>` to be explicit.
Put a value in with `opgate keychain set`, which prompts rather than taking an
argument — a secret in `argv` lands in shell history and in `ps` output:

```sh
opgate keychain set my-signing-key       # prompts, echo off
op read "op://Private/Old Item/token" | opgate keychain set my-signing-key
```

The keychain is the local-only source: no account, no network, no `op`. A
profile with no `op://` reference never invokes `op` at all, so it works on a
machine with no 1Password installed and cannot prompt for Touch ID. Use it for
secrets that are bound to this machine anyway and should never leave it; use
`op://` for anything you need on a second machine, want to rotate centrally, or
want to share.

Two things follow from how the keychain works, and both are deliberate:

- **Keychain values are never cached.** Reading one is silent and local, so
  there is no approval to amortise — and opgate's caches are 0600 plaintext, so
  mirroring a keychain value into one would strip exactly the encryption at rest
  you kept it there for. They are resolved on every call.
- **An SSH session cannot read them.** The login keychain is not unlocked for a
  non-GUI login, so `security` fails there. That is a property of the keychain,
  not of opgate: on a headless box, use `op://` with a service account.

## Install

```sh
brew install yogevkr/tap/opgate
```

Then add to `.zshrc` (optional but recommended — enables the in-memory cache
tier and the `op<profile>` convenience functions):

```sh
source "$(brew --prefix)/share/opgate/opgate.zsh"
```

Without sourcing, the `opgate` binary works standalone from any shell — bash,
`bash -lc` agent harnesses, cron, launchd.

## Quickstart

```sh
# a profile riding your op session
opgate init personal --account my.1password.com
$EDITOR ~/.config/opgate/personal.env      # add VAR=op://... lines
opgate personal env | grep MY_VAR          # first call resolves + caches

# a scoped profile for agents (the whole point)
op vault create agents                     # move agent-needed items into it
op service-account create agents --vault agents:read_items,write_items
# save the printed token: umask 077; $EDITOR ~/.config/opgate/agents.token
opgate init agents --token-file ~/.config/opgate/agents.token
$EDITOR ~/.config/opgate/agents.env
opgate agents some-tool                    # no prompts, ever
```

Reference items **by vault and item ID** in service-account profiles
(`op://<vault-id>/<item-id>/field`): a by-name `op read` costs 3 rate-limit
requests, by-ID costs 1 — and consumer-plan service accounts get 1,000
requests/day. With opgate's caching you will use a few dozen.

## Commands

```
opgate exec --profile <name> [--backend native|fnox] -- <command>
opgate op --profile <name> -- <op arguments>
opgate session --profile personal|work -- <command>
opgate invalidate                          invalidate local caches after a vault change
opgate <profile> [--] <command> [args...]   run command with the profile's secrets
opgate ls                                   profiles, source, cache state
opgate accounts [--format json|table]         local CLI accounts; no sign-in
opgate help [command]                        help without authentication
opgate read <VAR>                           print one value (never invokes op)
opgate approve                              sign in and warm every profile
opgate flush [--session]                    drop caches (--session: this session only)
opgate init <profile> [--account <a> | --token-file <f>]
opgate keychain set <service>[/<account>]   store a value (prompts, echo off)
opgate keychain rm  <service>[/<account>]   delete it
opgate keychain ls                          every keychain:// ref, and whether it resolves
```

There is no `keychain get`: printing a secret is what a wrapped command is for,
and `ls` tells you a reference resolves without putting the value on a terminal.

Sourcing the plugin also defines `op<profile>` functions (`opagents`,
`oppersonal`, ...) for each profile — skipped silently if the name would
shadow an existing command. Profile names `ls`, `list`, `read`, `approve`,
`flush`, `init`, `keychain`, `exec`, `op`, `session`, `accounts`, `account`, `invalidate`, `help`, and
`version` are reserved.

## How the caching works

1Password CLI authorization lasts 10 idle minutes per terminal; agent
harnesses run every command in a fresh shell. Uncached, that is one approval
prompt per tool call. Two mechanisms remove it. The approval holder (above)
makes every account `op` call from an agent session count as one terminal
session. On top of that, opgate stacks three tiers in front of `op run`:

1. **Shell memory** — non-exported assoc arrays. Children only see values for
   the lifetime of a wrapped command, same as plain `op run`.
2. **Session file** — 0600 under `$TMPDIR`, keyed by the session the shell
   belongs to: a Claude Code session (`CLAUDE_CODE_SESSION_ID`), else a Codex
   thread (`CODEX_THREAD_ID`), else the terminal app (found by walking the
   process tree past intermediate shells). One approval per session, 12h TTL —
   matching op's own hard session cap.
3. **Persistent** — 0600 under `~/.cache/opgate`, surviving reboots. **Off by
   default**; set `OPGATE_CACHE_TTL_DAYS=<n>` on machines where approving is
   expensive (a headless box over SSH, where op's desktop-app integration
   cannot prompt), not on a laptop with Touch ID one keypress away.

The tiers exist to amortise an approval prompt, so they cover `op://` values
only; `keychain://` values skip all three and are read fresh every call.

Editing a profile invalidates every tier for it. `opgate flush` drops
everything and forces a fresh approval.

`opgate read VAR` is the launchd/cron shape: it prints a value without ever
invoking `op` (under launchd, op hangs waiting for GUI auth rather than
failing). For `op://` values that means cache-only, so pair it with `opgate
approve` from an interactive session; `keychain://` values it resolves
directly, since `security` fails fast instead of hanging.

## Security model, honestly

opgate is a scoping and ergonomics tool, not a sandbox:

- Resolved values are cached in 0600 files owned by you. Anything running
  **as your user** can read them. The mitigation is scoping: keep agent
  profiles on service-account tokens over single-purpose vaults, so what
  leaks is bounded by what the profile could reach anyway. Keychain values
  are exempt — they are never cached.
- The keychain **stores** a secret better than a 0600 file, but it does not
  gate who reads it: anything running as you can call `security` too. What it
  buys is encryption at rest and no plaintext copy on disk, not an approval
  boundary. A tool that does enforce per-executable approval, from a signed
  app, is [Automic Vault](https://www.automicvault.com/) — opgate is not that,
  and does not pretend to be.
- Writing a keychain value keeps it out of `security`'s argv: `-w` given last,
  with no value, makes `security` read the secret from stdin instead. Its own
  man page is blunt about the alternative — *"Use of the -p or -w options is
  insecure."* A multiline value is the exception, because that prompt is
  line-based and fails its own retype check, so those still pass through argv.
  macOS hides one user's argv from another, so even then the exposure is to
  processes running as you — the same boundary everything else here sits inside.
  Reads never go through argv.
- `op run`'s stdout masking is bypassed (the internal resolve is captured,
  never printed) — but a wrapped command that *prints* a secret lands it in
  scrollback or an agent transcript, same as any tool.
- A service-account token file is a bearer credential for its vault. 0600 it,
  keep the vault minimal, and revoke/recreate to rotate.

Knobs: `OPGATE_DIR` (profile dir), `OPGATE_SESSION_CACHE=agents` (disk cache
only for agent sessions, terminals stay memory-only), `OPGATE_SESSION_CACHE=off`
or `OPGATE_NO_SESSION_CACHE=1` (no disk caching at all), `OPGATE_SESSION_KEY`
(pin a cache key explicitly), `OPGATE_SESSION_TTL` (seconds, default 43200).

Failed resolves share a one-hour retry delay across processes. Cache hits still
work during this delay. Cold profiles fail without another 1Password request;
stale fallback keeps its existing behavior. Set `OPGATE_RETRY_SECONDS=0` to retry
immediately, or set another delay in seconds. A profile content change or a full
`opgate flush` clears the delay. Retry files contain a timestamp, profile hash, and cache revision,
with no secret values. Concurrent requests already in progress can still finish.

## Development

```sh
zsh test/run.zsh    # fake op; no 1Password account needed
zsh test/discovery.zsh # fake CLIs; help, metadata, and bounded status checks
zsh test/fnox.zsh   # real fnox, fake op; skips when fnox is unavailable
```

## Acknowledgements

Extracted from the author's dotfiles. The scoped-agent-credentials shape owes
a debt to [1Password service
accounts](https://developer.1password.com/docs/service-accounts/) and to the
execution-boundary thinking in [Automic Vault](https://www.automicvault.com/),
which is also where the keychain-as-a-source idea comes from; the push to
actually build it came from [@kunchenguid's](https://x.com/kunchenguid)
machines-agents-and-secrets setup.

## License

MIT
