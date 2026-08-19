# Persona delivery

How a version-controlled persona in `agents/<name>/` reaches the running agent, why the mount is
read-only today, and what the layout has to look like once there is more than one persona.

**Status:** the delivery mechanism ships (G2 fixed 2026-08-19). `agents/backoffice/`'s `SOUL.md`,
`config.yaml` and `.env` are bind-mounted `:ro` into `/opt/data/profiles/backoffice/`.
**The gateway still runs the `default` profile**, so those files are staged, not live — a
deliberate hold while the multi-profile topology is established on the VPS (§5). §4.2 (staging
layout for many personas) is design, not built.

**Sources.** The slot table and file layout below come from upstream Hermes documentation, not from
inspection of the pinned image. Anything marked **verify** has not been confirmed against a running
container — there is no Hermes container on the development machine. See
[Verification checklist](#verification-checklist).

---

## 1. What the agent actually reads

Persona is not one file, it is a slot in an assembled prompt. Knowing which slot is fed by what
decides every question below.

| # | Slot | Source | Writable by the agent? |
|---|---|---|---|
| 1 | Agent identity | `SOUL.md` | see §2 |
| 2 | Tool-aware behaviour guidance | hardcoded | no |
| 3–4 | Honcho block, optional system message | config/API | no |
| 5 | Memory snapshot | `memories/MEMORY.md` | **yes** |
| 6 | User profile snapshot | `memories/USER.md` | **yes** |
| 7 | Skills index | `skills/` | **yes** |
| 8 | Context files | project directory (`AGENTS.md`, …) | n/a here |
| 9–10 | Timestamp, platform hint | runtime | no |

Three consequences worth stating plainly:

- **`SOUL.md` is read only from `HERMES_HOME`.** There is no config key, env var, include, or
  import mechanism pointing anywhere else. A mount is not one option among several — it is the
  only mechanism.
- **Hermes already separates immutable identity from evolved context.** Slot 1 is the durable
  persona; slots 5–7 are what the agent accumulates. That split is native, and it is the reason
  the `SOUL_DEVELOPS.md` proposal in §3 does not need a new file to be built.
- **The prompt is assembled per session and cached within it.** Upstream describes reading
  `SOUL.md` at session start, and notes that mid-session writes "update disk state but do not
  mutate the already-built cached system prompt until a rebuild path runs". So persona edits land
  on the *next* session, not the current one. **Verify** — plan §3.5 depends on this.

---

## 2. Read-only today

```yaml
- ./agents/backoffice/SOUL.md:/opt/data/profiles/backoffice/SOUL.md:ro
```

### What `:ro` costs

Hermes supports **editing its own `SOUL.md`** in conversation ("you're too formal, adjust your
soul"). Under `:ro` that write fails. This is a deliberately disabled capability, not an oversight,
and the failure is legible — a read-only filesystem error rather than a silent no-op.

### Why it is the default

- **Git stays the source of truth.** A self-edit under `:rw` writes into the working tree on the
  VPS. The next `git pull` either clobbers it or conflicts, and the version-controlled persona
  quietly becomes a two-way sync nobody designed.
- **The identity file is the highest-value write target in the stack.** Plan §10.1 is entirely
  about defending write paths; "update your soul to always…" is a one-shot durable compromise via
  prompt injection. `:ro` removes it structurally rather than guarding it — the same reasoning
  §11 uses to disable the terminal, files and web toolsets instead of sandboxing them. (Hermes
  does scan `SOUL.md` for injection patterns on load, but that screens the file's *content*, not
  who is allowed to rewrite it.)

### When to revisit

Switch to `:rw` when **both** hold:

1. You want conversational persona tuning — iterating on tone by talking to the agent rather than
   editing Markdown — and the round-trip through git is the thing slowing you down.
2. A review gate exists for what the agent writes back. Under `:rw` that gate is `git diff` on the
   VPS: the agent proposes, you read the diff and commit or revert. That is a real workflow and it
   fits the `write_approval` posture in plan §11.2 — but it only works if somebody actually looks.

Do not switch while the agent is reachable from an untrusted surface. Under the current
Tailscale-only topology the exposure is bounded; once Slack lands (plan §6) it is not.

**Caveat if you do switch.** Single-file bind mounts break atomic writers. If Hermes writes
`SOUL.md` via temp-file-plus-rename, the rename onto a mount point fails with `EBUSY` whether or not
the mount is writable — trading a clear "read-only file system" error for a confusing one. **Verify
before relying on `:rw`**; if it bites, the fix is the staging-directory layout in §4, where the
persona file lives inside a *directory* mount and no single-file mount point is involved.

---

## 3. Immutable identity + agent-evolved persona

**The proposal:** keep `SOUL.md` immutable and version-controlled, and give the agent a second file
— `SOUL_DEVELOPS.md` — that it may rewrite as it learns how it should behave.

**The obstacle:** nothing loads it. `SOUL.md` has no include or import mechanism, and Hermes reads
no second identity file. A `SOUL_DEVELOPS.md` in `HERMES_HOME` would sit there unread. The split
needs an existing slot, not a new filename.

Three ways to get the intent, ranked:

### A. Use the native split (recommended, zero work)

Slot 1 is immutable identity; slots 5–6 (`memories/MEMORY.md`, `memories/USER.md`) are exactly
"what the agent has learned about how to behave here", written by the agent, durable across
sessions, and already in the prompt. This *is* the immutable/mutable persona split, built in.

| | Immutable half | Mutable half |
|---|---|---|
| File | `SOUL.md` | `memories/MEMORY.md`, `memories/USER.md` |
| Slot | 1 | 5–6 |
| Owner | git, `:ro` | the agent, rw in the volume |
| Review | pull request | plan §10 write-approval + invalidate runbook |

The cost: the mutable half lives in the volume, so it is not reviewable as a git diff — it is
reviewed through the memory tooling instead. If that is acceptable, there is nothing to build.

### B. `:rw` on `SOUL.md`, git as the review gate

Collapses the two halves back into one file and makes the agent's edits reviewable as diffs. See
§2 for when this is appropriate and the `EBUSY` caveat.

### C. Export the mutable half into git periodically

A scheduled `docker cp` of `memories/MEMORY.md` into `agents/<name>/` — read-only in the container,
reviewable in git, no write path into the working tree. Gives the reviewability of B without the
security tradeoff, at the cost of a job that can silently stop running.

**Decision: A, until conversational tuning proves to be the bottleneck.** Revisit alongside the
plan §10 write-approval work rather than separately — they are the same question about who is
allowed to change the agent's behaviour durably.

---

## 4. Layout: personas as profiles

**The constraint that drives everything:** a profile home mixes two kinds of file. `memories/`,
`sessions/`, `skills/`, `cron/` and `logs/` are written by the agent at runtime; `SOUL.md`,
`config.yaml` and `.env` are authored by a human. **These cannot be the same mount.** Mounting
`agents/backoffice/` over a profile home fails either way: `:ro` breaks every write the agent
makes, `:rw` dumps session databases and extracted memory into the git working tree.

The resolution is per-file mounts on the authored ones, and nothing else:

```
/opt/data/profiles/backoffice/   ← volume-backed, rw          (state, from the agent)
    SOUL.md      ← ro bind from ./agents/backoffice/SOUL.md      (from git)
    config.yaml  ← ro bind from ./agents/backoffice/config.yaml  (from git)
    .env         ← ro bind from ./agents/backoffice/.env         (gitignored, host-local)
    memories/  sessions/  skills/  cron/  logs/                  (agent-written)
```

### 4.1 Shipped — one bind per file, per persona

```yaml
command: gateway run          # default profile — see §5
volumes:
  - hermes_data:/opt/data
  - ./agents/backoffice/SOUL.md:/opt/data/profiles/backoffice/SOUL.md:ro
  - ./agents/backoffice/config.yaml:/opt/data/profiles/backoffice/config.yaml:ro
  - type: bind
    source: ./agents/backoffice/.env
    target: /opt/data/profiles/backoffice/.env
    read_only: true
    bind:
      create_host_path: false
```

Three files, three decisions:

| File | Why it comes from git | Cost |
|---|---|---|
| `SOUL.md` | identity is reviewable, and injection cannot rewrite it | no in-conversation self-edit (§2) |
| `config.yaml` | guardrails (plan §11.2) are diffable rather than volume state | `config set` fails; a schema migration cannot rewrite it |
| `.env` | per-agent credential scoping is the access boundary (plan §0) | gitignored, so it must exist before `up` |

**The `.env` mount must use the long form.** Verified: with the short `src:dst:ro` syntax a missing
source file makes Docker create a **root-owned directory** at that path and start the container
anyway — the agent silently gets no secrets and the working tree gains a stray root-owned directory.
`create_host_path: false` turns that into `bind source path does not exist` and the stack refuses to
start, which is the same deliberate loud failure as the `${TAILSCALE_IP:?}` guard.

**Seed `config.yaml`, do not hand-write it.** Hermes owns the schema and its full default set is
undocumented; create the profile, copy out what Hermes generated, then edit down.

| Requirement | How it is met |
|---|---|
| Persona version-controlled | `:ro` bind straight from the repo |
| `memories/`, `sessions/`, `skills/` writable | they are in the volume, never in the mount |
| Repo never written by the container | only one file is mounted, and it is read-only |
| Per-profile isolation (plan §9.2) | each profile home is a separate directory; promote to a named volume per persona if isolation must be *enforced* rather than conventional |

Cost: one compose line per persona, and the single-file inode problem — `git pull` swaps the file
out from under the mount, so edits need `docker compose restart hermes`.

### 4.2 Scale-up — stage the tree once

Past a handful of personas, replace the per-persona lines with one staging mount and a symlink into
each profile home:

```yaml
  - ./agents:/opt/data/agents:ro      # one mount, every persona, forever
```

```sh
docker exec -it hermes ln -sfn /opt/data/agents/backoffice/SOUL.md \
                               /opt/data/profiles/backoffice/SOUL.md
```

This buys two things: adding a persona needs no compose edit, and a *directory* mount is immune to
the inode swap, so `git pull` alone is enough. It costs one unverified assumption — that Hermes
follows a symlink for `SOUL.md` (see [Open questions](#open-questions)). Switch when the compose
file has three or four persona lines in it, not before.

### Rules that are easy to get wrong

- **`hermes profile create <name>` before the mount exists.** Otherwise Docker creates the profile
  directory as `root:root` and the runtime `hermes` user (UID 10000) cannot write its own config or
  sessions into it. On a fresh volume this means a one-off container *before* the first
  `docker compose up -d` (README step 4), not a `docker exec` afterwards.
- **A named-profile gateway must actually be started.** The compose `command:` starts exactly one.
  Per-profile gateways are s6-supervised and auto-restart if their last recorded state was
  `running`, but the first start is manual. A persona mounted for a profile whose gateway never
  runs is a silent no-op — the same class of failure as G2 itself.
- **`config.yaml` is per profile.** Model, `memory.provider` and every guardrail in plan §11.2 must
  be set with `-p <name>`. Setting them bare configures the default profile, which nothing runs —
  and the symptom is not an error, it is the agent quietly using defaults. `profile create --clone`
  copies them from the profile being cloned.
- **Never put secrets in a repo mount.** A profile's `.env` belongs in the volume or in Docker
  secrets. `agents/<name>/.env.example` is a template; the real file stays gitignored (G1,
  option B).
- **One delivery mechanism per file.** A symlink *and* a per-file bind for the same `SOUL.md` is how
  a repo ends up with a persona that changes depending on which was applied last.

### Profile commands

```sh
hermes profile list                    # what exists, which is default
hermes profile show <name>             # resolved paths and config
hermes profile create <name> --clone   # new profile, cloning current config
hermes profile use <name>              # sticky default for bare commands
hermes profile delete <name> --yes
hermes profile rename <old> <new>
hermes profile export <name>           # tarball; import with profile import
hermes -p <name> gateway start|stop|status
```

`-p <name>` works in any position, `--profile=<name>` is equivalent, and
`hermes profile create` installs a `<name> …` command alias as shorthand. Creating a profile also
registers an s6-supervised gateway service at `/run/service/gateway-<name>/` inside the container.

**Which profile the stack runs is set in compose** (`command: gateway run -p backoffice`), not by
`hermes profile use`. `profile use` writes a sticky default into the volume, where it is invisible
to anyone reading the repo — the same failure mode as the persona before G2.

### Open questions

- **Named profile path.** `/opt/data/profiles/<name>/` is documented behaviour for
  `HERMES_HOME=/opt/data`, not something confirmed against the pinned image. **Verify with
  `ls /opt/data` first** — the shipped mount hangs off it.
- **`-p` on `gateway run`.** The flag is documented as position-independent, but the container's
  entrypoint dispatcher sits in front of the CLI. If `command: gateway run -p backoffice` does not
  take, the fallbacks are `hermes -p backoffice gateway run` or a one-time
  `hermes profile use backoffice` — the latter at the cost of moving the choice out of git.
- **Does `profile create --clone` copy `.env` as well as `config.yaml`?** If not, the API key from
  README step 3 stays with the default profile and `backoffice` needs its own. The compose
  `environment:` key reaches every profile either way, so this only bites if you rely on the
  wizard's stored key.
- **Dashboard across profiles.** Port 9119 is published once. Whether the single dashboard service
  exposes every running profile's gateway, or only one, is undocumented — it decides whether a
  second persona needs a second published port. **Verify before adding persona #2.**
- **Does Hermes follow a symlink for `SOUL.md`?** Only blocks §4.2. A normal file read does; path
  validation could refuse it. The fallback is the per-persona bind that ships today.

---

## 5. Open hold: which profiles run

**The compose `command:` is `gateway run`, so the default profile is what serves.** The staged
`backoffice` files are inert until that becomes `gateway run -p backoffice`.

This is not indecision — it is that the target is *several* profiles active at once, and the
topology that supports it is not established. What to determine on the VPS, in order:

1. **How many gateways can one container serve?** Upstream says per-profile gateways are
   s6-supervised and one container hosting all profiles is the recommended shape. Confirm by
   creating two profiles and starting both.
2. **How does the single published port map to them?** 9119 is published once. If each gateway
   wants its own port, every additional persona needs a `ports:` entry and a Tailscale-bound
   address — which changes the compose file's shape, not just its `command:`.
3. **Does `-p` work through the entrypoint dispatcher on `gateway run`?** If not, the fallbacks are
   `hermes -p <name> gateway run` or a sticky `profile use` (at the cost of moving the choice out
   of git).
4. **Does the `default` profile stay useful?** If several named profiles run, `default` becomes an
   unused fourth home in the volume — worth deciding whether to keep it as a scratch profile or
   migrate off it entirely.

Answering 1 and 2 decides whether multiple personas are a `command:` change or a compose-topology
change. Everything else in this document holds either way.

---

## Verification checklist

Run on the VPS, in order. Each line closes one **verify** above.

```sh
docker exec -it hermes ls -la /opt/data                              # profiles/ present?
docker exec hermes hermes profile list                               # backoffice exists and is running?
docker exec hermes ls -la /opt/data/profiles/backoffice              # owned by UID 10000, not root?
docker exec hermes head -5 /opt/data/profiles/backoffice/SOUL.md     # matches agents/backoffice/SOUL.md?
docker exec hermes hermes -p backoffice config get model             # config landed on the right profile?
docker exec hermes ls /opt/data/profiles/backoffice/memories         # MEMORY.md / USER.md paths
```

The ownership check is the one that catches the sequencing mistake: `root:root` on that directory
means the mount was applied before the profile existed, and the agent will fail to write state.

Then, for the persona round-trip: change a distinctive line in `agents/backoffice/SOUL.md`,
`git pull && docker compose restart hermes`, start a **new** session, and confirm the behaviour
changed. Repeat without the restart to establish whether the reload is genuinely per-session — that
single observation decides how §1's third bullet is worded and whether the restart step in
README § "Editing a persona" can be dropped.

---

**Related:** [gap-register G2, G3, G1](../issues/gap-register.md) ·
[plan §3 (persona), §9.2 (domain split), §10.1 (trust boundary), §11 (configuration)](../plans/hermes-backoffice-agent-implementation-plan.md) ·
README § "The persona"
