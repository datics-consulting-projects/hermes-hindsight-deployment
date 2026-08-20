# Gap Register

Concrete defects found in this repository, verified against the files as of 2026-08-20.

These are **actionable now** and independent of the phased roadmap in
[the implementation plan](../plans/hermes-backoffice-agent-implementation-plan.md). Closing them
leaves the current deployment strictly better whether or not the rest of the plan ever ships.

Issues scoped to one surface live in their own file: see
[slack-integration issues](slack-integration.md) (S1–S8). Only the plan deviation Slack represents
is tracked here, as [G8](#g8--slack-opens-before-the-readerwriter-split).

Priority reflects *actual risk today*, not position in the roadmap.

| # | Priority | Gap | Status |
|---|---|---|---|
| [G6](#g6--backups-documented-but-not-scheduled) | **P1** | Backups documented but not scheduled | Open |
| [G8](#g8--slack-opens-before-the-readerwriter-split) | P2 | Slack opens before the reader/writer split (§10.1) | Open — mitigated |
| [G5](#g5--images-track-latest) | P2 | Images track `:latest` — unpinned and unrecorded | Open — **restated 2026-08-20** |
| [G7](#g7--hindsight-has-no-resource-limit) | P3 | Hindsight has no resource limit | Open |
| [G1](#g1--notion_api_key-is-declared-but-reaches-no-container) | — | `NOTION_API_KEY` declared but reaches no container | **Fixed 2026-08-20** |
| [G2](#g2--agents-is-never-mounted-into-any-container) | — | `agents/` never mounted into any container | **Fixed 2026-08-19** |
| [G3](#g3--agentsbackofficesoulmd-is-empty) | — | `agents/backoffice/SOUL.md` is empty | **Fixed 2026-08-20** |
| [G4](#g4--stale-plan-section-references-in-the-soul-template) | — | Stale plan refs in SOUL template | **Fixed 2026-08-19** |

---

## G6 — Backups documented but not scheduled

**Priority:** P1 — highest actual risk in the repo.

`hindsight_pg_data` holds every extracted memory, entity and graph edge. It is **the one asset in
the stack that cannot be regenerated** — everything else rebuilds from config and images. The
README documents the `tar` commands but nothing runs them, so total memory loss is currently one
bad `docker volume rm` or one failed disk away.

**Evidence:** `README.md` § "Backups" gives the commands; no cron job, systemd timer, or CI step
invokes them anywhere in the repo.

**Fix:**

1. Add a systemd timer or cron entry on the VPS running both documented `tar` commands nightly.
2. Ship the archives **offsite** — a backup on the same disk as the volume is not a backup.
3. **Test a restore into a scratch stack.** An untested backup is a hypothesis.

**Verify:** restore `hindsight_pg_data` into a throwaway compose project and confirm prior memories
are recalled. This is also an acceptance test in plan §14.

---

## G2 — `agents/` is never mounted into any container

**Status: Fixed 2026-08-19.**

The `hermes` service mounted only `hermes_data:/opt/data`. Nothing bind-mounted or copied
`agents/`, so the `SOUL.md` files in this repo **could not reach the running agent**. Editing them
had no effect, which made the version-controlled persona a fiction: the agent ran on whatever was
inside the volume. It also broke the property plan §3.5 relies on — "persona edits take effect on
the next interaction" was only true for the copy inside the volume.

**Fix applied.** Hermes loads `SOUL.md` only from `HERMES_HOME` — there is no config key or env var
pointing elsewhere, so a mount is the only mechanism. `docker-compose.yml` now carries:

```yaml
command: gateway run -p backoffice
volumes:
  - hermes_data:/opt/data
  - ./agents/backoffice/SOUL.md:/opt/data/profiles/backoffice/SOUL.md:ro
```

`config.yaml` and `.env` are mounted the same way, so identity *and* configuration are code, while
`memories/`, `sessions/` and `skills/` stay read-write in the volume under
`/opt/data/profiles/backoffice/`. Documented in README § "The persona"; the full design is in
[docs/design/persona-delivery.md](../design/persona-delivery.md).

The `.env` mount uses the long form with `create_host_path: false` deliberately. Verified
behaviour: with the short `src:dst:ro` syntax a **missing** source file makes Docker create a
root-owned *directory* at that path and start the container anyway — the agent silently gets no
secrets. The long form fails with `bind source path does not exist` instead, matching the
`${TAILSCALE_IP:?}` guard's philosophy.

**Three constraints found while fixing it**, all recorded in the README and the compose comments:

- **Create the profile before adding its mount.** Otherwise Docker creates
  `/opt/data/profiles/<name>/` as `root:root` and the runtime `hermes` user (UID 10000) cannot
  write its own `config.yaml` and sessions into it.
- **Never mount `agents/<name>/` over a profile home.** A profile home is mutable agent state —
  sessions, memories, learned skills — not persona. Mount leaf paths only.
- **`git pull` breaks a single-file bind mount.** Git replaces a modified file with a new inode and
  the mount keeps pointing at the old one, so persona edits must be followed by
  `docker compose restart hermes`. If the mount count grows past a handful, switch to
  `- ./agents:/opt/data/agents:ro` plus a symlink per profile — directory mounts are immune to this.

**Both residuals closed 2026-08-20. The persona is live.**

1. **The gateway now runs the `backoffice` profile.** `docker-compose.yml` carries
   `command: gateway run -p backoffice`, so `/opt/data/profiles/backoffice/` is what the running
   agent reads and the mounts above are load-bearing rather than staged. The one word landed.
2. **`agents/backoffice/SOUL.md` is filled** — 2953 bytes (G3), and filled *before* the `-p` switch
   flipped, which was the ordering constraint this residual existed to enforce.

The staging state that produced them is worth keeping in mind as the failure mode: a gateway
running `default` reads none of these mounts, starts normally, and answers normally — the only
symptom is that persona edits do nothing. If that recurs, check the profile before the mounts.

**Verify** (not yet run — no Hermes container on the dev machine):

```sh
docker exec -it hermes ls /opt/data                               # confirm the layout on the VPS
docker exec hermes hermes profile list                            # backoffice present?
docker exec hermes ls -la /opt/data/profiles/backoffice           # UID 10000, not root?
docker exec hermes head -5 /opt/data/profiles/backoffice/SOUL.md  # matches the repo file?
```

Both halves are verifiable now that the gateway runs `-p backoffice`: the delivery, with the
commands above, and the *effect* — a distinctive line in `SOUL.md` changing the agent's behaviour
in a new session. **The effect test has not been run.**

**Related:** G3 (the file is empty), plan §3, §11.1,
[docs/design/persona-delivery.md](../design/persona-delivery.md) — which carries the read-only
decision, the `SOUL.md` / `SOUL_DEVELOPS.md` question, and the multi-persona target layout.

---

## G3 — `agents/backoffice/SOUL.md` is empty

**Status: Fixed 2026-08-20.**

The file was 0 bytes, so the persona described in plan §3 existed nowhere and the agent ran on
Hermes defaults. Because G2 had closed, the empty file was mounted at
`/opt/data/profiles/backoffice/SOUL.md` and actively shadowed whatever the setup wizard had written
into the volume, rather than merely being ignored.

**Fix applied.** Filled from `agents/template/SOUL.md` per plan §3.3 — now 2953 bytes. Both
decisions the entry called for were taken, and the resulting section list records them:

| Section | Present | Why |
|---|---|---|
| Identity, How you answer, Boundaries | yes | The baseline from the template. |
| What you remember | **kept** | The reader/writer split (plan §10.1) has not landed, so the single `backoffice` profile legitimately carries both recall and retention. Revisit when §10.1 lands — [G8](#g8--slack-opens-before-the-readerwriter-split) is the entry that will move first. |
| Untrusted content | **omitted** | No tool emits `<untrusted_content>` markers yet. The template says so itself: teaching the agent to expect markers it will never see is worse than omitting the section. Add it with the tool that emits them. |

This also unblocked G2's second residual — the file was filled *before* the `-p backoffice` switch
flipped, which was the ordering constraint.

**Verify:**

```sh
stat -c '%s bytes' agents/backoffice/SOUL.md                      # → 2953 bytes
docker exec hermes head -5 /opt/data/profiles/backoffice/SOUL.md  # after deploy.sh
```

Note the restart requirement from G2: `git pull` replaces the file's inode and the bind mount keeps
pointing at the old one, so persona edits need `docker compose restart hermes`. `scripts/deploy.sh`
does this unconditionally.

---

## G1 — `NOTION_API_KEY` is declared but reaches no container

**Status: Fixed 2026-08-20 — option B, and the consumer now exists.**

*Originally:* the root `.env.example` declared `NOTION_API_KEY` while no service received it, so
the repo implied a Notion capability it did not have — `grep -c NOTION docker-compose.yml` → 0.

*2026-08-19:* the key moved out of the root `.env.example` into `agents/<name>/.env.example`,
commented out. That closed the misrepresentation but left the loop open: a delivery path with no
consumer at the end of it.

**What closed it.** All three parts are now in place, and they sit in three deliberately different
layers:

| Part | Where | Why there |
|---|---|---|
| The **tool** — Notion's `ntn` CLI, plus `NOTION_KEYRING=0` | `docker/Dockerfile` (image) | Container-wide, and not a secret. `NOTION_KEYRING=0` is a fact about running headless, not about any one agent. |
| The **delivery path** — `agents/backoffice/.env` mounted `:ro` at `/opt/data/profiles/backoffice/.env` | `docker-compose.yml` | Per-profile, long-form bind with `create_host_path: false` so a missing file fails loudly (see G2). |
| The **credential** | `agents/<name>/.env`, gitignored | Per-agent scope is the access boundary (plan §0, §9.2). Prompting cannot enforce it; a scoped token can. |

The split is the point: **the image grants the tool, the `.env` grants the access.** A second
persona gets `ntn` and no Notion reach whatsoever.

**The Slack caveat resolved, but not by this entry.** `.env.example` warns that a live Notion
credential is "acceptable only while the surface stays Tailscale-only, never once Slack lands" —
and Slack has since landed. What makes that survivable is [G8](#g8--slack-opens-before-the-readerwriter-split)'s
control, not anything here: `platform_toolsets.slack` grants five toolsets — `clarify`, `memory`,
`session_search`, `skills`, `todo` — and **both of the `notion` skill's execution paths need a
toolset that is not in that list.** The `ntn` CLI needs `terminal`; the raw-curl fallback needs
`terminal` or `web`. So the credential is live in the container and unreachable from the shared
surface.

**That makes G1 and G8 load-bearing for each other.** If `platform_toolsets.slack` ever regains
`terminal`, `web`, `file` or `code_execution`, this credential becomes reachable from Slack in the
same commit — with no change to any Notion file to signal it. Treat that list as guarding the
Notion token, not just the shell.

**Two residuals, both documentation:**

1. **`agents/backoffice/.env.example` describes a line it no longer contains.** The comment block
   says "Both are genuinely needed, so both are set here" and warns that setting only the key gives
   a quiet failure — the skill reports itself correctly configured while `ntn` reports "API token
   is invalid". But `NOTION_API_TOKEN=${NOTION_API_KEY}` was deleted from both this file and
   `agents/template/.env.example` in `a2fe57d` (2026-08-19), so the file now ships exactly the state
   its own comment warns about. Either the second name turned out to be unnecessary — in which case
   the comment should say so — or it is still needed and the next person to copy `.env.example`
   hits the described failure. **The working `.env` on the VPS is the evidence; reconcile the
   comment with it.**
2. The same comment still says the key is for "Notion sync, no crm-mcp (plan §4)" and points at
   this entry as an open gap. Re-point it once §4 lands.

**Related:** plan §4.2.1, where the token ultimately belongs to the sync service and the agent holds
no Notion credential at all — this fix is the interim, not that end state.

---

## G5 — Images track `:latest`

**Priority:** P2. **Restated 2026-08-20** — the gap is real, but the mechanism the original entry
described has since stopped existing, and the actual risk is a different one.

**The original claim, and why it no longer holds.** The entry said a breaking release "lands
unannounced on the next `docker compose pull`". Neither image can do that today:

- **`hermes` is no longer pulled at all.** `docker/Dockerfile` turned it into a local build, so
  `docker-compose.yml` now carries `build.args.HERMES_IMAGE: nousresearch/hermes-agent:latest`,
  `image: hermes-agent-stack:latest` and `pull_policy: build`. `docker compose pull` cannot reach
  it; only `docker compose build --pull hermes` re-resolves the base. README § Upgrading documents
  that as deliberate. Of the two `:latest` strings in the hermes service, **one is a purely local
  tag and harmless** — the floating reference is the build arg.
- **`hindsight` is not pulled on a deploy either.** `scripts/deploy.sh` runs `git pull` then
  `docker compose up -d`; there is no `docker compose pull` in it. Upgrades are the two manual
  commands in the README.

So there is no *unannounced* upgrade path. What remains is the **fresh-host path**: on a new VPS,
or after a `docker system prune -a`, `up -d` pulls and builds whatever `:latest` resolves to that
day, with no record anywhere of what that was.

**What `:latest` actually points at.** Resolved against both registries on 2026-08-20:

| Reference | Resolves to | Note |
|---|---|---|
| `nousresearch/hermes-agent:latest` | `sha256:3559db4b…` | **Byte-identical to `:main`** — same digest, both pushed 2026-08-20T12:13. The newest *release* tag, `v2026.8.18`, is a different image (`sha256:22e37bb4…`). |
| `ghcr.io/vectorize-io/hindsight:latest` | `0.9.1`, built 2026-08-14 | Per its own `org.opencontainers.image.version` label (revision `e5b49eb`). Three minor versions past the `0.6.x` line. |

The first row is the one that changes the character of this gap: **`:latest` on Hermes is not "the
newest release", it is the rolling `main` build.** Pinning here is not churn control, it is the
difference between running a release and running a dev branch — and nothing in the repo says which
of the two is on the VPS.

The second row is the reproducibility failure, and it compounds with **G6**: a rebuild from an
unchanged git SHA can move Hindsight across three minor versions, which is a schema migration
against `hindsight_pg_data` — the one volume that cannot be regenerated, and the one with no
scheduled backup.

(`pgvector/pgvector:pg${HINDSIGHT_DB_VERSION:-18}` is already pinned to a major — fine.)

**So the gap is not "a pull will surprise you". It is: the repo cannot state what it runs, and
cannot reproduce it.** Plan §15 lists version pinning as the mitigation for release churn, so the
repo still contradicts its own stated risk control — just for a different reason than recorded.

**Fix.** Both upstreams publish pinnable tags: Hermes ships date-versioned releases
(`v2026.8.18` is current), Hindsight ships semver through `0.9.1`, each with a `-slim` variant.

1. Pin `HERMES_IMAGE` in `docker-compose.yml` to a release tag, and add a `HERMES_VERSION` override
   hook for symmetry with `HINDSIGHT_VERSION`.
2. Set `HINDSIGHT_VERSION` in `.env.example` to a real version — it currently ships the literal
   `latest`, so every copied `.env` floats by default.
3. Test upgrades against a scratch stack before moving the live one.

**Open question, not part of this gap:** Hindsight's `-slim` variants may bear on **G7** — the
README flags that Hindsight can resolve its embeddings provider to an in-process model, which is
the footprint G7 is about. What `-slim` omits has not been checked.

---

## G7 — Hindsight has no resource limit

**Priority:** P3 — measure before acting.

`hermes` carries `deploy.resources.limits` (4 GB / 2.0 CPU); `hindsight` carries none. The README
flags that Hindsight may resolve its embeddings provider to an **in-process model** rather than an
API call, which changes its footprint substantially. On a 2 vCPU / 8 GB VPS that matters, and it
matters more once `notion-sync` becomes a fourth service (plan §2.3).

**Fix:**

1. Measure under real extraction load: `docker stats --no-stream`
2. Set a limit **with headroom**.

**Caution:** a limit set too low gets the container OOM-killed mid-extraction rather than degrading
gracefully. Err high; the point is to bound a runaway, not to right-size to the megabyte.

---

## G4 — Stale plan section references in the SOUL template

**Status: Fixed 2026-08-19.**

`agents/template/SOUL.md` referenced "plan §7.1" twice. That number came from the superseded
`hermes-backoffice-agent-implementation-plan_v2.md`; in the current plan the trust boundary is
**§10.1**. Both references were updated.

**Standing risk:** the template hard-codes plan section numbers, so any future renumbering breaks
them again silently. If this recurs, cite the section by *name* ("the reader/writer split") rather
than by number.

**Verify:**

```sh
grep -n '§' agents/template/SOUL.md
```

---

## G8 — Slack opens before the reader/writer split

**Priority:** P2. Briefly P1: the original entry assumed the agent held no execution tools, that
assumption was checked on 2026-08-20 and was false, and it was fixed the same day. The history is
kept below because the *way* it was false — a config key that silently did nothing — is the part
worth remembering.

Plan §6 states the condition plainly: *"Do not open Slack before §10.1 is in place. The reader/
writer split is a prerequisite, not a follow-up."* Slack is being opened anyway.

**The original mitigation did not hold, and was replaced. Verified 2026-08-20.**

The argument was: §4 has not shipped, so the agent holds no `crm_*` tools, and
`agents/backoffice/config.yaml` disables `web`, `terminal`, `files` and `browser` — so Slack only
adds "people can say things that become memory". The second half is false.

```
💼 Slack  (18/28)
  ✓ ⚡ Code Execution      ✓ 💻 Terminal & Processes    ✓ 📁 File Operations
  ✓ 🌐 Browser Automation  ✓ 🖱️  Computer Use            ✓ 🔍 Web Search & Scraping
  ✓ 👥 Task Delegation     ✓ ⏰ Cron Jobs
```

Identical to CLI — every execution toolset available on the shared surface.

**Two separate causes, and the first was initially misdiagnosed.**

1. `agent.disabled_toolsets` **does work**, but only for the profile whose config declares it, and
   the first check was run without `-p` — so it reported `default`, which declares nothing. Run per
   profile and the key is visibly effective: `-p backoffice` gives CLI 17/28 with Browser
   Automation absent, against 18/28 with it present on `default`, `browser` being the sole entry.
   **Tool state is per profile; a bare `hermes tools --summary` is not evidence about backoffice.**
2. The block listed `files`, and this build's toolset is `file`. A name matching nothing is
   silently ignored — no error, no warning — so File Operations was never removed even though the
   config looked like it removed it. Names come from `known_builtin_toolsets` in the generated
   config: `file`, `terminal`, `web`, `browser`.

Independently, `agent.disabled_toolsets` is profile-wide: it would have taken the toolset off the
dashboard too. Restricting the shared surface *only* needs `platform_toolsets`.

**What that means concretely.** Invite the bot to a channel today and anyone who can post in it is
one prompt away from an agent that runs shell commands, reads and writes files, executes code and
fetches URLs — inside a container holding `OPENROUTER_API_KEY`, the dashboard Basic Auth
credentials, the mounted per-agent `.env`, and network reach to `hindsight` and `hindsight-db`.
`env` is one terminal call. This is not injection-dependent; asking politely also works.

**Fixed the same day.** The lever is per-platform: `hermes tools disable --platform slack …`,
which writes the top-level `platform_toolsets:` map. Slack went from 18/28 toolsets to 5/28 —
`clarify`, `memory`, `session_search`, `skills`, `todo` — while CLI stayed at 18/28, so the
dashboard surface was not touched. The resulting map is pinned in
`agents/backoffice/config.yaml`, so it is config-as-code rather than volume state and survives a
`profile create --clone`.

**Three transferable lessons, in order of how much time they cost:**

1. **Check the right profile.** Every `hermes` command defaults to `default`, which is not the
   profile the stack runs. A bare invocation looks authoritative and answers a different question.
   This produced a wrong "the key does nothing" conclusion that was written into this register
   before being caught.
2. **A wrong toolset name is silent.** `files` vs `file` cost a guardrail, with no error anywhere.
3. **`hermes config set` is schemaless.** It accepts and round-trips any key, enforced or not, and
   `config get` reports an unknown key and a real-but-unset key identically as "Config key not
   set". A key appearing in `config.yaml` is **no evidence** anything reads it — only observing the
   effect is.

**Mitigation in place:**

| Control | Where | Effect |
|---|---|---|
| `platform_toolsets.slack` — 5 toolsets | `agents/backoffice/config.yaml` | No terminal, file, code execution, computer use, browser, web, delegation or cron on Slack. **This is now the load-bearing control**, and unlike the one below it is verified. |
| `memory.write_approval: true` | `agents/backoffice/config.yaml` | Retention staged for review rather than landing silently. **Partially verified:** the key round-trips through `config set`/`config get`, but `hermes memory` exposes only `setup/status/off/reset` — no approval subcommand — so nothing in the CLI confirms it is *enforced*. The evidence it is real is Slack's `/memory approval on\|off` gateway command, which the pilot manifest does not grant. |
| `app_mention` as the only bot event | `agents/backoffice/slack-manifest.yaml` | Slack never delivers the channel's other messages, so mention-only holds at the Slack layer even if the config is wrong. |
| Mention gates — `require_mention`, `strict_mention`, `thread_require_mention`, `ignore_other_user_mentions` | `agents/backoffice/config.yaml` → `slack:` | The second layer under the row above, added 2026-08-20 once [S9](slack-integration.md#s9--the-slack-behaviour-gates-are-unread) established these are read. Three of the four default `false`. Inert while only `app_mention` is subscribed — which is the point: they are what a future `message.channels` runs into. **Committed, not yet observed** — [S10](slack-integration.md#s10--the-slack-block-is-committed-but-unverified). |
| One channel, explicit allowlist | the `/invite`, plus `hermes pairing`; `slack.allowed_channels` and `SLACK_ALLOWED_USERS` | The bot cannot read channels it was not invited to. Never `GATEWAY_ALLOW_ALL_USERS` or `SLACK_ALLOW_ALL_USERS`; unset, the build denies unpaired users by default. `channels.slack` was named here before discovery and **no such config key exists** — the declarable forms are `slack.allowed_channels` in `config.yaml` and `SLACK_ALLOWED_USERS` in the per-agent `.env`. `allowed_channels` is **still empty**, and empty means every channel the bot is invited to; it is filled in at invite time — [S11](slack-integration.md#s11--todo--slackallowed_channels-is-empty-so-the-invite-is-the-only-channel-scope), plan §5.6. |
| No DM scopes, plus `disable_dms: true` | `slack-manifest.yaml` and `config.yaml` → `slack:` | No second, unwitnessed surface — plan §6.2. Two layers since 2026-08-20: withholding the `im:*` scopes, and a runtime gate that does not depend on nobody pasting a wider manifest into Slack's UI. |

**What this does *not* buy.** Write approval is a review queue, and a review queue only works while
someone reads it. Left unattended it degrades into a rubber stamp, at which point the deviation is
no longer mitigated — it is just unrecorded.

**Closing condition — any one of:**

1. §10.1 is built (plan §13.1 step 4) and the §14 boundary tests are green. Then write approval
   can be relaxed on its own merits.
2. **§4 ships.** Not a choice: the moment `crm_*` tools reach the Slack-facing profile, the exact
   path §10.1 exists to close is open, and the interim stops being sufficient. Do not let step 2 of
   plan §13.1 land before step 4.
3. Slack is withdrawn.

**Verify the mitigation is actually live, not just committed:**

```sh
docker exec hermes hermes config get memory -p backoffice     # write_approval: true
docker exec hermes hermes pairing list                        # allowlist, not all-users
./scripts/slack-preflight.sh verify
```

Then, in the channel: post **without** an @-mention and confirm silence, and @-mention from a
non-allowlisted account and confirm no reply. A misparsed read-only config fails *open*, so these
two negative tests are the ones that actually prove the boundary.

**Related:** plan §6, §10.1, §13.1 step 4; G1 (the other credential that must not reach a
Slack-facing agent before the screening layer exists).

**The rest of the Slack work does not live here.** This entry is the *deviation from the plan*.
Slack's own defects and open questions — including whether the two mitigations above are actually
enforced (S2, S3) — are tracked in [slack-integration issues](slack-integration.md), and the
runbook is [docs/plans/slack-integration.md](../plans/slack-integration.md).
