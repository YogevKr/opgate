# opgate

[![test](https://github.com/YogevKr/opgate/actions/workflows/test.yml/badge.svg)](https://github.com/YogevKr/opgate/actions/workflows/test.yml)

Scoped, cached secrets for shells and AI agents, from 1Password and the macOS
keychain.

`opgate` hands secrets to exactly one command, resolved at runtime — never
exported into your shell, never written into dotfiles — and caches them so you
approve once per session instead of once per call. Its reason to exist: give AI
coding agents a **scoped** path to the secrets they need, with no route to
everything else your 1Password session can read.

```sh
opgate agents curl -H "Authorization: Bearer $HA_TOKEN" http://ha.local/api/
opagents buzz post ...        # same thing — one convenience function per profile
```

## Why

If you run coding agents (Claude Code, Codex, ...) with low-friction
permissions, two bad options present themselves:

- **Export secrets in your shell** — every descendant process inherits them,
  including sandboxed agent jobs; sandboxes govern files and network, not the
  environment they were handed.
- **Give agents your `op` session** — `op run` keeps values out of the env,
  but a cached session can read *your entire account*. An agent that can run
  `op item get` can print your bank card.

`opgate` splits the difference with **profiles**. A profile is an env file of
`op://` references plus one directive saying how it authenticates:

```sh
# ~/.config/opgate/agents.env
# opgate:token-file ~/.config/opgate/agents.token
HA_TOKEN=op://<vault-id>/<item-id>/token
PERPLEXITY_API_KEY=op://<vault-id>/<item-id>/credential
```

A `token-file` profile authenticates with a [1Password service
account](https://developer.1password.com/docs/service-accounts/) that can
read **exactly one vault**. Agents get `opgate agents <cmd>`: no Touch ID, no
desktop-app prompts, headless-safe — and structurally unable to reach
anything outside that vault. Your own profiles keep riding your normal `op`
session:

```sh
# ~/.config/opgate/personal.env
# opgate:account my.1password.com
GITHUB_TOKEN=op://Private/GitHub PAT/token
```

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
op service-account create agents --vault agents:read_items
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
opgate <profile> [--] <command> [args...]   run command with the profile's secrets
opgate ls                                   profiles, source, cache state
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
`flush`, `init`, `keychain`, `help`, and `version` are reserved.

## How the caching works

1Password CLI authorization lasts 10 idle minutes per terminal; agent
harnesses run every command in a fresh shell. Uncached, that is one approval
prompt per tool call. opgate stacks three tiers in front of `op run`:

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

## Development

```sh
zsh test/run.zsh    # hermetic — uses a fake `op`, no 1Password account needed
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
