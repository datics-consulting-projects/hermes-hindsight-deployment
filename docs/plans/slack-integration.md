# Slack integration — backoffice agent

How the backoffice agent gets a Slack channel, what part of that lives in git, and what is
left. Supersedes [implementation plan §6](hermes-backoffice-agent-implementation-plan.md), which
predates the per-agent `:ro` mounts and guesses at config keys this build does not have.

**Status as of 2026-08-20:** the repo side is built and deployed. The Slack side has not started —
no app exists, no tokens, no channel. One discovery item blocks the credential wiring.

Defects and unresolved questions live in [slack-integration issues](../issues/slack-integration.md)
(S1–S8). The plan deviation it represents is [G8](../issues/gap-register.md#g8--slack-opens-before-the-readerwriter-split).

---

## 1. Shape of the thing

Slack runs in **Socket Mode** — the container opens an outbound WebSocket to Slack. There is no
inbound port, no webhook URL, no reverse proxy. **`docker-compose.yml` does not change at all**,
and the Tailscale-only posture is untouched.

Everything that can be a committed file is one. What cannot is named, with the reason.

| Piece | Lives in | Why there |
|---|---|---|
| Scopes, events, DM settings | `agents/backoffice/slack-manifest.yaml` | **Not mounted.** Hermes never reads it — it is the artifact pasted into Slack's App Manifest tab. In git so a widened permission is a reviewable diff instead of an invisible click in Slack's UI. |
| What the agent may *do* on Slack | `agents/backoffice/config.yaml` → `platform_toolsets.slack` | Already mounted `:ro`. Edit, commit, deploy — no `hermes config set` on the server. |
| How the agent behaves on Slack | `agents/backoffice/SOUL.md` | Mounted `:ro`. Mention-only and in-thread are stated there as persona; the manifest is what *enforces* them. |
| The three tokens | `agents/backoffice/.env` (gitignored) | Per-agent, not root `.env`: the compose `environment:` list is container-wide, so a second persona would inherit this bot's identity and be able to post as it. |
| Who may talk to it | `hermes pairing`, in the volume — **and possibly `SLACK_ALLOWED_USERS`/`SLACK_ALLOWED_CHANNELS`** | The pairing store is runtime state, not config: audit it, do not expect to review it in git. The env vars, if read, would make the allowlist declarable — [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread). |
| The Slack app itself | api.slack.com | Four UI steps. `apps.manifest.create` exists but needs a configuration token that rotates every 12 hours — not worth a rotating secret for one app. |

## 2. What discovery established

Run against the deployed build on 2026-08-20. These findings replaced guesses; each cost a probe,
so they are recorded rather than re-derived.

- **There is no `channels:` config key.** Plan §6.3's `channels.slack.respondTo: mention` does not
  exist in this build. But the gate may exist as an **environment variable** —
  `SLACK_REQUIRE_MENTION` and friends are in the install; see §4 and
  [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread).
- **Slack is credentialed by environment variable, not by config.** `SLACK_BOT_TOKEN`,
  `SLACK_APP_TOKEN` and `SLACK_SIGNING_SECRET` are read from the environment, which is why the
  per-agent `.env` is the right home and no `config.yaml` change is needed for credentials.
- **`hermes slack` only generates manifests.** Slack is configured by `hermes gateway setup`.
- **Authorization is `hermes pairing list|approve|revoke`**, not an allowlist config key.
- **`platform_toolsets:` is the per-platform tool map**, written by
  `hermes tools disable --platform slack …`. This is the load-bearing restriction.
- **`agent.disabled_toolsets` works**, but it is profile-wide (it would strip the dashboard too)
  and toolset names must match the build's own list exactly — `file`, not `files`. A wrong name is
  silently ignored.
- **`hermes config set` is schemaless.** It accepts keys nothing reads, and `config get` reports an
  unknown key and a real-but-unset key identically. A key present in `config.yaml` is no evidence
  anything reads it.
- **Every bare `hermes` command targets the `default` profile**, which is not the profile the stack
  runs. Pass `-p backoffice`, and pass it **after** the subcommand — a leading `-p` dies in the
  container entrypoint.

## 3. What is built

Committed and deployed:

- `agents/backoffice/slack-manifest.yaml` — minimal scopes (`app_mentions:read`, `chat:write`,
  `channels:history`), Socket Mode on, interactivity off, all App Home tabs off, `app_mention` as
  the only bot event.
- `agents/backoffice/config.yaml` — the full `platform_toolsets` map pinned, with
  `slack: [clarify, memory, session_search, skills, todo]`; `memory.write_approval: true`;
  `agent.disabled_toolsets: [browser]`; the discovery findings above recorded inline.
- `agents/backoffice/.env.example` — the three Slack token slots, commented, with the reason they
  are per-agent rather than container-wide.
- `agents/backoffice/SOUL.md` — Slack named as a surface, mention-only and in-thread stated,
  "Slack is somewhere you talk, not a system you can search".
- `scripts/deploy.sh` — ssh → `git pull --ff-only` → `docker compose up -d` →
  **`docker compose restart hermes`** → status + log tail. The restart is mandatory, not
  cosmetic: `git pull` swaps inodes and single-file bind mounts do not follow.
- `scripts/slack-preflight.sh` — `discover` (probe the build), `check` (tokens present and live),
  `verify` (post-deploy).
- `scripts/.env.example` — `HERMES_SSH`, `HERMES_DIR`.

Verified live: `hermes config get platform_toolsets -p backoffice` returns exactly the committed
map, which proves the `:ro` mount is read and the deploy took.

## 4. Mention-only rests on one thing — probably two

The manifest subscribes to `app_mention` and nothing else, so Slack never delivers the channel's
other messages. **Today that is the whole mechanism** — there is no `channels:` config key.

There is likely a second: `SLACK_REQUIRE_MENTION`, `SLACK_STRICT_MENTION` and
`SLACK_THREAD_REQUIRE_MENTION` exist in the install as environment variables, as do
`SLACK_ALLOWED_USERS` and `SLACK_ALLOWED_CHANNELS`. If they are read from the environment, this
repo can set them in the per-agent `.env` and mention-only stops being single-point.
**Until [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread) confirms it,
assume it is single-point.**

Two consequences:

- Adding `message.channels` to the manifest is not a formality. It is the single decision that puts
  every message in the channel in front of the agent.
- The test that matters is the *silent* one. A misparsed config fails **open** — the agent answers
  everyone — so "it replied when mentioned" proves nothing on its own.

## 5. Remaining steps

**5.1 — Settle the Slack environment variables.** `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` and
`SLACK_SIGNING_SECRET` are confirmed present, so credentials are unblocked. What remains is the
**behaviour gates** — `SLACK_REQUIRE_MENTION`, `SLACK_ALLOWED_USERS`, `SLACK_ALLOWED_CHANNELS`,
`SLACK_DISABLE_DMS`, and the two that fail open (`SLACK_ALLOW_ALL_USERS`,
`SLACK_FREE_RESPONSE_CHANNELS`). Confirm which are env-read and what they default to:
[S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread) carries both probes.

This does not block creating the Slack app. It blocks the `/invite` in 5.6.

**5.2 — Port the confirmed gates into git.** Add them to `agents/backoffice/.env.example` with
what each one does, so the Slack posture is reviewable in a diff rather than living in the VPS
`.env` alone. Deploy.

**5.3 — Create the Slack app.** api.slack.com/apps → Create New App → **From a manifest** → paste
`agents/backoffice/slack-manifest.yaml`. Then: enable Socket Mode (→ `xapp-`), Install to Workspace
(→ `xoxb-`), Basic Information → Signing Secret.

**5.4 — Install the tokens** into `agents/backoffice/.env` **on the VPS**. They never enter git.
Note [S6](../issues/slack-integration.md#s6--slack-preflightsh-check-reads-the-wrong-env):
`slack-preflight.sh check` currently reads the local file.

**5.5 — Deploy and confirm the restriction landed.**

```sh
./scripts/deploy.sh
docker exec -it hermes hermes tools --summary -p backoffice
```

This is the decisive check for [S2](../issues/slack-integration.md#s2--no-slack-section-in-tools---summary--p-backoffice).
A Slack row at 5/28 means the pinned map applies. 18/28, or still no Slack row once Slack is
actually configured, means the restriction is not landing — **stop before the `/invite`**.

**5.6 — `/invite` to exactly one channel.** The bot cannot read channels it was not invited to, so
the invite *is* the scope. Then `hermes pairing list` — approve named people, never
`GATEWAY_ALLOW_ALL_USERS=true`.

**5.7 — Run the controls.** In order of what they actually prove:

| # | Action | Expected | Proves |
|---|---|---|---|
| 1 | Post in the channel **without** mentioning the bot | silence | mention-only holds |
| 2 | @-mention from a **non-paired** account | no reply | pairing is enforced |
| 3 | @-mention from a paired account | reply, **in-thread** | the surface works |
| 4 | Ask it to run a shell command or read a file | refusal / no such tool | `platform_toolsets.slack` holds |
| 5 | "Remember that X" | staged for review, not committed | `memory.write_approval` — see [S3](../issues/slack-integration.md#s3--memorywrite_approval-is-unverified) |

1, 2 and 4 are the negative tests. They are the ones worth actually running.

## 6. Deliberately not done

- **No DM scopes, no App Home messages tab.** Plan §6.2: a DM is a second, unwitnessed surface. The
  dashboard already covers private one-to-one use, over Tailscale.
- **No `commands` scope.** Hermes registers its gateway commands as native slashes, and among them
  are `/yolo`, `/approvals off` and `/memory approval off` — any channel member could disable the
  guardrails from inside Slack. Omitting the scope is what prevents that. See
  [S5](../issues/slack-integration.md#s5--slash-commands-would-let-channel-members-disable-the-guardrails).
- **No `interactivity`.** Nothing needs buttons or modals, and each one is another entry point.
- **No second channel, no second persona.** One channel is the pilot.

## 7. Closing conditions

Slack is open ahead of the reader/writer split (plan §10.1), which is the accepted deviation
recorded as [G8](../issues/gap-register.md#g8--slack-opens-before-the-readerwriter-split). The
interim holds only while all of these are true:

- one channel, membership audited via `hermes pairing list`
- `platform_toolsets.slack` stays at five toolsets, re-checked after every Hermes upgrade
- **§4 (Notion/CRM tools) does not ship to this profile first.** Not a preference: the moment
  `crm_*` tools reach the Slack-facing agent, the exact path §10.1 exists to close is open.
- someone actually reads the memory review queue — an unread queue is a rubber stamp
