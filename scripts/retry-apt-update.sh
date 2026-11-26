#!/usr/bin/env bash

# A mirror can briefly serve an index that does not match its release metadata.
# Refresh the full index again so APT can fetch and verify a consistent set.
retry_apt_update() {
  local attempt status
  for attempt in 1 2 3; do
    if apt-get update --error-on=any; then
      return 0
    else
      status=$?
    fi
    if (( attempt < 3 )); then
      printf 'apt-get update failed (attempt %d/3, exit %d), retrying in %ds\n' \
        "$attempt" "$status" "$((attempt * 10))" >&2
      sleep "$((attempt * 10))"
    fi
  done
  printf 'apt-get update failed after %d attempts (exit %d)\n' "$attempt" "$status" >&2
  return "$status"
}
