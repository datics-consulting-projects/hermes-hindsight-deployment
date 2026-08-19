# The Hermes image this stack actually runs: upstream, plus the CLI tools the
# bundled skills expect to find on PATH.
#
# WHY THIS FILE EXISTS. Hermes' bundled `notion` skill has two paths — Notion's
# `ntn` CLI, and raw curl against the HTTP API — and picks the CLI "when
# installed". Upstream does not ship it, so the skill quietly degrades to the
# curl path and the agent reports `ntn: not found`.
#
# The agent cannot fix that itself, by design: /opt/hermes is root-owned and
# non-writable at runtime, the gateway drops to the unprivileged `hermes` user
# (UID 10000), and the image's own runtime extension point
# (HERMES_LAZY_INSTALL_TARGET -> /opt/data/lazy-packages) installs *Python
# packages for Hermes backends* only — never CLI binaries.
#
# That leaves two options. `docker exec -u root hermes npm i -g ntn` works, and
# is exactly the ad-hoc server state this repo exists to avoid: invisible in
# git, undone by the next image pull, and impossible to reproduce on a second
# host. Building one layer on top puts the capability in git next to every
# other deployment fact.
#
# Note the split this preserves: the image grants the *tool*, container-wide.
# The *credential* stays per agent in agents/<name>/.env, which is the access
# boundary. A second persona gets `ntn` and no Notion access whatsoever.

ARG HERMES_IMAGE=nousresearch/hermes-agent:latest
FROM ${HERMES_IMAGE}

# Pinned, not floating. A rebuild triggered by something unrelated must not be
# able to swap the agent's tooling underneath it — bump this in a commit.
ARG NTN_VERSION=0.22.8

# npm 11 blocks package install scripts by default and warns that ntn's
# `preinstall` hook was skipped. Deliberately left that way rather than passing
# --allow-scripts: the package ships the prebuilt Linux binary at bin/ntn, and
# the hook is only the downloader for platforms where it doesn't. `ntn
# --version` is the proof — it fails the build if the binary isn't runnable,
# instead of letting a broken install reach the VPS.
RUN npm install --global "ntn@${NTN_VERSION}" \
 && ntn --version

# There is no OS keychain in a container. Without this, `ntn` tries the keyring
# before falling back to NOTION_API_TOKEN. It is not a secret and not per-agent
# — it is a fact about running headless — so it belongs in the image rather
# than in an agent's .env.
ENV NOTION_KEYRING=0
