#!/usr/bin/env bash
# Run every numbered task script in order (00 runs at compose startup, 99 is teardown).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"

for script in /workspace/scripts/[0-9][0-9]-*.sh; do
  case "$(basename "$script")" in
    00-*|99-*) continue ;;
  esac
  printf '\n\033[1;35m########## %s ##########\033[0m\n' "$(basename "$script")"
  bash "$script"
done

printf '\n\033[1;32mAll scripts finished. Try from the host: curl http://localhost:%s/api/quote\033[0m\n' "$HTTP_PORT"
