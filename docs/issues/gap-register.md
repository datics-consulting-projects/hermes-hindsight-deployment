# Gap Register

Concrete defects found in this repository, verified against the files as of 2026-08-19.

These are **actionable now** and independent of the phased roadmap in
[the implementation plan](../plans/hermes-backoffice-agent-implementation-plan.md). Closing them
leaves the current deployment strictly better whether or not the rest of the plan ever ships.

Priority reflects *actual risk today*, not position in the roadmap.

| # | Priority | Gap | Status |
|---|---|---|---|
| [G6](#g6--backups-documented-but-not-scheduled) | **P1** | Backups documented but not scheduled | Open |
| [G3](#g3--agentsbackofficesoulmd-is-empty) | **P1** | `agents/backoffice/SOUL.md` is empty | Open |
| [G8](#g8--slack-opens-before-the-readerwriter-split) | P2 | Slack opens before the reader/writer split (§10.1) | Open — mitigated |
| [G1](#g1--notion_api_key-is-declared-but-reaches-no-container) | P2 | `NOTION_API_KEY` declared but reaches no container | Open |
| [G5](#g5--images-track-latest) | P2 | Images track `:latest` | Open |
| [G7](#g7--hindsight-has-no-resource-limit) | P3 | Hindsight has no resource limit | Open |
| [G2](#g2--agents-is-never-mounted-into-any-container) | — | `agents/` never mounted into any container | **Fixed 2026-08-19** |
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

**Two residuals. The persona is not live yet.**

1. **The gateway runs the `default` profile** (`command: gateway run`), so nothing reads
   `/opt/data/profiles/backoffice/`. The mount is correct and proven; it is simply not pointed at
   by the running agent. This is a deliberate staging state while the multi-profile topology is
   established on the VPS — see README § "Profiles" — **not** a silent
   regression, but the observable symptom is the same as G2's: edits to `agents/` change nothing.
   Closes with one word in the compose `command:`.
2. **`agents/backoffice/SOUL.md` is still empty (G3).** Once the `-p` switch lands, an empty file
   would shadow the profile's own `SOUL.md`. **Close G3 before flipping the switch.**

**Verify** (not yet run — no Hermes container on the dev machine):

```sh
docker exec -it hermes ls /opt/data                               # confirm the layout on the VPS
docker exec hermes hermes profile list                            # backoffice present?
docker exec hermes ls -la /opt/data/profiles/backoffice           # UID 10000, not root?
docker exec hermes head -5 /opt/data/profiles/backoffice/SOUL.md  # matches the repo file?
```

The delivery half is verifiable now. The *effect* — a distinctive line in `SOUL.md` changing the
agent's behaviour in a new session — cannot be until the gateway runs `-p backoffice`.

**Related:** G3 (the file is empty), plan §3, §11.1,
[docs/design/persona-delivery.md](../design/persona-delivery.md) — which carries the read-only
decision, the `SOUL.md` / `SOUL_DEVELOPS.md` question, and the multi-persona target layout.

---

## G3 — `agents/backoffice/SOUL.md` is empty

**Priority:** P1 — cheapest high-value item in the plan, and now the only thing standing between
the repo and a working persona.

The file exists at 0 bytes. The persona described in plan §3 does not exist anywhere; the agent
runs on Hermes defaults. Since G2 closed, this file **is** mounted at
`/opt/data/profiles/backoffice/SOUL.md`, so its
emptiness now actively shadows whatever the setup wizard wrote into the volume rather than merely
being ignored.

**Evidence:**

```sh
stat -c '%s bytes' agents/backoffice/SOUL.md   # → 0 bytes
```

**Fix:** fill from `agents/template/SOUL.md`, following plan §3.3. Two decisions to make while
filling it:

- **Omit the "What you remember" section** if and when the reader/writer split (plan §10.1) lands —
  under that split the reader holds recall only, and the retention rules belong to the writer.
  Today there is no split, so the single `backoffice` profile legitimately carries both.
- **Omit the "Untrusted content" section** until some tool actually emits `<untrusted_content>`
  markers. The template says so itself: teaching the agent to expect markers it will never see is
  worse than omitting the section.

**Verify:** the delivery path is in place (G2), so it is a straight check —
`docker exec hermes head -5 /opt/data/profiles/backoffice/SOUL.md` after
`git pull && docker compose restart hermes` must show what you wrote.

---

## G1 — `NOTION_API_KEY` is declared but reaches no container

**Priority:** P2 — nothing breaks, but the repo misrepresents its own state.

*Originally:* the root `.env.example` declared `NOTION_API_KEY` while no service received it, so
the repo implied a Notion capability it did not have.

*As of 2026-08-19:* the key has been **moved out of the root `.env.example`** into
`agents/<name>/.env.example`, where it sits commented out with a note that nothing consumes it yet.
The delivery path exists (per-profile `.env`, mounted `:ro`); the consumer does not. The repo no
longer claims a capability it lacks, so what remains is the actual Notion work in plan §4 rather
than a documentation defect.

**Evidence:**

```sh
grep -c NOTION docker-compose.yml   # → 0
```

**Stated intent.** `.env.example` now carries the annotation:

> Agents need their own token key to fine-grain control access rights.
> Move to `agents/<agent-type>/.env.example`

That is the right instinct and it matches plan §9.2: per-profile Notion scope has to come from a
per-profile *integration*, because scoping by prompt does not satisfy the §0 access constraint.
It also points the same direction as plan §4.2.1, where the token belongs to the sync service and
the agent holds no Notion credential at all.

**Fix — pick one, and do it in the same commit as the `.env.example` line:**

| Option | When | Action |
|---|---|---|
| **A — remove** | Notion work is not imminent | Delete the key from root `.env.example`. Re-add it under the design that actually lands. Leaves no false signal. |
| **B — per-agent env** | **Chosen, in progress 2026-08-19** | `agents/<name>/.env.example` exists and is mounted read-only into each profile home; the real `.env` is gitignored. The key is **commented out** there, because nothing consumes it yet — uncommenting it is the remaining step, and belongs with §4, not before it. |
| **C — plumb as-is** | Running the interim spike in plan §4.4 | Add `- NOTION_API_KEY` (bare form) to the `hermes` service. **Time-box it.** On this path the agent holds a Notion credential directly and free-text Notion content reaches it unscreened — acceptable only while the surface stays Tailscale-only, never once Slack lands. |

**Do not leave it dangling.** Whichever option, the repo should not claim a capability it lacks.

---

## G5 — Images track `:latest`

**Priority:** P2.

Both `hermes` and `hindsight` float on `:latest`, so a breaking upstream release lands unannounced
on the next `docker compose pull`. Plan §15 lists version pinning as the mitigation for release
churn, which means **the repo currently contradicts its own stated risk control**.

**Evidence:**

```
nousresearch/hermes-agent:latest
ghcr.io/vectorize-io/hindsight:${HINDSIGHT_VERSION:-latest}
```

(`pgvector/pgvector:pg${HINDSIGHT_DB_VERSION:-18}` is already pinned to a major — fine.)

**Fix:** pin both to known-good tags. `HINDSIGHT_VERSION` already exists as the override hook;
add an equivalent `HERMES_VERSION` for symmetry. Test upgrades against a scratch stack before
pulling on the live one.

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

**Priority:** P2 — a knowing deviation with a mitigation, not an oversight. It becomes P1 the day
§4 ships.

Plan §6 states the condition plainly: *"Do not open Slack before §10.1 is in place. The reader/
writer split is a prerequisite, not a follow-up."* Slack is being opened anyway.

**Why the deviation is defensible today.** The threat §10.1 defends against is untrusted *tool
output* — a poisoned Notion note reaching the process that writes memory. That path does not exist
yet: §4 has not shipped, so the agent holds no `crm_*` tools, and
`agents/backoffice/config.yaml` disables the `web`, `terminal`, `files` and `browser` toolsets.
What Slack actually adds is narrower: people who are not you can now say things that Hermes syncs
to Hindsight after each response, where they become durable memory.

**Mitigation in place:**

| Control | Where | Effect |
|---|---|---|
| `memory.write_approval: true` | `agents/backoffice/config.yaml` | Retention is staged for review instead of landing silently. This is the load-bearing one. |
| `app_mention` as the only bot event | `agents/backoffice/slack-manifest.yaml` | Slack never delivers the channel's other messages, so mention-only holds at the Slack layer even if the config key is wrong. |
| One channel, explicit allowlist | the `/invite`, and `channels.slack` | The bot cannot read channels it was not invited to. Never `GATEWAY_ALLOW_ALL_USERS=true`. |
| No DM scopes | `slack-manifest.yaml` | No second, unwitnessed surface — plan §6.2. |

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
