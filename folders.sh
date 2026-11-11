#!/usr/bin/env bash
# Persist the dock's mixed app/folder order without passing folder paths to
# omarchy-dock, whose pinned list contains desktop IDs only.
set -euo pipefail

source omarchy-shell-config

case "${1:-}" in
  order)
    (( $# == 3 )) || fail "order expects JSON order and pinned lists"
    jq -en --argjson order "$2" --argjson pinned "$3" \
      '$order | type == "array" and all(.[]; type == "string")' >/dev/null \
      || fail "invalid order"
    jq -en --argjson pinned "$3" \
      '$pinned | type == "array" and all(.[]; type == "string")' >/dev/null \
      || fail "invalid pins"
    commit "$NORMALIZE | .dock.order = \$order | .dock.pinned = \$pinned" \
      --argjson order "$2" --argjson pinned "$3"
    ;;
  remove)
    (( $# == 2 )) || fail "remove expects one folder path"
    commit "$NORMALIZE | .dock.folders = ((.dock.folders // []) | map(select(
      (if type == \"object\" then (.path // \"\") else \"\" end | sub(\"/+$\"; \"\")) != (\$path | sub(\"/+$\"; \"\"))
    ))) | .dock.order = ((.dock.order // []) | map(select(. != (\"folder:\" + \$path))))" \
      --arg path "$2"
    ;;
  *) fail "usage: folders.sh order <order-json> <pinned-json> | remove <absolute-path>" ;;
esac
