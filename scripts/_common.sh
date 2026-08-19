# Shared setup for the scripts in this directory. Sourced, not executed.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

load_deploy_env() {
  local env_file="$repo_root/scripts/.env"
  if [ ! -f "$env_file" ]; then
    echo "scripts/.env not found. Run: cp scripts/.env.example scripts/.env" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$env_file"
  # Same philosophy as ${TAILSCALE_IP:?} in docker-compose.yml: stop with a
  # message naming the variable rather than proceeding against a wrong target.
  : "${HERMES_SSH:?set HERMES_SSH in scripts/.env (user@host)}"
  : "${HERMES_DIR:?set HERMES_DIR in scripts/.env (stack path on the VPS)}"
}

# Run a script on the VPS with $1 bound to the stack directory.
remote() {
  ssh "$HERMES_SSH" bash -s -- "$HERMES_DIR"
}

# Colour only on a terminal: "discover" output is meant to be piped and pasted.
if [ -t 1 ]; then
  _b=$'\033[1m'; _g=$'\033[32m'; _r=$'\033[31m'; _0=$'\033[0m'
else
  _b=''; _g=''; _r=''; _0=''
fi

heading() { printf '\n%s== %s ==%s\n' "$_b" "$*" "$_0"; }
ok()      { printf '  %sok%s    %s\n' "$_g" "$_0" "$*"; }
fail()    { printf '  %sFAIL%s  %s\n' "$_r" "$_0" "$*"; }
note()    { printf '        %s\n' "$*"; }
