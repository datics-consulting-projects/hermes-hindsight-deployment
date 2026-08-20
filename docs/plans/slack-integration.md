# Slack integration — backoffice agent

How the backoffice agent gets a Slack channel, what part of that lives in git, and what is
left. Supersedes [implementation plan §6](hermes-backoffice-agent-implementation-plan.md), which
predates the per-agent `:ro` mounts and guesses at config keys this build does not have.

**Status as of 2026-08-20:** the app exists, the three tokens are installed on the VPS, and the
toolset restriction is verified live (`Slack 5/28`). The behaviour gates have now been read out of
the build and pinned — [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread)
is resolved, and mention-only is no longer single-point. What is left is the `/invite`, blocked by
this plan's own sequencing on two things: one observation that the pinned block is actually applied
([S10](../issues/slack-integration.md#s10--the-slack-block-is-committed-but-unverified)), and the
pilot channel's id, which nothing can supply until the channel is chosen
([S11](../issues/slack-integration.md#s11--todo--slackallowed_channels-is-empty-so-the-invite-is-the-only-channel-scope)). Steps 5.5a and 5.6 are the only ones outstanding.

Defects and unresolved questions live in [slack-integration issues](../issues/slack-integration.md)
(S1–S11). The plan deviation it represents is [G8](../issues/gap-register.md#g8--slack-opens-before-the-readerwriter-split).

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
| How the agent behaves *on Slack* | `agents/backoffice/config.yaml` → top-level `slack:` | Mounted `:ro`. Mention gating, DMs, bots and the channel scope, bridged into the `SLACK_*` variables the adapter reads. In git, so tightening or loosening the Slack posture is a reviewable diff. **The environment overrides this file**, so no gate here may also appear in `.env`. |
| Who may talk to it | `hermes pairing`, in the volume — plus `SLACK_ALLOWED_USERS` in `agents/backoffice/.env` | The pairing store is runtime state, not config: audit it, do not expect to review it in git. `SLACK_ALLOWED_USERS` is the declarable companion, and the one Slack gate with no config key — `gateway/authz_mixin.py` reads it straight from the environment. |
| The Slack app itself | api.slack.com | Four UI steps. `apps.manifest.create` exists but needs a configuration token that rotates every 12 hours — not worth a rotating secret for one app. |

## 2. What discovery established

Run against the deployed build on 2026-08-20. These findings replaced guesses; each cost a probe,
so they are recorded rather than re-derived.

- **There is no `channels:` config key** — but there is a top-level `slack:` one. Plan §6.3's
  `channels.slack.respondTo: mention` does not exist in this build; `slack.require_mention` does,
  along with the rest of the behaviour gates, bridged into `SLACK_*` environment variables by the
  Slack plugin. **The environment wins over the file.** See §4 and
  [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread).
- **Slack is credentialed by environment variable, not by config.** `SLACK_BOT_TOKEN` and
  `SLACK_APP_TOKEN` are read from the environment, which is why the per-agent `.env` is the right
  home and no `config.yaml` change is needed for credentials. `SLACK_SIGNING_SECRET` is set
  alongside them but read by nothing in this build — Socket Mode has no inbound HTTP request to
  verify a signature on.
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
  `agent.disabled_toolsets: [browser, bfl, kanban]`; the discovery findings above recorded inline.
  The last two entries were added after both toolsets appeared on Slack *despite* being absent from
  the map — [S8](../issues/slack-integration.md#s8--toolsets-that-bypass-platform_toolsets).
  Since 2026-08-20 it also carries the top-level `slack:` block — the behaviour gates, pinned with
  each default recorded next to it, `allowed_channels` alone left commented for want of a channel
  id.
- `agents/backoffice/.env.example` — the three Slack token slots, commented, with the reason they
  are per-agent rather than container-wide; `SLACK_ALLOWED_USERS`, the one gate that cannot live in
  `config.yaml`; and a "never set these" list naming each variable that would undo the posture.
- `agents/backoffice/SOUL.md` — Slack named as a surface, mention-only and in-thread stated,
  "Slack is somewhere you talk, not a system you can search".
- `scripts/deploy.sh` — ssh → `git pull --ff-only` → `docker compose up -d` →
  **`docker compose restart hermes`** → status + log tail. The restart is mandatory, not
  cosmetic: `git pull` swaps inodes and single-file bind mounts do not follow.
- `scripts/slack-preflight.sh` — `discover` (probe the build), `check` (tokens present and live),
  `verify` (post-deploy).
- `scripts/.env.example` — `HERMES_SSH`, `HERMES_DIR`.

Verified live: `hermes config get platform_toolsets -p backoffice` returns exactly the committed
map, which proves the `:ro` mount is read and the deploy took. Verified again after the app was
credentialed: `tools --summary -p backoffice` reports **Slack 5/28**, listing exactly those five —
so the map is not merely stored, it is applied
([S2](../issues/slack-integration.md#s2--whether-the-slack-toolset-restriction-is-applied)).

## 4. Mention-only rests on two things

**First layer, and still the strong one.** The manifest subscribes to `app_mention` and nothing
else, so Slack never delivers the channel's other messages. Nothing that is not a mention reaches
the container at all.

**Second layer, added 2026-08-20.** `require_mention`, `strict_mention`,
`thread_require_mention` and `ignore_other_user_mentions` are pinned in the `slack:` block of
`agents/backoffice/config.yaml`, and the adapter reads them on every message. `strict_mention` is
the one that earns its place: it disables the auto-triggers — mentioned-thread memory, bot-message
follow-up, session-presence — that answer a message which never mentioned the bot. A thread is
where mention-only leaks first.

The second layer is **inert today by construction**: with only `app_mention` delivered, there is
nothing for it to reject. That is what it is for. Defaults for three of those four are `false`, so
this was a gap that would have opened silently — see
[S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread) for the full table.

Three consequences:

- Adding `message.channels` to the manifest is no longer the single decision that puts every
  message in the channel in front of the agent — the gates now catch what it lets through. It is
  still a decision to make deliberately, not a formality.
- **Neither layer is verified end-to-end yet.** Until
  [S10](../issues/slack-integration.md#s10--the-slack-block-is-committed-but-unverified) closes,
  the second layer is committed rather than proven, and the honest posture is the old one.
- The test that matters is the *silent* one. A misparsed config fails **open** — the agent answers
  everyone — so "it replied when mentioned" proves nothing on its own.

## 5. Remaining steps

**5.1 — Settle the Slack environment variables. DONE 2026-08-20.** Twelve gates read out of the
build with their defaults; three of the four mention gates default `false` and `allowed_channels`
defaults to *no restriction*. The full table, the mechanism and the two corrections it produced are
in [S9](../issues/slack-integration.md#s9--the-slack-behaviour-gates-are-unread).

**5.2 — Port the confirmed gates into git. DONE 2026-08-20, but not where this step said.** They
went into the top-level `slack:` block of `agents/backoffice/config.yaml`, not
`agents/backoffice/.env.example`. The reason is better than the original plan's: `config.yaml` is
mounted and committed, so the gates are reviewable in a diff **with their real values**, whereas
`.env.example` is a template whose live counterpart never enters git. `SLACK_ALLOWED_USERS` is the
single exception and stays in `.env`, because `gateway/authz_mixin.py` reads it from the
environment and no config key exists for it.

**Do not set a gate in both places.** The environment overrides `config.yaml`, silently, and the
losing line still looks like a setting.

**5.3 — Create the Slack app. DONE 2026-08-20.** api.slack.com/apps → Create New App → **From a
manifest** → paste `agents/backoffice/slack-manifest.yaml`. Then, in this order: Basic Information
→ App Credentials → Signing Secret; Basic Information → App-Level Tokens → Generate Token and
Scopes with the **`connections:write`** scope (→ `xapp-`); Install App → Install to Workspace
(→ `xoxb-`, and any scope change afterwards means a reinstall and a new one).

**5.4 — Install the tokens. DONE 2026-08-20**, into `agents/backoffice/.env` **on the VPS**. They
never enter git. Note [S6](../issues/slack-integration.md#s6--slack-preflightsh-check-reads-the-wrong-env):
`slack-preflight.sh check` reads the *local* file, so the tokens were validated from the VPS with
`auth.test` and `apps.connections.open` directly — both `"ok": true`. The second is the only call
that proves Socket Mode is genuinely on.

**5.5 — Deploy and confirm the restriction landed. DONE 2026-08-20.**

```sh
./scripts/deploy.sh
docker exec -it hermes hermes tools --summary -p backoffice
```

**Read the Slack row's contents, not its count.** The first run returned 7/28 — the five pinned
toolsets plus `kanban` and `bfl`, neither of which is in the map
([S8](../issues/slack-integration.md#s8--toolsets-that-bypass-platform_toolsets)). Adding both to
`agent.disabled_toolsets` brought it to **5/28**, and no execution toolset appears on Slack:
that is the pass condition, and it settles
[S2](../issues/slack-integration.md#s2--whether-the-slack-toolset-restriction-is-applied).
A Slack row carrying File Operations, Terminal, Code Execution or Web means the restriction is not
landing — **stop before the `/invite`**.

What this does *not* establish: `tools --summary` renders configuration back at you, not the
gateway's runtime behaviour. Control 4 in 5.7 is the only test of that path.

**5.5a — Prove the `slack:` block is applied. BLOCKS 5.6.** Everything in 5.2 is committed and
traced through the source; nothing has observed this deployment applying it, which is the same
posture that made [S3](../issues/slack-integration.md#s3--memorywrite_approval-is-unverified) an
issue rather than a mitigation. `allow_bots` is the one gate that announces itself in the log, so
it is the probe: set it to `"mentions"`, deploy, grep the log for the `[Slack] allow_bots=` line,
then **revert to `"none"` and deploy again**. Full recipe and the failure branch in
[S10](../issues/slack-integration.md#s10--the-slack-block-is-committed-but-unverified).

**5.6 — `/invite` to exactly one channel. BLOCKED ON 5.5a.** The bot cannot read channels it was
not invited to, so the invite *is* the scope. Two things to do at the same moment, because this is
the first point at which either is possible:

- Uncomment `slack.allowed_channels` in `agents/backoffice/config.yaml` with the channel's `C…` id
  (open the channel in Slack → right-click the name → Copy link), commit and deploy **before** the
  invite. Empty means *every* channel, so until this is filled in a stray second invite is live
  rather than inert — [S11](../issues/slack-integration.md#s11--todo--slackallowed_channels-is-empty-so-the-invite-is-the-only-channel-scope) carries the step and its test.
- `hermes pairing list` — approve named people, never `GATEWAY_ALLOW_ALL_USERS=true`. Optionally
  mirror those member ids into `SLACK_ALLOWED_USERS` in the VPS `.env` as a second, declarable
  gate.

**5.7 — Run the controls.** In order of what they actually prove:

| # | Action | Expected | Proves |
|---|---|---|---|
| 1 | Post in the channel **without** mentioning the bot | silence | mention-only holds |
| 2 | @-mention from a **non-paired** account | no reply | pairing is enforced |
| 3 | @-mention from a paired account | reply, **in-thread** | the surface works |
| 4 | Ask it to run a shell command or read a file | refusal / no such tool | `platform_toolsets.slack` holds |
| 5 | "Remember that X" | staged for review, not committed | `memory.write_approval` — see [S3](../issues/slack-integration.md#s3--memorywrite_approval-is-unverified) |
| 6 | Ask it to generate a video, then to create a kanban card | refusal / no such tool | the [S8](../issues/slack-integration.md#s8--toolsets-that-bypass-platform_toolsets) bypass is actually closed at runtime, not just in the summary |

1, 2, 4 and 6 are the negative tests. They are the ones worth actually running — 4 above all,
because it is the only observation of the Slack gateway's real tool gate rather than of config.

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
- the Slack row of `tools --summary -p backoffice` stays at exactly the five pinned toolsets
- **§4 (Notion/CRM tools) does not ship to this profile first.** Not a preference: the moment
  `crm_*` tools reach the Slack-facing agent, the exact path §10.1 exists to close is open.
- **No BFL/FLUX API key enters the container environment.** `bfl` bypassed `platform_toolsets` once
  already and is now held off only by `agent.disabled_toolsets`; uncredentialed, it fails on call.
  A key would arrive as an env change with nothing in the diff to connect it to Slack, so this is
  the only thing guarding that path — [S8](../issues/slack-integration.md#s8--toolsets-that-bypass-platform_toolsets).
- **After every Hermes upgrade**, re-read the Slack row of `tools --summary -p backoffice` by
  contents. A new toolset can arrive enabled there without appearing in any committed list.
- **The `slack:` block keeps its gates, and no `SLACK_*` gate appears in `agents/backoffice/.env`.**
  The environment overrides `config.yaml` silently, so a gate set in both places is governed by the
  one that is not in git. `grep '^SLACK_' agents/backoffice/.env` on the VPS should return the two
  tokens, the signing secret and at most `SLACK_ALLOWED_USERS` — nothing else.
- someone actually reads the memory review queue — an unread queue is a rubber stamp
