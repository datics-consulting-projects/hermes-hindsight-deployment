#!/usr/bin/env bash
#
# Deploy this repo to the VPS: pull, apply, restart, report.
#
#   ./scripts/deploy.sh
#
# WHY THE RESTART IS NOT OPTIONAL. "docker compose up -d" alone does nothing
# after a git pull. Compose sees no change to the service definition, so it
# does not recreate the container — and git replaces every modified file with a
# NEW INODE, which a single-file bind mount does not follow. SOUL.md,
# config.yaml and .env are all single-file mounts here, so without the restart
# the container silently keeps serving the previous persona and configuration.
# Same note lives in docker-compose.yml above the SOUL.md mount.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
load_deploy_env

# The VPS pulls from the remote, so anything not pushed is not deployed. Warn
# rather than block: deploying an older commit on purpose is legitimate.
if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
  note "warning: uncommitted changes in the working tree — they will NOT deploy"
fi
if git -C "$repo_root" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  unpushed=$(git -C "$repo_root" rev-list --count '@{upstream}..HEAD')
  if [ "$unpushed" -gt 0 ]; then
    note "warning: $unpushed unpushed commit(s) — they will NOT deploy"
  fi
fi

heading "Deploying to $HERMES_SSH:$HERMES_DIR"

remote <<'REMOTE'
set -euo pipefail
cd "$1"

echo "-- git pull"
git pull --ff-only

# The hermes service carries "pull_policy: build", so this also rebuilds the
# derived image (docker/Dockerfile) — from cache unless that file changed, and
# without pulling a newer upstream base. No --build flag to forget, and no
# accidental Hermes upgrade on a routine deploy; see README § Upgrading.
echo "-- docker compose up -d"
docker compose up -d

# See the header of deploy.sh: this is what makes edited mounts take effect.
echo "-- docker compose restart hermes"
docker compose restart hermes

echo "-- status"
docker compose ps

echo "-- recent hermes log"
docker compose logs --tail 30 --no-log-prefix hermes
REMOTE

heading "Done"
note "Slack changes? verify them with: ./scripts/slack-preflight.sh verify"
