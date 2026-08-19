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

4. **Start the stack:**

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

5. **Activate the Hindsight memory provider** (one-time; not settable via
   env var, so this needs to run once against the live container):

   ```sh
   docker exec -it hermes hermes config set memory.provider hindsight
   docker exec -it hermes hermes memory status
   ```

   The `HINDSIGHT_MODE=local_external` and `HINDSIGHT_API_URL` env vars in
   the compose file already point it at the sidecar container, so no further
   Hindsight configuration is needed.

6. **Connect from Hermes Desktop:** add a Remote Gateway connection to
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
docker exec -it hermes hermes config set model openrouter/anthropic/claude-sonnet-4
docker exec -it hermes hermes config get model     # verify
```

The string is `openrouter/<vendor>/<slug>` — the `openrouter/` prefix selects
the provider, and the rest is the model's OpenRouter slug:

| Example | Meaning |
| --- | --- |
| `openrouter/anthropic/claude-sonnet-4` | pinned Anthropic model via OpenRouter |
| `openrouter/google/gemini-2.5-flash` | cheap/fast option |
| `openrouter/~anthropic/claude-sonnet-latest` | `~` prefix = always latest revision |

Suffixes work too: `:nitro` sorts routing by throughput, `:floor` by price.

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

## Operating

```sh
docker compose logs -f hermes          # gateway + dashboard logs
docker compose logs -f hindsight       # memory extraction/synthesis logs
docker exec hermes hermes -p default gateway status
docker exec hermes hermes memory status
```

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
