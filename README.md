# hermes-vps-stack

Minimal Docker Compose deployment of a Hermes Agent gateway server with the
[Hindsight](https://hindsight.vectorize.io) memory provider, backed by its
own PostgreSQL instance. Designed to run 24/7 on a VPS reachable only via
Tailscale, controlled remotely from Hermes Desktop.

## Architecture

```
Hermes Desktop (laptop) ──Tailscale──▶ hermes:9119 (dashboard backend)
                                          │  (agent runs in this container)
                                          │
                                          ▼  (internal docker network)
                                  hindsight:8888 (not published)
                                          │
                                          ▼
                                  hindsight-db (PostgreSQL + pgvector)
```

- Only port **9119** is published, and only on the VPS's Tailscale IP. The
  provider's firewall already blocks all public traffic, but binding the
  publish address explicitly means the port isn't reachable even if that
  firewall config ever changes.
- Hindsight and its Postgres are internal-only — Hermes reaches Hindsight by
  its container name (`http://hindsight:8888`) over the compose network.
- Hermes' other documented port, **8642**, is the OpenAI-compatible API
  server. It is *disabled by default* (`API_SERVER_ENABLED` is unset) and is
  not part of this path — the dashboard backend on 9119 is what Hermes
  Desktop talks to. Nothing here needs 8642, so it is neither enabled nor
  published.

### A note on "the UI"

Hermes Desktop's **Remote Gateway** connection and the browser-based
**web dashboard** are the same backend on port 9119 — there's no separate,
lighter-weight channel for the desktop app. So "reachable from Hermes
Desktop" and "the dashboard is running" are the same thing here. What you
*don't* get is public reachability: the port is bound to the Tailscale
interface only, and it's gated behind Basic Auth (mandatory for any
non-loopback bind — Hermes refuses to start the dashboard otherwise).
Anyone on your tailnet with the credentials could open it in a browser too,
but nobody outside it can.

## Prerequisites

- Docker Engine + the Compose plugin installed on the VPS
- Tailscale already running on the VPS (per your existing setup)
- An LLM API key for Hermes itself (whatever chat model you want to use) —
  see [Choosing the Hermes chat model](#choosing-the-hermes-chat-model)
- An LLM API key for Hindsight's fact extraction (can be the same key/provider,
  or something cheap like Groq — this is a separate, usually much higher-volume
  call path than your actual chat turns)

## Setup

1. **Copy this repo to the VPS** (e.g. `/opt/hermes-stack`) and get your
   Tailscale IP:

   ```sh
   tailscale ip -4
   ```

2. **Create `.env`** from the example and fill in real values:

   ```sh
   cp .env.example .env
   # edit .env: TAILSCALE_IP, dashboard credentials, Hermes chat-model key,
   # Hindsight LLM key, Hindsight DB password
   ```

   Every one of those is required and guarded — if you leave one unset,
   `docker compose up` fails with a message naming the variable rather than
   starting in a degraded state. This matters most for `TAILSCALE_IP`: an
   empty value would otherwise render the port mapping as plain `9119:9119`
   and publish the dashboard on **every** interface.

3. **Run the Hermes setup wizard once, interactively**, before starting the
   background gateway. This writes your LLM keys and chat-platform config
   into the `hermes_data` volume:

   ```sh
   docker volume create hermes_data
   docker run -it --rm -v hermes_data:/opt/data nousresearch/hermes-agent setup
   ```

   The volumes in `docker-compose.yml` carry explicit `name:` keys, so this
   bare `hermes_data` really is the volume the stack mounts. (Without them,
   Compose would namespace it to `<project>_hermes_data` and the wizard's
   output would be silently invisible to the running gateway.)

4. **Create each agent's `.env`.** The stack mounts
   `agents/backoffice/.env` and **will not start without it**:

   ```sh
   cp agents/backoffice/.env.example agents/backoffice/.env
   ```

   The mount is deliberately strict (`create_host_path: false`), so a missing
   file stops the stack with `bind source path does not exist`. With Docker's
   default behaviour you would instead get a silently-created *root-owned
   directory* at that path and an agent with no secrets — verified, not
   theoretical. These `.env` files are gitignored; the `.env.example` beside
   each one is what's committed.

5. **Create the `backoffice` profile — before the first `docker compose up`.**
   The compose file mounts persona files into `/opt/data/profiles/backoffice/`.
   If that directory doesn't exist yet, Docker creates it as `root:root` and the
   runtime `hermes` user (UID 10000) can never write its own sessions or
   memories into it. `--clone` copies the configuration the wizard just wrote:

   ```sh
   docker run --rm -v hermes_data:/opt/data nousresearch/hermes-agent \
     profile create backoffice --clone
   ```

6. **Start the stack:**

   ```sh
   docker compose up -d
   docker compose logs -f
   docker exec hermes hermes profile list
   ```

   The gateway runs the **default** profile, not `backoffice` — see
   [Profiles: the open question](#profiles-the-open-question).

7. **Activate the Hindsight memory provider** (one-time; not settable via
   env var, so this needs to run once against the live container):

   ```sh
   docker exec -it hermes hermes config set memory.provider hindsight
   docker exec -it hermes hermes memory status
   ```

   These target the **default** profile, which is what the gateway runs today.
   `config` is per profile, so a named profile needs `-p <name>` — except
   `backoffice`, whose `config.yaml` is mounted read-only from the repo and
   already carries this setting.

   The `HINDSIGHT_MODE=local_external` and `HINDSIGHT_API_URL` env vars in
   the compose file already point it at the sidecar container, so no further
   Hindsight configuration is needed. Those are container-wide environment
   variables, so unlike `config.yaml` they apply whichever profile runs.

8. **Connect from Hermes Desktop:** add a Remote Gateway connection to
   `http://<TAILSCALE_IP>:9119` with the Basic Auth credentials from `.env`.

## Choosing the Hermes chat model

This is the LLM the agent itself thinks with — separate from the Hindsight
extraction model further down. Configuring it takes **two steps in two
different places**, because Hermes splits secrets from settings:

> Secrets (API keys, tokens, passwords) go in `.env`; everything else in
> `config.yaml`.

### 1. The API key — `.env` (picked up by `docker-compose.yml`)

```sh
# in .env, next to the other secrets
OPENROUTER_API_KEY=sk-or-v1-...
```

`docker-compose.yml` passes this into the container. It is listed there in
the bare form (`- OPENROUTER_API_KEY`, with no `=${...}`) deliberately: that
form passes the variable through *only when it is set*, whereas
`${OPENROUTER_API_KEY:-}` would inject an empty string and shadow whatever
key the setup wizard already wrote into the volume.

Using a different provider? The same slot takes `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, etc. — add it to `.env` and to the `environment:` list of
the `hermes` service.

### 2. The model name — `hermes config set` (there is no env var)

**Hermes has no environment variable for the model.** It lives in
`config.yaml` inside the `hermes_data` volume, so it cannot be set from
`.env` or the compose file. Set it once against the running container, the
same way as the `memory.provider` step above:

```sh
docker exec -it hermes hermes config set model.default anthropic/claude-sonnet-4
docker exec -it hermes hermes config set model.provider openrouter
docker exec -it hermes hermes config get model     # verify
```

**Two keys, not one — `model` is a mapping, not a string.** `model.default`
holds the provider's own bare slug; `model.provider` says how to route it.
Setting them this way also fills in `model.base_url` automatically:

```yaml
model:
  default: anthropic/claude-sonnet-4
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
```

> **Do not write the provider into the model string.** `hermes config set model
> openrouter/anthropic/claude-sonnet-4` is accepted, prints `✓ Set model = …`,
> and is **broken**: a scalar `model:` is normalized to `{default: "<the whole
> string>"}` with no provider, so the `openrouter/` prefix is never stripped and
> goes out to the API as part of the model id. OpenRouter replies `HTTP 400:
> openrouter/anthropic/claude-sonnet-4 is not a valid model ID`, and only on the
> first chat turn — nothing complains at config time. Verified against
> `nousresearch/hermes-agent:latest` (Aug 2026).
>
> Hermes' own provider-prefix syntax uses a **colon**, not a slash
> (`openrouter:anthropic/claude-sonnet-4`), and that is a `/model` runtime
> switch — not the config file's shape.

`config.yaml` is **per profile**, and these bare commands target the profile the
gateway currently runs. The `backoffice` profile does not take its configuration
this way: its `config.yaml` is mounted read-only from `agents/backoffice/`, so
`hermes config set … -p backoffice` fails by design. Edit the file in git
instead. See [The persona](#the-persona).

`model.default` is the plain OpenRouter slug — what appears in their catalogue,
with no `openrouter/` in front:

| Example | Meaning |
| --- | --- |
| `anthropic/claude-sonnet-4` | pinned Anthropic model via OpenRouter |
| `google/gemini-2.5-flash` | cheap/fast option |
| `~anthropic/claude-sonnet-latest` | `~` prefix = always latest revision |

Suffixes work too: `:free` selects a free tier, `:nitro` sorts routing by
throughput, `:floor` by price. Check a slug against
<https://openrouter.ai/api/v1/models> before pinning it.

You can also do both steps interactively, which lists the provider's
available models:

```sh
docker exec -it hermes hermes model
```

Worth preferring if you are unsure of the exact slug — a typo'd model name
only surfaces as a failure on the first chat turn.

If you set the key and model through the wizard in step 3, both are already
in the volume and you can skip this section entirely.

### The Hindsight extraction model is configured separately

Hindsight runs its own, much higher-volume LLM calls and takes plain env
vars for all of it — provider, key **and** model:

```sh
HINDSIGHT_LLM_PROVIDER=openrouter
HINDSIGHT_LLM_API_KEY=sk-or-v1-...
HINDSIGHT_API_LLM_MODEL=anthropic/claude-sonnet-4   # note: no openrouter/ prefix
```

`openrouter` is a first-class Hindsight provider, so no OpenAI-compatible
base-URL workaround is needed. Two things differ from the Hermes side: the
model name here is the plain OpenRouter slug **without** the `openrouter/`
prefix, and the variable keeps its full `HINDSIGHT_API_` prefix because it is
passed through verbatim. Leave the model unset to accept the provider default.

## The persona

Each agent's identity lives in this repo under `agents/<name>/SOUL.md` and is
bind-mounted into its **profile home** in the container. Hermes loads `SOUL.md`
only from `HERMES_HOME` — there is no config key or env var pointing at another
path — so a mount is the only way to get a version-controlled persona in front of
the agent.

```yaml
# docker-compose.yml, hermes service
volumes:
  - hermes_data:/opt/data
  - ./agents/backoffice/SOUL.md:/opt/data/profiles/backoffice/SOUL.md:ro
  - ./agents/backoffice/config.yaml:/opt/data/profiles/backoffice/config.yaml:ro
  - type: bind                                     # .env — long form on purpose
    source: ./agents/backoffice/.env
    target: /opt/data/profiles/backoffice/.env
    read_only: true
    bind:
      create_host_path: false
```

A **profile** is a separate Hermes home. `backoffice` lives at
`/opt/data/profiles/backoffice/` and owns its own everything — three files come
from git, the rest is the agent's:

| Path in the profile home | Comes from | Writable by the agent |
| --- | --- | --- |
| `SOUL.md` | `agents/backoffice/`, `:ro` | no |
| `config.yaml` | `agents/backoffice/`, `:ro` | no — `config set` fails |
| `.env` | `agents/backoffice/`, `:ro`, gitignored | no |
| `memories/` (`MEMORY.md`, `USER.md`) | the volume | **yes** |
| `skills/` | the volume | **yes** |
| `sessions/`, `cron/`, `logs/` | the volume | **yes** |

That is the whole design: identity and configuration are code, and everything the
agent *accumulates* lands in the volume. The repo never receives a write from the
container, and the container never loses state on `git pull`.

`memories/` is worth understanding rather than fighting — it fills slots 5–6 of
the system prompt, which is already the mutable counterpart to `SOUL.md`'s
immutable slot 1.

Two consequences of mounting `config.yaml` read-only, both intended:

- **`hermes -p backoffice config set …` fails.** The file in git wins. Edit it
  there, commit, restart.
- **A Hermes upgrade that migrates the config schema cannot rewrite it.** If a
  version bump ever fails to start, check this first: copy the container's
  migrated file back into the repo and commit it.

Seed `config.yaml` from a profile Hermes generated rather than hand-writing it —
the schema is not fully documented. The file says how.

### Profiles: the open question

**The gateway currently runs the `default` profile**, so the mounted `backoffice`
files are staged but not read by the running agent:

```yaml
command: gateway run          # not "gateway run -p backoffice"
```

This is deliberate. The goal is several profiles active at once, and how Hermes
resolves them — one gateway per profile, how the single published dashboard port
maps to them, whether `-p` on `gateway run` behaves through the container's
entrypoint — is worth watching on the VPS before the compose file commits to an
answer. Bring the stack up, create profiles by hand, inspect.

Switching the stack to the mounted persona is a one-word change:

```yaml
command: gateway run -p backoffice
```

Until then, treat `agents/backoffice/` as staged configuration, not live
behaviour. Open questions and what to measure are in
[docs/design/persona-delivery.md](docs/design/persona-delivery.md).

### Profile commands

```sh
docker exec hermes hermes profile list                   # what exists, which is default
docker exec hermes hermes profile show backoffice        # paths and config for one
docker exec hermes hermes profile create sales --clone   # new persona, cloning current config
docker exec hermes hermes profile use backoffice         # sticky default for bare commands
docker exec hermes hermes -p backoffice gateway status   # is this persona's gateway up
docker exec hermes hermes -p backoffice gateway stop     # disable it without deleting it
```

Creating a profile also registers an s6-supervised gateway service inside the
container and installs a `backoffice …` command alias as shorthand for
`hermes -p backoffice …`. Which profile the **stack** runs is set declaratively by
`command: gateway run -p backoffice` in the compose file rather than by
`profile use`, so it is visible in git instead of buried in the volume.

### Why the mount is read-only

Hermes can **edit its own `SOUL.md`** in conversation ("you're too formal, adjust
your soul"). `:ro` disables that on purpose, for two reasons: git stays the single
source of truth (a self-edit under `:rw` lands in the working tree on the VPS and
the next `git pull` clobbers or conflicts with it), and the identity file is the
highest-value target for prompt injection — "update your soul to always…" is a
one-shot durable compromise, and removing the write removes it structurally.

**This may become `:rw` later.** The case for flipping it is conversational
persona tuning, with `git diff` on the VPS as the review gate. Don't do it while
the agent is reachable from an untrusted surface. Tradeoffs, the `EBUSY` caveat
for single-file mounts, and the `SOUL.md` / `SOUL_DEVELOPS.md` split are worked
through in [docs/design/persona-delivery.md](docs/design/persona-delivery.md).

### Editing a persona

```sh
git pull && docker compose restart hermes
```

The restart is not optional. Git replaces a modified file with a **new inode**,
and a single-file bind mount keeps pointing at the old one — edit without
restarting and the container silently keeps serving the previous persona. Bind
mounts are re-resolved at container start, so a restart is the fix.

### Adding another persona

Same shape, one more time. Create the profile *before* adding its mount:

```sh
docker exec -it hermes hermes profile create sales --clone
```

```yaml
  - ./agents/sales/SOUL.md:/opt/data/profiles/sales/SOUL.md:ro
```

```sh
docker compose up -d
docker exec -it hermes hermes -p sales gateway start
docker exec hermes hermes -p sales gateway status      # must actually be running
```

Three rules, each of which fails silently if broken:

- **`profile create` before the mount**, or Docker creates
  `/opt/data/profiles/<name>/` as `root:root` and the `hermes` user (UID 10000)
  cannot write its own config or sessions into it.
- **Start the profile's gateway.** `command:` in the compose file runs
  `backoffice` only; a second persona needs its own gateway started once, after
  which s6 supervises and restarts it. A persona whose gateway never runs is a
  no-op — the same silent failure as an unmounted `SOUL.md`.
- **Configure the new profile.** `config.yaml` is per profile, so model and
  `memory.provider` must be set for it too (`--clone` copies them from the
  profile you cloned).

**Never mount `agents/<name>/` over a profile home** — that directory is mutable
agent state, not persona: `:ro` breaks every write the agent makes, `:rw` dumps
session databases and extracted memory into your git working tree. Mount leaf
paths only.

Past a handful of personas, one mount line each stops scaling and the tree gets
staged at a single read-only path instead; that design, plus what still needs
verifying on the VPS, is in
[docs/design/persona-delivery.md](docs/design/persona-delivery.md).

### `skills/` is deliberately not mounted

A profile's `skills/` directory is writable agent state — Hermes writes learned
skills there for review. Mounting it `:ro` from this repo would make skills fully
version-controlled at the cost of disabling that loop entirely. That is a real
decision, not a detail; it is left in the volume until it is made.

## Operating

```sh
docker compose logs -f hermes          # gateway + dashboard logs
docker compose logs -f hindsight       # memory extraction/synthesis logs
docker exec hermes hermes profile list                 # which personas exist
docker exec hermes hermes -p default gateway status    # the one the stack runs
docker exec hermes hermes memory status
```

Anything touching `config.yaml`, `.env`, memory or skills is per profile. Bare
commands hit the default profile — which is the one running today, but will not
be once `-p backoffice` goes into the compose `command:`. The flag works in any
position; `hermes profile create` also installs a `<name> …` command alias inside
the container as a shorthand.

## Upgrading

```sh
docker compose pull
docker compose up -d
```

Hermes runs non-interactive config migrations against the mounted volume on
startup and backs up `config.yaml`/`.env` first if a migration is needed.

## Backups

Everything that matters lives in two named volumes:

- `hermes_data` — config, sessions, skills, credentials
- `hindsight_pg_data` — all extracted memories (facts, entities, graph)

```sh
docker run --rm -v hermes_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/hermes_data.tar.gz -C /data .
docker run --rm -v hindsight_pg_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/hindsight_pg_data.tar.gz -C /data .
```

## A note on VPS sizing

Only the `hermes` service carries `deploy.resources.limits` (4G / 2 CPU).
Hindsight is deliberately left unlimited, but it is not free: depending on
how its embeddings provider resolves, it may load an embedding model
in-process rather than calling out to an API. On a small VPS, check actual
usage before assuming the defaults fit:

```sh
docker stats --no-stream
```

If Hindsight's resident size is uncomfortable, either point it at a hosted
embeddings provider or give it its own `deploy.resources.limits` block —
but note that a limit too low gets the container OOM-killed mid-extraction
rather than degrading gracefully.

## Optional: expose Hindsight's own memory browser

Hindsight ships a small control-plane UI (port 9999) for browsing what's
been retained. It's commented out in `docker-compose.yml` — uncomment the
`ports:` block under the `hindsight` service and re-run `docker compose up -d`
to reach it at `http://<TAILSCALE_IP>:9999`. It has no built-in
authentication, so only do this over Tailscale, never on a public interface.
