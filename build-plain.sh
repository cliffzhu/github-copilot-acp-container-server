#!/usr/bin/env sh
set -eu

# BuildKit's default TTY UI uses colors/progress rendering that can be hard to read
# in some terminals (for example dark PuTTY themes). Force plain, no-color output.
export BUILDKIT_PROGRESS=plain
export NO_COLOR=1
export TERM=dumb

exec docker compose build "$@"
