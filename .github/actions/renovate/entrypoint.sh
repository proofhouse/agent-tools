#!/bin/bash
# Custom entrypoint for the self-hosted Renovate container. Renovate runs
# as root by default (docker-user: root in renovate.yaml) so it can adjust
# group membership, then drops to the `ubuntu` user before exec'ing.
#
# The post-update gomodTidy step needs to launch a Go sidecar, which
# requires write access to /var/run/docker.sock. The socket's GID inside
# the Renovate container doesn't match any pre-existing group; we discover
# the host GID and either reuse the matching group or create one, then
# add `ubuntu` to it.

set -euo pipefail

ls -lah /var/run/docker.sock

GROUP_ID=$(stat -c '%g' /var/run/docker.sock)
GROUP_NAME=$(getent group "$GROUP_ID" | cut -d: -f1 || true)

if [ -z "$GROUP_NAME" ]; then
  GROUP_NAME="docker_group"
  groupadd -g "$GROUP_ID" "$GROUP_NAME"
fi

usermod -aG "$GROUP_NAME" ubuntu

runuser -u ubuntu renovate
