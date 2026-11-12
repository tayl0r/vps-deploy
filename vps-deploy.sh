#!/usr/bin/env bash
# The deploy job's client (.github/workflows/deploy.yml): asks the VPS deploy gate to redeploy one of this
# app's deployments. It sends one line, "deploy <target> [<compose sha256>]", and the registry token and actor
# on stdin, never in argv. The server decides everything else. Inputs arrive as VPS_* environment variables.
set -euo pipefail

for v in VPS_DEPLOY_KEY VPS_DEPLOY_USER VPS_HOST VPS_TARGET VPS_TOKEN VPS_ACTOR; do
  if [ -z "${!v:-}" ]; then echo "::error title=VPS deploy::$v is empty"; exit 1; fi
done
target_re='^[a-z0-9-]{1,64}$'   # the gate's own form
if ! [[ $VPS_TARGET =~ $target_re ]]; then echo "::error title=VPS deploy::target must be <app> or <app>-dev"; exit 1; fi
if [ ! -s "$VPS_KNOWN_HOSTS" ]; then echo "::error title=VPS deploy::no pinned host keys at $VPS_KNOWN_HOSTS"; exit 1; fi

cmd="deploy $VPS_TARGET"
if [ -n "${VPS_COMPOSE:-}" ]; then
  if [ ! -f "$VPS_COMPOSE" ]; then echo "::error title=VPS deploy::no compose file at $VPS_COMPOSE"; exit 1; fi
  cmd+=" $(sha256sum -- "$VPS_COMPOSE" | cut -d' ' -f1)"
fi

# RUNNER_TEMP is emptied after every job, so even a killed job leaves no key behind.
dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/vps-deploy.XXXXXX")
trap 'rm -rf "$dir"' EXIT
keyfile=$dir/key
# GitHub stores a secret without its trailing newline, and OpenSSH won't load a key file missing it.
(umask 077 && printf '%s\n' "$VPS_DEPLOY_KEY" >"$keyfile")
unset VPS_DEPLOY_KEY

rc=0
printf '%s\n%s\n' "$VPS_TOKEN" "$VPS_ACTOR" | ssh -F /dev/null -T -i "$keyfile" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$VPS_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
  -o HostKeyAlias=vps -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
  -- "$VPS_DEPLOY_USER@$VPS_HOST" "$cmd" || rc=$?

case $rc in
  0) exit 0 ;;
  2) why="the deploy gate refused this command" ;;
  3) why="compose drift: install the repo's compose on the server (see the message above)" ;;
  75) why="another deploy of this deployment ran past 10 minutes" ;;
  255) why="ssh failed: connection, host key or deploy key. If the gate's 'deploying' line is above, the deploy may still finish on the server: check its log there before re-running" ;;
  *) why="the deploy didn't happen or failed on the server: the gate's message above says why" ;;
esac
echo "::error title=VPS deploy::$why"
exit "$rc"
