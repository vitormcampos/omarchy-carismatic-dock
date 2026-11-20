#!/usr/bin/env bash
# Persist the dock's mixed app/folder order without passing folder paths to
# omarchy-dock, whose pinned list contains desktop IDs only.
set -euo pipefail

source omarchy-shell-config

helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/folders.py"

case "${1:-}" in
  always-visible)
    (( $# == 2 )) || fail "always-visible expects on or off"
    case "$2" in
      on) enabled=true ;;
      off) enabled=false ;;
      *) fail "always-visible expects on or off" ;;
    esac
    commit "$NORMALIZE | .dock.alwaysVisible = \$enabled" --argjson enabled "$enabled"
    ;;
  icon)
    (( $# == 2 )) || fail "icon expects one folder path"
    python3 "$helper" icon "$2"
    ;;
  add-url)
    (( $# == 2 )) || fail "add-url expects one local file URL"
    folder=$(python3 "$helper" add-url "$2") || { notify-send 'Carismatic Dock' 'Only local folders can be added'; fail "not a local folder"; }
    commit "$NORMALIZE | .dock.folders = ((.dock.folders // []) | if any(.[];
      (if type == \"object\" then (.path // \"\") else \"\" end | sub(\"/+$\"; \"\")) == (\$folder.path | sub(\"/+$\"; \"\"))
    ) then . else . + [\$folder] end)" --argjson folder "$folder"
    ;;
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
  list)
    (( $# == 2 )) || fail "list expects one folder path"
    python3 "$helper" list "$2"
    ;;
  move)
    (( $# == 3 )) || fail "move expects a source path and a folder path"
    status=0
    python3 "$helper" move "$2" "$3" || status=$?
    if (( status != 0 )); then
      if (( status == 4 )); then
        notify-send 'Carismatic Dock' "Already in that folder: $(basename "$2")"
      else
        notify-send 'Carismatic Dock' "Could not move $(basename "$2")"
      fi
      fail "move failed"
    fi
    ;;
  *) fail "usage: folders.sh always-visible <on|off> | icon <folder-path> | add-url <file-url> | order <order-json> <pinned-json> | remove <absolute-path> | list <absolute-path> | move <source-path> <folder-path>" ;;
esac
