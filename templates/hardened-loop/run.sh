#!/usr/bin/env bash
# run.sh: runs loop.sh in a container with the gate tests mounted read-only.
set -euo pipefail

docker run --rm --init \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e GIT_AUTHOR_NAME=loop.sh -e GIT_AUTHOR_EMAIL=loop@localhost \
  -e GIT_COMMITTER_NAME=loop.sh -e GIT_COMMITTER_EMAIL=loop@localhost \
  -e ANTHROPIC_API_KEY \
  -v "$PWD:/work" -w /work \
  -v "$PWD/../gate-tests:/gate/tests:ro" \
  "${LOOP_IMAGE:?set LOOP_IMAGE to an image with claude, git, jq and pytest}" \
  ./loop.sh
