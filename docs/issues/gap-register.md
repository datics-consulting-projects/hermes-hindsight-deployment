# Gap Register

Concrete defects found in this repository, verified against the files as of 2026-08-19.

These are **actionable now** and independent of the phased roadmap in
[the implementation plan](../plans/hermes-backoffice-agent-implementation-plan.md). Closing them
leaves the current deployment strictly better whether or not the rest of the plan ever ships.

Priority reflects *actual risk today*, not position in the roadmap.

| # | Priority | Gap | Status |
|---|---|---|---|
| [G6](#g6--backups-documented-but-not-scheduled) | **P1** | Backups documented but not scheduled | Open |
| [G2](#g2--agents-is-never-mounted-into-any-container) | **P1** | `agents/` never mounted into any container | Open |
| [G3](#g3--agentsbackofficesoulmd-is-empty) | **P1** | `agents/backoffice/SOUL.md` is empty | Open |
| [G1](#g1--notion_api_key-is-declared-but-reaches-no-container) | P2 | `NOTION_API_KEY` declared but reaches no container | Open |
| [G5](#g5--images-track-latest) | P2 | Images track `:latest` | Open |
| [G7](#g7--hindsight-has-no-resource-limit) | P3 | Hindsight has no resource limit | Open |
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

**Priority:** P1 — silently disables the persona layer.

The `hermes` service mounts only `hermes_data:/opt/data`. Nothing bind-mounts or copies `agents/`,
so the `SOUL.md` files in this repo **cannot reach the running agent**. Editing them has no effect,
which makes the version-controlled persona a fiction: the agent runs on whatever is inside the
volume.

This also breaks the property plan §3.5 relies on — "persona edits take effect on the next
interaction" is only true for the copy inside the volume.

**Evidence:**

```sh
grep -c agents docker-compose.yml   # → 0
```

**Fix:** bind-mount the persona into the profile path inside `/opt/data`, or add an explicit deploy
step that copies it in. **Confirm the real path first** — do not assume
`~/.hermes/profiles/<name>/`, which was the predecessor plans' host-install layout, not this
container's:

```sh
docker exec -it hermes ls /opt/data
```

**Verify:** change a distinctive line in `SOUL.md`, restart, and confirm the agent's behaviour
reflects it.

**Related:** G3 (the file is empty), plan §3, §11.1.

---

## G3 — `agents/backoffice/SOUL.md` is empty

**Priority:** P1 — cheapest high-value item in the plan.

The file exists at 0 bytes. The persona described in plan §3 does not exist anywhere; the agent
runs on Hermes defaults.

**Evidence:**

```sh
stat -c '%s bytes' agents/backoffice/SOUL.md   # → 0 bytes
```

**Fix:** fill from `agents/template/SOUL.md`, following plan §3.3. Two decisions to make while
filling it:

- **Omit the "What you remember" section** if and when the reader/writer split (plan §10.1) lands —
  under that split the reader holds recall only, and the retention rules belong to the writer.
  Today there is no split, so the single `default` profile legitimately carries both.
- **Omit the "Untrusted content" section** until some tool actually emits `<untrusted_content>`
  markers. The template says so itself: teaching the agent to expect markers it will never see is
  worse than omitting the section.

**Verify:** G2 must be closed first, or this file still won't load.

---

## G1 — `NOTION_API_KEY` is declared but reaches no container

**Priority:** P2 — nothing breaks, but the repo misrepresents its own state.

`.env.example` declares `NOTION_API_KEY`, and the README says nothing to contradict it. No service
in `docker-compose.yml` receives the variable, so Notion is **not wired up**. Anyone reading the
repo would reasonably conclude otherwise and could plan work on that belief.

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
| **B — per-agent env** | Following the annotation now | Create `agents/<agent-type>/.env.example`, establish how those files reach the container (depends on G2), and plumb the variable through. |
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
