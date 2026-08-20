#!/usr/bin/env bash
#
# Slack enablement helper for the backoffice agent.
#
#   ./scripts/slack-preflight.sh discover   # what does THIS Hermes build call things?
#   ./scripts/slack-preflight.sh check      # are the tokens present and live? (local)
#   ./scripts/slack-preflight.sh verify     # did the deployed agent actually connect?
#
# "check" talks to Slack and nothing else — the tokens never leave this machine
# except to slack.com, which is the whole point of validating them here rather
# than reading a failure out of the gateway log later.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_env="$repo_root/agents/backoffice/.env"

# Read one KEY=value out of the per-agent .env without sourcing it.
val() {
  [ -f "$agent_env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$agent_env" | tail -n1 | sed 's/^["'\'']//; s/["'\'']$//'
}

# Pull a single scalar field out of a Slack JSON response. Uses jq when it is
# available and falls back to sed, so this works on a bare VPS shell too.
jget() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$2" | jq -r ".$1 // empty"
  else
    printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
  fi
}

slack_ok() { printf '%s' "$1" | grep -q '"ok":[[:space:]]*true'; }
slack_err() { [ -n "$1" ] && jget error "$1" || echo "no response — could not reach slack.com"; }

# set -e must not kill the run because the network is down; an unreachable
# Slack is a result to report, not a crash.
slack_call() { curl -sS -X POST "https://slack.com/api/$1" \
                 -H "Authorization: Bearer $2" \
                 -H "Content-type: application/x-www-form-urlencoded" 2>/dev/null || true; }

cmd_discover() {
  load_deploy_env
  heading "Discovering the Slack surface of the deployed Hermes build"
  note "Every command is best-effort — a 'not found' here is itself the answer."
  note "Paste this whole output back when writing the channels.slack block."

  remote <<'REMOTE'
cd "$1"
run() { printf '\n----- %s -----\n' "$*"; docker exec hermes "$@" 2>&1 || true; }

# Round 1 answered: `hermes slack` only generates manifests, and access
# control is `hermes pairing`, not an allowlist config key. What is still open
# is where Slack tokens are read from and whether channels.slack is real.

# Env var names, straight from the source. `hermes config` reports the install
# root as /opt/hermes — an earlier version of this probe assumed an importable
# python package and silently found nothing, which is not the same as "there
# are none". Print the file count so an empty result stays distinguishable
# from a broken search.
printf '\n----- SLACK_* env vars referenced by the install -----\n'
docker exec hermes sh -c '
  echo "searching /opt/hermes ($(find /opt/hermes -type f 2>/dev/null | wc -l) files)"
  grep -rhoE "SLACK_[A-Z0-9_]+" /opt/hermes 2>/dev/null | sort -u
' 2>&1 || true

# Where Slack actually gets configured: gateway setup, not env vars and not
# `hermes slack`. Its writes land in config.yaml / .env, both of which are
# mounted READ-ONLY for backoffice — see the note in agents/backoffice/config.yaml.
run hermes gateway setup --help
# `hermes tools --summary` refuses without a TTY, and discover pipes a script
# into ssh — so no interactive hermes command can ever run from here. Use the
# `list` subcommand, and run the interactive UI by hand on the VPS.
run hermes tools list
run hermes memory --help

# Is "channels" a real key, or does config get say that about anything?
run hermes config get channels.slack -p backoffice
run hermes config get zzz_control_probe -p backoffice

# The effective config — this is the schema. Skim before pasting: config.yaml
# holds settings not secrets, but check nothing sensitive rode along.
run hermes config -p backoffice

run hermes gateway status -p backoffice
REMOTE
}

cmd_check() {
  local failed=0
  heading "Local token check — agents/backoffice/.env"

  if [ ! -f "$agent_env" ]; then
    fail "agents/backoffice/.env is missing"
    note "cp agents/backoffice/.env.example agents/backoffice/.env"
    note "The stack will not start without it (create_host_path: false)."
    exit 1
  fi
  ok "agents/backoffice/.env exists"

  local bot app secret
  bot=$(val SLACK_BOT_TOKEN)
  app=$(val SLACK_APP_TOKEN)
  secret=$(val SLACK_SIGNING_SECRET)

  case "$bot" in
    xoxb-*) ok "SLACK_BOT_TOKEN present (xoxb-)" ;;
    "")     fail "SLACK_BOT_TOKEN is unset"; failed=1 ;;
    *)      fail "SLACK_BOT_TOKEN must start with xoxb- (Install App → Bot User OAuth Token). xoxp- is a user token, xapp- is the app-level one."; failed=1 ;;
  esac
  case "$app" in
    xapp-*) ok "SLACK_APP_TOKEN present (xapp-)" ;;
    "")     fail "SLACK_APP_TOKEN is unset — generate it when you enable Socket Mode"; failed=1 ;;
    *)      fail "SLACK_APP_TOKEN does not start with xapp-"; failed=1 ;;
  esac
  if [ -n "$secret" ]; then
    ok "SLACK_SIGNING_SECRET present"
  else
    fail "SLACK_SIGNING_SECRET is unset (Basic Information → App Credentials)"
    failed=1
  fi

  [ "$failed" -eq 0 ] || { note ""; note "Fix the above, then re-run."; exit 1; }

  heading "Live check against Slack"

  local resp
  resp=$(slack_call auth.test "$bot")
  if slack_ok "$resp"; then
    ok "bot token is live"
    note "workspace : $(jget team "$resp")"
    note "bot user  : $(jget user "$resp") ($(jget user_id "$resp"))"
  else
    fail "auth.test rejected the bot token: $(slack_err "$resp")"
    failed=1
  fi

  # This is the only call that proves Socket Mode is actually switched on in
  # the app config. It returns a single-use WebSocket URL and opens nothing.
  resp=$(slack_call apps.connections.open "$app")
  if slack_ok "$resp"; then
    ok "app token is live and Socket Mode is enabled"
  else
    fail "apps.connections.open rejected the app token: $(slack_err "$resp")"
    note "'not_allowed_token_type' usually means Socket Mode is off in the app settings."
    failed=1
  fi

  [ "$failed" -eq 0 ] || exit 1
  heading "Ready to deploy"
  note "./scripts/deploy.sh   then   ./scripts/slack-preflight.sh verify"
}

cmd_verify() {
  load_deploy_env
  heading "Post-deploy verification"

  remote <<'REMOTE'
cd "$1"

# If the read-only config.yaml had an unknown or malformed key, this is where
# it shows: the block either comes back or it does not.
printf '\n----- config get channels -p backoffice -----\n'
docker exec hermes hermes config get channels -p backoffice 2>&1 || true

printf '\n----- gateway status -p backoffice -----\n'
docker exec hermes hermes gateway status -p backoffice 2>&1 || true

printf '\n----- slack / socket lines in the gateway log -----\n'
docker compose logs --tail 400 --no-log-prefix hermes 2>&1 \
  | grep -i -E 'slack|socket|websocket' || echo '(no slack lines — the channel is not connected)'

printf '\n----- pairing list (who may talk to the agent) -----\n'
docker exec hermes hermes pairing list 2>&1 || true
REMOTE

  heading "Then test the controls by hand, in the pilot channel"
  note "1. post WITHOUT an @-mention   -> the agent must stay silent"
  note "2. @-mention it                -> it replies, in-thread"
  note "3. @-mention from a non-allowlisted account -> no reply"
  note "A misparsed config fails OPEN (it answers everyone), so 1 and 3 are the real tests."
}

case "${1:-check}" in
  discover) cmd_discover ;;
  check)    cmd_check ;;
  verify)   cmd_verify ;;
  *)        echo "usage: $0 [discover|check|verify]" >&2; exit 2 ;;
esac
