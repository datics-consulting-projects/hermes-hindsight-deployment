# Slack integration — issues

Defects, unresolved questions and known sharp edges specific to the Slack surface. Separate from
the [gap register](gap-register.md), which tracks defects in the deployment as a whole; the one
Slack entry that belongs there is
[G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split), the deviation from plan §10.1.

Plan and runbook: [slack-integration](../plans/slack-integration.md).

Priority is *actual risk today*, given that no Slack app exists yet. Several of these become more
severe the moment the bot is in a channel — that is noted where it applies.

| # | Priority | Issue | Status |
|---|---|---|---|
| [S2](#s2--no-slack-section-in-tools---summary--p-backoffice) | **P1** | No Slack section in `tools --summary -p backoffice` | Open — unexplained |
| [S9](#s9--the-slack-behaviour-gates-are-unread) | **P1** | The Slack behaviour gates are unread — including the ones that fail open | Open |
| [S3](#s3--memorywrite_approval-is-unverified) | P2 | `memory.write_approval` is unverified | Open |
| [S4](#s4--mention-only-has-a-single-point-of-failure) | P2 | Mention-only may have a single point of failure | **Superseded by S9** |
| [S1](#s1--slack-credential-schema) | — | Slack credential schema | **Resolved 2026-08-20** |
| [S5](#s5--slash-commands-would-let-channel-members-disable-the-guardrails) | P2 | Slash commands would let channel members disable the guardrails | Mitigated — scope omitted |
| [S6](#s6--slack-preflightsh-check-reads-the-wrong-env) | P3 | `slack-preflight.sh check` reads the wrong `.env` | Open |
| [S7](#s7--the-default-profiles-gateway-restarts-itself) | P3 | The `default` profile's gateway restarts itself | Open — worked around by hand |
| [S8](#s8--kanban-cannot-be-disabled-through-tools-disable) | P3 | `kanban` cannot be disabled through `tools disable` | Open — hand-removed |

---

## S1 — Slack credential schema

**Status: resolved 2026-08-20.** Kept because the way it was nearly answered wrongly is the part
worth remembering.

`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` and `SLACK_SIGNING_SECRET` all appear in the installed build.
Slack is credentialed by **environment variable**, not by a config key — which is why the per-agent
`agents/backoffice/.env` is the right home for them, and why no `config.yaml` change is needed for
credentials at all.

```sh
docker exec hermes sh -c '
  echo "files: $(find /opt/hermes -type f | wc -l)"
  grep -rhoE "SLACK_[A-Z0-9_]+" /opt/hermes 2>/dev/null | sort -u'
# files: 49326  → 68 SLACK_* identifiers, the three token names among them
```

**Two lessons this cost.**

1. **An empty result from a broken search is not a finding.** The first version of this probe
   searched for an importable `hermes` python package; the install root is `/opt/hermes`, so it
   returned nothing, and nothing was nearly read as "there are no Slack env vars". The file count
   in the command above exists solely to make a broken search distinguishable from a real negative.
2. **The pre-setup config dump was mistaken for a post-setup one.** `/opt/data/config.yaml` was
   read as evidence about Slack credentials when it predated any Slack configuration —
   `platform_toolsets.slack` still held the stock `hermes-slack` placeholder. What had actually
   been run was `hermes tools disable`, not `hermes gateway setup`. **Check what a dump is a dump
   *of* before drawing a negative from it.**

**What it opened:** the same probe surfaced ~60 other `SLACK_*` names, including behaviour gates
nothing in this repo currently sets. That is now [S9](#s9--the-slack-behaviour-gates-are-unread).

---

## S2 — No Slack section in `tools --summary -p backoffice`

**Priority:** P1 — because the answer decides whether the Slack tool restriction is real.

`hermes tools --summary -p backoffice` prints a CLI section (17/28) and **no Slack section at
all**. The `default` profile prints one. Meanwhile `hermes config get platform_toolsets -p
backoffice` returns exactly the committed map, including
`slack: [clarify, memory, session_search, skills, todo]` — so the `:ro` config *is* being read.

**This is not explained.** The plausible reading is that the summary enumerates platforms from a
registry populated by `tools disable --platform` on the profile it is run against, whereas
backoffice's entry arrived as a raw config file — the value is present, just not enumerated. That
is a hypothesis, not a finding.

**Why it matters.** `platform_toolsets.slack` is the load-bearing control from
[G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split). If it is not applied, the
Slack surface has every execution toolset the CLI has.

**The decisive test comes after Slack is actually configured** (S1 → app → tokens → deploy):

```sh
docker exec -it hermes hermes tools --summary -p backoffice
```

| Result | Meaning |
|---|---|
| Slack section, 5/28 | The pinned map applies. Restriction confirmed. |
| Slack section, 18/28 | The map is not being applied. **Do not `/invite`.** |
| Still no Slack section | Inconclusive again; find another observable before opening the channel. |

**Until this is green, treat the Slack toolset restriction as committed but unverified.**

---

## S3 — `memory.write_approval` is unverified

**Priority:** P2.

`memory.write_approval: true` in `agents/backoffice/config.yaml` is the interim standing in for the
reader/writer split. It round-trips through `config set`/`config get` — but in this build so does
any key at all, so that is no evidence.

**What is known.** The generated `memory:` block contains `memory_enabled`, `user_profile_enabled`,
`memory_char_limit`, `user_char_limit`, `provider`, `nudge_interval`, `flush_min_turns` — and no
`write_approval`. `hermes memory` exposes only `setup`, `status`, `off`, `reset`; there is no
approval subcommand. The reason to believe the gate exists at all is Slack's `/memory approval
on|off` gateway command, which implies something for it to toggle.

**Verify:** control 5 in the plan's runbook — say "remember that X" in the channel and check
whether it lands. If retention is immediate, the key does nothing and G8's second mitigation is
fiction.

**If it does nothing,** the honest options are to withdraw Slack, or to accept that anything said
in the channel becomes durable memory unreviewed and say so in G8 rather than leaving a control
listed that does not exist.

---

## S4 — Mention-only may have a single point of failure

**Priority:** P2. **Status: superseded by [S9](#s9--the-slack-behaviour-gates-are-unread).** The
claim below was written before the env-var probe and is now only half true.

`slack-manifest.yaml` subscribes to `app_mention` and no other bot event. Slack therefore never
delivers the channel's other messages. This build has no `channels:` **config key**, so plan §6.3's
`channels.slack.respondTo: mention` does not exist — but that is not the same as having no second
layer. `SLACK_REQUIRE_MENTION`, `SLACK_STRICT_MENTION` and `SLACK_THREAD_REQUIRE_MENTION` exist in
the install as *environment variables*, which is a lever this repo can set and never looked for.
**Nothing here is a second layer until S9 confirms they are read and sets them.**

**The failure mode is silent and open.** If the manifest is ever edited to add `message.channels`,
every message in the channel reaches the agent, and nothing anywhere else pushes back. A config
that fails does so by answering *more* people, not fewer.

**Guard:** the negative control — post without mentioning the bot, confirm silence — after every
manifest change. The comment above `bot_events` in the manifest states this; keep it there.

---

## S5 — Slash commands would let channel members disable the guardrails

**Priority:** P2. **Status: mitigated** by omitting the `commands` scope.

`hermes slack manifest` generates a manifest registering every gateway command as a native Slack
slash command. Among them are `/yolo`, `/approvals off` and `/memory approval off`. With that
manifest, **any member of the channel could turn off the approval gates from inside Slack** —
including the one control S3 is about.

`agents/backoffice/slack-manifest.yaml` is hand-written for this reason and grants no `commands`
scope and no slash commands.

**The sharp edge:** the manifest's own header tells the reader to diff against
`hermes slack manifest --agent-view`. Doing that and adopting the generated version wholesale
reintroduces this. Diff it for *events Hermes needs*, not for commands.

**Verify:** the installed app's Slash Commands page in Slack is empty.

---

## S6 — `slack-preflight.sh check` reads the wrong `.env`

**Priority:** P3 — an annoyance now, a false negative later.

`cmd_check` reads `$repo_root/agents/backoffice/.env` on the **local** machine. The real tokens
live in that path **on the VPS**, and by design never enter this repo. So `check` will report
"agents/backoffice/.env is missing" for the person who did everything correctly.

**Fix:** read the file over ssh, the way `discover` and `verify` already do, or accept a token
source on stdin. The Slack API calls should keep running locally — validating tokens from the
machine holding them is the point of the subcommand.

---

## S7 — The `default` profile's gateway restarts itself

**Priority:** P3.

The stack runs `gateway run -p backoffice`, but the container's
`/etc/cont-init.d/02-reconcile-profiles` restarts every profile whose last recorded state was
`running`. Once the `default` gateway has been started by hand, it comes back on every container
restart — **two gateways, two profiles, one set of Slack credentials.** If both ever connect to the
same Slack app, which one answers is a race.

**Worked around by hand** on 2026-08-20 with `docker exec hermes hermes gateway stop`, which
cleared the recorded state. `gateway status -p backoffice` now shows a single gateway and no
"Other profiles" line.

**Why it is still open:** the fix was a command, not a commit. Nothing in this repo prevents it
recurring the next time someone runs a bare `hermes gateway` command — and a bare command is the
easy mistake, since every `hermes` invocation defaults to `default`.

**Fix:** read `/etc/cont-init.d/02-reconcile-profiles` and find a declarative lever — an env var,
or a state file that can be pinned `:ro`. Failing that, document it in the README's operating
section as a check after every restart.

**Verify:** `docker compose restart hermes && docker exec hermes hermes gateway status -p backoffice`
— one gateway, no "Other profiles".

---

## S8 — `kanban` cannot be disabled through `tools disable`

**Priority:** P3.

`hermes tools disable --platform slack … kanban` answers `✗ Unknown toolset 'kanban'`, yet `kanban`
appears as enabled in `tools --summary` and in the generated `platform_toolsets` map. It is absent
from `known_builtin_toolsets`, which is presumably why the name is rejected.

**Worked around:** the line is deleted by hand from the `slack:` list in
`agents/backoffice/config.yaml`. Since that file is the mounted source of truth, the deletion is
the config.

**Unverified:** whether removing the line actually removes the toolset, or whether `kanban` is
injected regardless of the map. This shares an observable with
[S2](#s2--no-slack-section-in-tools---summary--p-backoffice) — both are answered by the same
post-setup summary. A Slack row at 5/28 with no kanban settles it.

**Why it is P3 and not lower:** kanban is a task-dispatch surface, not a read tool. It is the one
remaining toolset on the Slack list whose blast radius is not obviously zero.

---

## S9 — The Slack behaviour gates are unread

**Priority:** P1. This is the successor to [S1](#s1--slack-credential-schema), and it decides how
much of the Slack posture is enforced versus merely intended.

The env-var probe returned ~68 `SLACK_*` identifiers. Alongside the three tokens are names that
read as behaviour gates on exactly the properties this integration is trying to guarantee:

| Name | What it looks like it controls | Why it matters here |
|---|---|---|
| `SLACK_REQUIRE_MENTION` | answer only when mentioned | would be the second layer S4 says does not exist |
| `SLACK_STRICT_MENTION`, `SLACK_THREAD_REQUIRE_MENTION` | mention handling, incl. inside threads | a thread is where mention-only most plausibly leaks |
| `SLACK_ALLOWED_USERS`, `SLACK_ALLOWED_CHANNELS` | who and where | a **declarable** allowlist — the plan currently says the only allowlist is the runtime `hermes pairing` store |
| `SLACK_IGNORED_CHANNELS` | channel denylist | belt to the `/invite` braces |
| `SLACK_DISABLE_DMS` | no DMs | enforces plan §6.2 at runtime, not just by withholding `im:*` scopes |
| `SLACK_ALLOW_BOTS`, `SLACK_VIA_HERMES_ONLY` | who may trigger it | bot-to-bot loops, and an unattended input path |
| `SLACK_ALLOW_ALL_USERS` | disables the allowlist | **never set this** |
| `SLACK_FREE_RESPONSE_CHANNELS` | channels answered **without** a mention | the direct negation of mention-only |

**The list is a superset, and must not be read as a finding on its own.** The probe matched every
uppercase `SLACK_*` identifier across 49,326 files, including vendored `slack_sdk` / `slack_bolt`
and ordinary module constants — `SLACK_MENTION_RE`, `SLACK_USER_ID_RE`, `SLACK_AUDIO_MIME_TO_EXT`
and `SLACK_TOKEN_PREFIXES` are regexes and dicts, not environment variables. Every env var is in
the list; not everything in the list is an env var.

**Step 1 — separate env-reads from constants:**

```sh
docker exec hermes sh -c '
  grep -rhoE "(environ|getenv)[^A-Za-z]{1,8}SLACK_[A-Z0-9_]+" /opt/hermes 2>/dev/null \
    | grep -oE "SLACK_[A-Z0-9_]+" | sort -u'
```

**Step 2 — read the defaults, which is where the actual risk is:**

```sh
docker exec hermes sh -c '
  grep -rn -E "SLACK_(REQUIRE_MENTION|STRICT_MENTION|ALLOW_ALL_USERS|FREE_RESPONSE_CHANNELS|ALLOWED_USERS|DISABLE_DMS)\b" \
    /opt/hermes --include=*.py | grep -vE "/(slack_sdk|slack_bolt)/" | head -40'
```

A gate defaulting to *on* is a control the deployment already has. A gate defaulting to *off* is a
control only once this repo sets it — and one that fails open if nobody does.

**Then:** set the confirmed ones in `agents/backoffice/.env.example` with their meaning, and in the
VPS `.env`. That moves mention-only and the allowlist from "one Slack manifest field" to
"manifest **and** runtime gate", and makes the allowlist reviewable in `.env.example` rather than
living only in the volume's pairing store.

**Update when resolved:** [S4](#s4--mention-only-may-have-a-single-point-of-failure), the mitigation
table in [G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split), and §2, §4 and §5 of
[the plan](../plans/slack-integration.md) — all three currently state that no config-side gate
exists, which was true of config **keys** and looks likely to be false of environment variables.
