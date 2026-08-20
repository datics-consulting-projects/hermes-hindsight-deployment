# Slack integration — issues

Defects, unresolved questions and known sharp edges specific to the Slack surface. Separate from
the [gap register](gap-register.md), which tracks defects in the deployment as a whole; the one
Slack entry that belongs there is
[G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split), the deviation from plan §10.1.

Plan and runbook: [slack-integration](../plans/slack-integration.md).

Priority is *actual risk today*. As of 2026-08-20 the app exists, the tokens are installed and the
gateway is connected, but the bot has not been `/invite`d to any channel — so nobody outside the
deployment can reach it yet. Several of these become materially worse the moment that invite
happens; that is noted where it applies.

| # | Priority | Issue | Status |
|---|---|---|---|
| [S10](#s10--the-slack-block-is-committed-but-unverified) | **P1** | The `slack:` block is committed but unverified | Open — **blocks the `/invite`** |
| [S11](#s11--todo--slackallowed_channels-is-empty-so-the-invite-is-the-only-channel-scope) | P2 | **TODO** — `slack.allowed_channels` is empty, so the `/invite` is the only channel scope | Open — **do this at the `/invite`** |
| [S3](#s3--memorywrite_approval-is-unverified) | P2 | `memory.write_approval` is unverified | Open |
| [S5](#s5--slash-commands-would-let-channel-members-disable-the-guardrails) | P2 | Slash commands would let channel members disable the guardrails | Mitigated — scope omitted |
| [S6](#s6--slack-preflightsh-check-reads-the-wrong-env) | P3 | `slack-preflight.sh check` reads the wrong `.env` | Open |
| [S7](#s7--the-default-profiles-gateway-restarts-itself) | P3 | The `default` profile's gateway restarts itself | Open — worked around by hand |
| [S8](#s8--toolsets-that-bypass-platform_toolsets) | P3 | Toolsets that bypass `platform_toolsets` | **Worked around 2026-08-20** — standing upgrade hazard |
| [S9](#s9--the-slack-behaviour-gates-are-unread) | — | The Slack behaviour gates are unread | **Resolved 2026-08-20** — became S10 |
| [S4](#s4--mention-only-may-have-a-single-point-of-failure) | — | Mention-only may have a single point of failure | **Resolved 2026-08-20** by S9 |
| [S1](#s1--slack-credential-schema) | — | Slack credential schema | **Resolved 2026-08-20** |
| [S2](#s2--whether-the-slack-toolset-restriction-is-applied) | — | Whether the Slack toolset restriction is applied | **Resolved 2026-08-20** |

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

## S2 — Whether the Slack toolset restriction is applied

**Status: resolved 2026-08-20.** The map is read and applied.

Run once the Slack app was credentialed and deployed, `hermes tools --summary -p backoffice` prints
a **Slack (5/28)** row listing exactly `clarify, memory, session_search, skills, todo` — the
committed `platform_toolsets.slack`, entry for entry. Every execution toolset (File Operations,
Terminal & Processes, Code Execution, Web Search & Scraping, Computer Use, Task Delegation, Cron
Jobs, Image Generation, TTS, Vision) is absent from the Slack row while present on CLI. The
load-bearing control from [G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split) is
real.

**Why it looked broken.** Before the app existed the summary printed a CLI section and *no Slack
section at all*, while `config get platform_toolsets -p backoffice` returned the committed map. The
hypothesis recorded here was right: a platform is enumerated only once it is actually configured.
The missing row had been evidence of nothing in either direction — which is why the decisive test
was deferred to after the tokens landed instead of being read as a failure.

**Two things this does not prove.** Both are why the controls in
[plan §5.7](../plans/slack-integration.md) still have to be run:

- `tools --summary` renders configuration back at you. It is not an observation of what the Slack
  gateway does when a tool is called. Control 4 — asking the agent in-channel to run a shell
  command — is the only test of that path.
- The **first** run of this test returned 7/28, not 5: `kanban` and `bfl` were present despite
  being absent from the map. See [S8](#s8--toolsets-that-bypass-platform_toolsets). Read the row's
  contents, never just its count.

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

**Status: resolved 2026-08-20** by [S9](#s9--the-slack-behaviour-gates-are-unread). It was not
single-point; the second layer existed the whole time and this repo had not looked for it.

`slack-manifest.yaml` subscribes to `app_mention` and no other bot event, so Slack never delivers
the channel's other messages. That remains the first layer and the strongest one. The claim that it
was the *only* one rested on there being no `channels:` config key — true, and irrelevant: the key
is a top-level `slack:` block, and `require_mention`, `strict_mention` and `thread_require_mention`
are now pinned in `agents/backoffice/config.yaml`.

**The failure mode it was written about is now covered.** If the manifest is ever edited to add
`message.channels`, Slack starts delivering every message in the channel — and the adapter drops
each one that does not mention the bot, instead of nothing anywhere pushing back. That is the
whole point of setting gates that do nothing today: they are what a *future* widening runs into.

**Two things this does not retire:**

- The gates are committed, not verified — [S10](#s10--the-slack-block-is-committed-but-unverified).
  Until that closes, treat mention-only as single-point exactly as before.
- **The negative control still runs after every manifest change.** Post without mentioning the bot,
  confirm silence. A config that fails does so by answering *more* people, not fewer, so the silent
  test is the only one that proves anything. The comment above `bot_events` in the manifest says
  this; keep it there.

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

## S8 — Toolsets that bypass `platform_toolsets`

**Status: worked around 2026-08-20.** Held at P3 as a standing upgrade hazard, not as a live
defect. Supersedes the original entry, which was narrower (`kanban` only) and whose proposed
workaround did not work.

**What happened.** With Slack configured, the first `tools --summary -p backoffice` showed
**Slack 7/28** — the five pinned toolsets plus `kanban` and `bfl` (BFL FLUX 3 Video). Neither is in
`platform_toolsets.slack`. `kanban` was in no list in the file at all; `bfl` was in `cli:` only.
**Absence from the map did not disable either one**, which is exactly what this issue originally
proposed as the fix.

**The lever that works** is `agent.disabled_toolsets`, which is profile-wide:

```yaml
agent:
  disabled_toolsets: [browser, bfl, kanban]
```

CLI 17 → 15, Slack 7 → 5. `kanban` is the clean experiment: it was in no platform list, so only
this key can have removed it. `bfl` left the `cli:` list in the same commit, so which of the two
levers fired for it was never isolated — both are kept.

**The name check is a superset.** `hermes tools disable --platform slack … kanban` answers
`✗ Unknown toolset 'kanban'`, yet `kanban` in `agent.disabled_toolsets` works. That command
rejecting a name is **not** evidence the name does nothing in config. Unchanged and still true in
the other direction: a wrong name in `disabled_toolsets` fails silently (`files` for `file`), so
the count in the summary is the only confirmation either way.

**Why it stays open as a hazard.** The mechanism was never read out of the source.
`known_builtin_toolsets` appears only under `/opt/hermes/hermes_cli/` — the code that writes the
map and prints the summary — and the backoffice profile has no such key, because the `:ro` mount
means Hermes cannot write one. The working theory is that toolsets outside the build's own registry
are not governed by `platform_toolsets` at all and default to enabled. **Under that theory, any
Hermes upgrade can add a toolset that arrives enabled on Slack.** After every upgrade, run
`tools --summary -p backoffice` and read the Slack row's *contents*, not its count.

**`bfl` is why this was not a P3 curiosity.** It is not a read tool: it calls an external API with
channel-supplied text, and it spends money. `env | grep -iE 'bfl|flux'` inside the container
returned nothing, so the toolset would have failed on call — but that is one credential away from
live, arriving as an env change with no diff anywhere near Slack to show it. Hence the closing
condition added to [plan §7](../plans/slack-integration.md).

---

## S9 — The Slack behaviour gates are unread

**Status: resolved 2026-08-20.** Both probes were run against the installed build. The gates are
real, they are read, and — with exactly one exception — they are **config keys as well as**
environment variables. That last part is what several entries in this repo had wrong.

**The mechanism, because no key name gives it away.** `gateway/config.py::load_gateway_config()`
reads `<profile home>/config.yaml` — for `-p backoffice`, the `:ro` mount of
`agents/backoffice/config.yaml` — and hands its top-level `slack:` mapping to the Slack plugin's
`_apply_yaml_config` hook (`plugins/platforms/slack/adapter.py`), which translates each key into
the `SLACK_*` variable the adapter reads at message time. The loader's own docstring states the
priority: **environment variables, then `config.yaml`, then `gateway.json`, then built-in
defaults.** Every assignment in the hook is guarded by `not os.getenv(...)`, so a gate set in both
places is governed by the environment and the `config.yaml` line becomes decoration. **One gate,
one home** — the reason `agents/backoffice/.env.example` now says so at length.

### The gates, their defaults, and where they live now

| Env var | `slack:` key | Default | Fails | Set to |
|---|---|---|---|---|
| `SLACK_REQUIRE_MENTION` | `require_mention` | **`true`** | closed | `true` (pinned) |
| `SLACK_STRICT_MENTION` | `strict_mention` | `false` | **open** | `true` |
| `SLACK_THREAD_REQUIRE_MENTION` | `thread_require_mention` | `false` | **open** | `true` |
| `SLACK_IGNORE_OTHER_USER_MENTIONS` | `ignore_other_user_mentions` | `false` | open | `true` |
| `SLACK_DISABLE_DMS` | `disable_dms` | `false` | **open** | `true` |
| `SLACK_ALLOW_BOTS` | `allow_bots` | `"none"` | closed | `"none"` (pinned) |
| `SLACK_FREE_RESPONSE_CHANNELS` | `free_response_channels` | empty | closed | `[]` (pinned) |
| `SLACK_MENTION_PATTERNS` | `mention_patterns` | empty | closed | unset — never set |
| `SLACK_ALLOWED_CHANNELS` | `allowed_channels` | empty — **empty means every channel** | **open** | *left commented; needs the pilot channel's `C…` id* |
| `SLACK_IGNORED_CHANNELS` | `ignored_channels` | empty | n/a | unset |
| `SLACK_ALLOWED_USERS` | **none — environment only** | unset | closed | optional, in `.env` |
| `SLACK_ALLOW_ALL_USERS` | none | unset | closed | **never set** |

`require_mention` uses explicit-false parsing — anything unrecognised keeps gating **on**. It is
the only gate in the table that was already safe, and it is pinned anyway so an upgrade cannot
change a default out from under the deployment.

`strict_mention` is the one worth understanding rather than copying: it makes every message in a
thread need its own `@`-mention by disabling the adapter's auto-triggers — mentioned-thread memory,
bot-message follow-up, session-presence — each of which answers a message that never mentioned the
bot. S9 guessed that "a thread is where mention-only most plausibly leaks". That was right.

**None of these do anything today**, and that is not an argument against setting them. With only
`app_mention` subscribed, Slack delivers nothing for them to act on. They are the layer a future
`message.channels` line in the manifest runs into — which is precisely what
[S4](#s4--mention-only-may-have-a-single-point-of-failure) said did not exist.

### Authorization, which is the exception

`SLACK_ALLOWED_USERS` has no `slack:` key. `gateway/authz_mixin.py` resolves it through a
platform→variable map (`Platform.SLACK: "SLACK_ALLOWED_USERS"`), so there is nothing for the YAML
bridge to translate and it can only be an environment variable. It takes comma-separated `U…`
member ids — the plugin's own `plugin.yaml` documents that — and complements `hermes pairing`
rather than replacing it.

Unset, the deployment already fails closed: `hermes gateway setup` prints *"No Slack allowlist set
— unpaired users will be denied by default"* and names `SLACK_ALLOW_ALL_USERS` /
`GATEWAY_ALLOW_ALL_USERS` as the way to undo that. Never set either.

### Two corrections this probe produced

1. **`SLACK_SIGNING_SECRET` is inert in this build.** No Slack code path reads it — it appears only
   in the subprocess secret strip-list — and the plugin's `requires_env` names just
   `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`. Socket Mode authenticates with the app token; the
   signing secret verifies inbound HTTP signatures, and there is no inbound HTTP here. Keeping it
   set is harmless; believing it is what makes the connection work is not.
2. **`SLACK_VIA_HERMES_ONLY` does not exist.** S9's own table listed it as a gate on "who may
   trigger it". It is `_SLACK_VIA_HERMES_ONLY` in `hermes_cli/commands.py` — a frozenset of
   subcommands reachable only via `/hermes …`. The entry that warned "the list is a superset, and
   must not be read as a finding on its own" had already been caught by its own warning.

### The lesson, which is the reverse of S1's

S1's lesson was that an empty result from a broken search is not a finding. This one is the other
direction: **a name absent from a narrow search is not absent from the build.** Step 1 matched
`environ|getenv` within eight characters of the name and returned 26 of the original 68 — and
missed `SLACK_ALLOWED_USERS` entirely, because it is never read by literal name. Had that list
been treated as complete, the single most important gate here would have been written off as a
regex constant.

**Grep for the name, then for the read.** `grep -rl` on the bare name across `/opt/hermes`, minus
`slack_sdk` / `slack_bolt`, is what found `authz_mixin.py`, `plugin.yaml` and the YAML bridge.

---

## S10 — The `slack:` block is committed but unverified

**Priority:** P1. **Blocks the `/invite`**, inheriting that from
[S9](#s9--the-slack-behaviour-gates-are-unread). This is S9's remainder: the gates are read out of
the build and pinned in `agents/backoffice/config.yaml`, but nothing has yet observed this
deployment *applying* them.

**Why that is not pedantry.** It is the same shape as
[S3](#s3--memorywrite_approval-is-unverified), and this repo has already been bitten twice by it:
`hermes config set` is schemaless, a wrong toolset name fails silently, and `platform_toolsets`
turned out not to govern `kanban` at all ([S8](#s8--toolsets-that-bypass-platform_toolsets)). The
`slack:` block has been read out of the *source* and the loader path traced, which is more evidence
than either of those ever had — and still not an observation.

Two specific ways it could be inert: the block is dispatched only for platforms in the plugin
registry, which requires the Slack plugin to have loaded; and any `SLACK_*` variable already in the
process environment silently wins over its `config.yaml` twin.

**The decisive test, and it needs no Slack traffic.** `allow_bots` is the one gate that announces
itself: set to anything but `none`, the adapter logs a line at INFO on connect. So temporarily set

```yaml
slack:
  allow_bots: "mentions"
```

deploy, and read the log:

```sh
./scripts/deploy.sh                       # its own log tail may already show it
ssh "$HERMES_SSH" 'docker logs --tail 200 hermes' | grep -i allow_bots
# expect: [Slack] allow_bots=mentions — for bot-to-bot interop also ensure: ...
```

The line appearing proves the whole chain for this profile: `config.yaml` read → `slack:` block
dispatched → key translated → adapter observed the result. **Then revert to `"none"` and deploy
again** — this is a two-commit test, and leaving `mentions` in place would admit bot traffic past
the human allowlist.

If the line does not appear, the block is inert and every gate in it has to move to
`agents/backoffice/.env` instead, where the read path is already proven by the tokens working.

**Also outstanding, and part of the same close:** the one gate in the block still unset —
[S11](#s11--todo--slackallowed_channels-is-empty-so-the-invite-is-the-only-channel-scope).

---

## S11 — TODO — `slack.allowed_channels` is empty, so the `/invite` is the only channel scope

**Priority:** P2. **Status: open, and it is a to-do rather than a defect** — it cannot be closed
before the pilot channel exists, which is why it is carried here instead of being left as a
commented line nobody re-reads.

`slack.allowed_channels` is present in `agents/backoffice/config.yaml` but commented out. The
adapter's own docstring is explicit about what that means:

> When non-empty, messages from channels NOT in this set are silently ignored — even if the bot is
> @mentioned. […] Empty set means no channel restriction.

So today the bot would answer an `@`-mention in **any** channel it has been invited to, and the
only thing scoping it is the `/invite` itself. That brace is real — Slack does not deliver events
for channels the app is not in — but it is one action away from being wrong, and the action is a
single click by anyone with the bot in their member list. This is a belt with no braces, which is
the same shape as [S4](#s4--mention-only-may-have-a-single-point-of-failure) before it was closed.

**The to-do, at invite time and not before:**

1. Open the pilot channel in Slack → right-click its name → **Copy link**. The `C…` id is the last
   path segment.
2. Uncomment the key in `agents/backoffice/config.yaml` and put the id in it:

   ```yaml
   slack:
     allowed_channels:
       - "C0123456789"
   ```

3. Commit, `./scripts/deploy.sh`, then `/invite` — in that order, so the scope exists before the
   bot does.

**Do not put it in `.env` instead.** `SLACK_ALLOWED_CHANNELS` would work and would also silently
override the whole `slack:` block's twin key; the channel id is not a secret and belongs in the
diff. See the precedence note in [S9](#s9--the-slack-behaviour-gates-are-unread).

**Verify:** invite the bot to a second, throwaway channel and `@`-mention it there. Silence is the
pass. That is the only test that distinguishes "scoped" from "happens to be in one channel", and it
is worth running once — the failure mode here is the config answering *more* people, so a positive
test in the pilot channel proves nothing about it.

**Related:** plan §5.6, which carries the same step in the runbook; and
[G8](gap-register.md#g8--slack-opens-before-the-readerwriter-split), whose "one channel, explicit
allowlist" mitigation row is only half-true until this lands.
