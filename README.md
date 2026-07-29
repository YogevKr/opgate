# opgate

Scoped, cached 1Password secrets for shells and AI agents.

`opgate` hands secrets to exactly one command, resolved at runtime from
1Password — never exported into your shell, never written into dotfiles —
and caches them so you approve once per session instead of once per call.
Its reason to exist: give AI coding agents a **scoped** path to the secrets
they need, with no route to everything else your 1Password session can read.

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
opgate ls                                   profiles, auth mode, cache state
opgate read <VAR>                           print one cached value (never invokes op)
opgate approve                              sign in and warm every profile
opgate flush [--session]                    drop caches (--session: this session only)
opgate init <profile> [--account <a> | --token-file <f>]
```

Sourcing the plugin also defines `op<profile>` functions (`opagents`,
`oppersonal`, ...) for each profile — skipped silently if the name would
shadow an existing command. Profile names `ls`, `list`, `read`, `approve`,
`flush`, `init`, `help`, and `version` are reserved.

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

Editing a profile invalidates every tier for it. `opgate flush` drops
everything and forces a fresh approval.

`opgate read VAR` is the launchd/cron shape: it prints a cached value and can
never invoke `op` (under launchd, op hangs waiting for GUI auth rather than
failing). Pair it with `opgate approve` from an interactive session.

## Security model, honestly

opgate is a scoping and ergonomics tool, not a sandbox:

- Resolved values are cached in 0600 files owned by you. Anything running
  **as your user** can read them. The mitigation is scoping: keep agent
  profiles on service-account tokens over single-purpose vaults, so what
  leaks is bounded by what the profile could reach anyway.
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
execution-boundary thinking in [Automic Vault](https://www.automicvault.com/);
the push to actually build it came from
[@kunchenguid's](https://x.com/kunchenguid) machines-agents-and-secrets setup.

## License

MIT
