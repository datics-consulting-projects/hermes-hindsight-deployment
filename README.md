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
   docker exec hermes hermes gateway status -p backoffice
   ```

   The gateway runs the **`backoffice`** profile — `command: gateway run -p
   backoffice` in the compose file — so the persona files mounted in step 5 are
   the ones in front of the running agent. Check for a **second** gateway the
   first time you start after switching profiles; [Profiles](#profiles) explains
   why one can appear and how to stop it.

7. **Check the Hindsight memory provider is live:**

   ```sh
   docker exec -it hermes hermes memory status -p backoffice
   ```

   Nothing to activate: `memory.provider: hindsight` is already in
   `agents/backoffice/config.yaml`, mounted read-only from this repo. The
   `config set` dance is only needed for profiles whose config lives in the
   volume — the `default` profile, which the stack no longer runs:

   ```sh
   docker exec -it hermes hermes config set memory.provider hindsight   # default profile only
   ```

   The `HINDSIGHT_MODE=local_external` and `HINDSIGHT_API_URL` env vars in
   the compose file already point it at the sidecar container, so no further
   Hindsight configuration is needed. Those are container-wide environment
   variables, so unlike `config.yaml` they apply whichever profile runs.

8. **Connect from Hermes Desktop:** add a Remote Gateway connection to
   `http://<TAILSCALE_IP>:9119` with the Basic Auth credentials from `.env`.

9. **Optional — give the agent a Slack channel:** see [Slack](#slack). It needs
   no port and no compose change, but read [the gate it
   opens](#the-gate-this-opens) before inviting anyone.

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

- **`hermes config set … -p backoffice` fails.** The file in git wins. Edit it
  there, commit, restart.
- **A Hermes upgrade that migrates the config schema cannot rewrite it.** If a
  version bump ever fails to start, check this first: copy the container's
  migrated file back into the repo and commit it.

Seed `config.yaml` from a profile Hermes generated rather than hand-writing it —
the schema is not fully documented. The file says how.

### Profiles

**The stack runs the `backoffice` profile.** It is set in the compose file, not
with `profile use`, so which persona is live is visible in git rather than buried
in the volume:

```yaml
command: gateway run -p backoffice
```

That is what makes the mounted persona *live* rather than staged:
`/opt/data/profiles/backoffice/` is `HERMES_HOME` for the running agent, so the
`SOUL.md`, `config.yaml` and `.env` from this repo are the ones it reads.

**Watch for two gateways after switching profiles.** Creating a profile registers
an s6-supervised service, and on container start
`/etc/cont-init.d/02-reconcile-profiles` brings up every profile whose last
recorded state was `running`. The `default` profile ran before this switch, so
that state is still on the volume — and two agents serving one dashboard port,
with two separate session stores, is a confusing failure. Persist `default` as
stopped, once:

```sh
docker exec hermes hermes gateway stop                    # no -p: the default profile
docker exec hermes hermes gateway status -p backoffice    # the one that should be up
```

**Still open: several personas serving at once.** One gateway per profile is
straightforward; how the single published port 9119 maps to more than one of them
is not answered, and that is the thing to establish on the VPS before a second
persona goes into the compose file. What to measure is in
[docs/design/persona-delivery.md](docs/design/persona-delivery.md).

### Profile commands

```sh
docker exec hermes hermes profile list                   # what exists, which is default
docker exec hermes hermes profile show backoffice        # paths and config for one
docker exec hermes hermes profile create sales --clone   # new persona, cloning current config
docker exec hermes hermes profile use backoffice         # sticky default for bare commands
docker exec hermes hermes gateway status -p backoffice   # is this persona's gateway up
docker exec hermes hermes gateway stop -p backoffice     # disable it without deleting it
```

**`-p` goes after the subcommand, never before it.** `hermes -p backoffice
gateway status` dies in the container entrypoint with `s6-applyuidgid: fatal:
unable to exec -p`: `docker/main-wrapper.sh` dispatches on `command -v "$1"`, and
POSIX `sh` reads `command -v -p` as options with no operand, exits 0, and the
wrapper then tries to execute `-p` as a program. The flag position is load-bearing
here even though Hermes itself accepts either.

Creating a profile also registers an s6-supervised gateway service inside the
container and installs a `backoffice …` command alias as shorthand for
`hermes … -p backoffice`.

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
docker exec -it hermes hermes gateway start -p sales
docker exec hermes hermes gateway status -p sales      # must actually be running
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

### When a skill needs a CLI the image doesn't ship

Some bundled skills drive an external command-line tool and degrade quietly when
it is absent. The `notion` skill is the worked example: it prefers Notion's `ntn`
CLI and falls back to raw `curl` against the HTTP API "when `ntn` isn't
installed" — so a correctly-configured skill still answers `ntn: not found`.

**The agent cannot install it itself, by design.** `/opt/hermes` is root-owned
and non-writable at runtime, the gateway drops to the unprivileged `hermes` user
(UID 10000), and the image's runtime extension point
(`HERMES_LAZY_INSTALL_TARGET` → `/opt/data/lazy-packages`) installs *Python
packages for Hermes backends* — never CLI binaries. `docker exec -u root hermes
npm i -g ntn` does work, and is precisely the ad-hoc server state this repo
exists to avoid: invisible in git, undone by the next image pull, unreproducible
on a second host.

So the stack builds one layer on top of upstream instead — the whole of
[docker/Dockerfile](docker/Dockerfile):

```dockerfile
ARG HERMES_IMAGE=nousresearch/hermes-agent:latest
FROM ${HERMES_IMAGE}
ARG NTN_VERSION=0.22.8
RUN npm install --global "ntn@${NTN_VERSION}" && ntn --version
ENV NOTION_KEYRING=0
```

`ntn --version` in the same `RUN` is the build-time proof: a broken install
fails the build rather than reaching the VPS. The version is pinned so an
unrelated rebuild cannot swap the agent's tooling underneath it.

The compose service carries `build:` plus `pull_policy: build`, so
`docker compose up -d` rebuilds from cache (near-free) and no `--build` flag has
to be remembered. Note the build context is `./docker`, not `.` — the repo root
holds `agents/*/.env`, and live credentials have no business in a build context.
Refreshing the upstream base is a separate, deliberate command; see
[Upgrading](#upgrading).

**The split this preserves is the point.** The image grants the *tool*,
container-wide. The *credential* stays per agent in `agents/<name>/.env`, which
is the access boundary. A second persona gets `ntn` and no Notion access at all.

**Two names, one secret**, on the credential side. The skill declares
`NOTION_API_KEY` as its prerequisite — a real gate, not documentation: Hermes
turns a missing prerequisite into *"Setup needed before using this skill"* — and
uses that name in all thirteen of its `curl` examples. But the `ntn` CLI it
drives reads `NOTION_API_TOKEN`. Set only the key and the failure is quiet in
the worst way: the skill reports itself correctly configured while `ntn` reports
`API token is invalid`.

So set both. Hermes loads the profile `.env` with python-dotenv, which
interpolates `${VAR}`, so the second line references the first rather than
duplicating the secret and a rotated key changes in one place:

```sh
NOTION_API_KEY=ntn_...
NOTION_API_TOKEN=${NOTION_API_KEY}
```

The alternative — renaming the variable inside the bundled skill during the
image build — was tried and rejected. It works (`skills_sync` re-copies bundled
skills into the profile's own `skills/` dir on every gateway start, so a patched
skill does reach the running agent), but it buys one fewer `.env` line at the
price of owning a `sed` patch against an upstream file forever. Two documented
lines beat a vendored-file patch.

One thing that needed checking and turned out to be a non-issue: Hermes strips
provider credentials from terminal subprocesses, but the blocklist is name-based
and no `NOTION_*` name is on it, so both reach `ntn` normally — no
`terminal.env_passthrough` entry in `config.yaml` is required.

## Slack

Runbook and design: [docs/plans/slack-integration.md](docs/plans/slack-integration.md).
Open defects: [docs/issues/slack-integration.md](docs/issues/slack-integration.md).

The agent's second surface: one channel, mention-only, no DMs. Slack uses
**Socket Mode** — an outbound WebSocket — so nothing about the Tailscale-only
posture changes and **`docker-compose.yml` is not touched at all**. No port, no
new environment variable, no inbound anything.

Everything that can live in git does:

| Piece | Where | Why there |
| --- | --- | --- |
| Scopes, events, DM settings | `agents/backoffice/slack-manifest.yaml` | Not mounted — Hermes never reads it. It is what you paste into Slack's App Manifest tab, kept in git so a widened permission is a reviewable commit rather than an invisible click. |
| What the agent can *do* on Slack | `agents/backoffice/config.yaml`, `platform_toolsets.slack` | Already mounted `:ro`, so this needs **no `hermes config set` on the server**. Edit, commit, deploy. |
| Who may talk to it | `hermes pairing`, in the volume | Not config-as-code — a runtime approval store. Audit it, don't expect to review it in git. |
| The three tokens | `agents/backoffice/.env` (gitignored) | Per-agent, not root `.env`. The compose `environment:` list is container-wide — a second persona would inherit this bot's identity and be able to post as it. |

### Enabling it

Four steps happen in Slack's UI and cannot be automated (`apps.manifest.create`
exists but wants a configuration token that rotates every 12 hours — not worth a
rotating secret for one app). Everything else is a script.

```sh
# 0. Confirm what this Hermes build calls things, then uncomment the
#    channels.slack block in agents/backoffice/config.yaml.
./scripts/slack-preflight.sh discover
```

1. **api.slack.com/apps → Create New App → From a manifest**, paste
   `agents/backoffice/slack-manifest.yaml`.
2. **Enable Socket Mode** → generate the app-level token (`xapp-`).
3. **Install App to Workspace** → copy the bot token (`xoxb-`), and the signing
   secret from Basic Information.
4. Paste all three into `agents/backoffice/.env`.

```sh
./scripts/slack-preflight.sh check     # tokens present, live, Socket Mode really on
./scripts/deploy.sh                    # pull, up, restart hermes
./scripts/slack-preflight.sh verify    # config parsed, socket connected, pairings
```

Then `/invite` the bot to **exactly one** channel. It cannot read channels it
was not invited to, so the invite is the scope.

### Mention-only rests on one thing

The manifest subscribes to `app_mention` and nothing else, so Slack never
delivers the channel's other messages. That is the *whole* mechanism — this
build has no `channels:` config key, so there is no second layer and nothing to
fall back on. Adding `message.channels` to the manifest is therefore a single
decision that puts every message in the channel in front of the agent.

The test that matters is the silent one: post in the channel **without**
mentioning the bot and confirm nothing happens.

### The gate this opens

Slack is the first surface where people who are not you put text in front of the
agent. Two consequences, one fixed and one still open.

**What the agent can do there is restricted, and verified.**
`platform_toolsets.slack` in `agents/backoffice/config.yaml` leaves five
toolsets — `clarify`, `memory`, `session_search`, `skills`, `todo`. No terminal,
files, code execution, browser, web, delegation or cron. Your CLI and dashboard
keep all 18; the restriction is per-platform. Confirm after any change:

```sh
docker exec -it hermes hermes tools --summary -p backoffice
# -it because it refuses without a TTY; -p because tool config is PER PROFILE
# and a bare invocation reports `default`, which is not the profile that runs.
```

**Memory writes are the part still resting on trust.** Hermes syncs turns to
Hindsight after every response, so anything said in the channel tends toward
durable memory. The plan gates this behind the reader/writer split (§10.1),
which is not built; the interim is `memory.write_approval: true`. That key
round-trips through `config set`, but nothing observable proves it is
*enforced* — and in this build a config key that nothing reads is silent, not an
error. Keep the channel single, audit `hermes pairing list`, and never set
`GATEWAY_ALLOW_ALL_USERS=true`. Tracked as
[G8](docs/issues/gap-register.md).

## Operating

```sh
docker compose logs -f hermes          # gateway + dashboard logs
docker compose logs -f hindsight       # memory extraction/synthesis logs
docker exec hermes hermes profile list                     # which personas exist
docker exec hermes hermes gateway status -p backoffice     # the one the stack runs
docker exec hermes hermes memory status -p backoffice
```

From your laptop, so the stack is not driven by pasted `docker exec` lines
(`cp scripts/.env.example scripts/.env` first, and set the host):

```sh
./scripts/deploy.sh                    # pull + up -d + restart hermes, on the VPS
./scripts/slack-preflight.sh verify    # what the deployed agent sees of Slack
```

`deploy.sh` always restarts `hermes`, and that is the point rather than
belt-and-braces: `docker compose up -d` alone sees no change to the service
definition and leaves the container running, still holding the **old inodes** of
`SOUL.md`, `config.yaml` and `.env`.

Anything touching `config.yaml`, `.env`, memory or skills is per profile, so
almost every command above wants `-p backoffice`. **Bare commands hit `default`,
which is not the profile the stack runs** — that is the quiet way to spend ten
minutes reading the wrong profile's memory. `-p` must come *after* the
subcommand; see [Profile commands](#profile-commands) for why. `hermes profile
create` also installs a `<name> …` alias inside the container as a shorthand.

## Upgrading

```sh
docker compose pull                  # hindsight + postgres
docker compose build --pull hermes   # hermes: refresh the upstream base image
docker compose up -d
```

`hermes` is built, not pulled ([why](#when-a-skill-needs-a-cli-the-image-doesnt-ship)),
so `docker compose pull` cannot reach it — `--pull` on the build is what
re-resolves `nousresearch/hermes-agent:latest`. Two commands rather than one is
the deliberate cost of that: it also means no routine `up -d` or `deploy.sh` can
move the agent onto a new Hermes release by accident.

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
