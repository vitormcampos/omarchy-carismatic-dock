#!/usr/bin/env bash
# Persist the dock's mixed app/folder order without passing folder paths to
# omarchy-dock, whose pinned list contains desktop IDs only.
set -euo pipefail

source omarchy-shell-config

case "${1:-}" in
  icon)
    (( $# == 2 )) || fail "icon expects one folder path"
    python3 - "$2" <<'PY'
import os
import subprocess
import sys
from urllib.parse import unquote_to_bytes, urlsplit

result = subprocess.run(
    ["gio", "info", "-a", "standard::icon,metadata::custom-icon,metadata::custom-icon-name", sys.argv[1]],
    capture_output=True, text=True,
)
if result.returncode:
    sys.exit(0)
attrs = {}
for line in result.stdout.splitlines():
    key, sep, value = line.strip().partition(": ")
    if sep:
        attrs[key] = value.strip()

custom = attrs.get("metadata::custom-icon", "")
if custom:
    url = urlsplit(custom)
    if url.scheme == "file" and url.netloc in ("", "localhost"):
        if os.path.isfile(os.fsdecode(unquote_to_bytes(url.path))):
            print(custom)
            sys.exit(0)
    elif os.path.isabs(custom) and os.path.isfile(custom):
        print(custom)
        sys.exit(0)

name = attrs.get("metadata::custom-icon-name", "")
if name:
    print(name)
    sys.exit(0)

name = attrs.get("standard::icon", "").split(",", 1)[0].strip()
if name not in ("", "folder", "folder-symbolic", "inode-directory", "inode-directory-symbolic"):
    print(name)
PY
    ;;
  add-url)
    (( $# == 2 )) || fail "add-url expects one local file URL"
    folder=$(python3 - "$2" <<'PY'
import json
import os
import sys
from urllib.parse import unquote_to_bytes, urlsplit

url = urlsplit(sys.argv[1])
if url.scheme != "file" or url.netloc not in ("", "localhost") or url.query or url.fragment:
    sys.exit(1)
path = os.path.normpath(os.fsdecode(unquote_to_bytes(url.path)))
if not os.path.isabs(path) or not os.path.isdir(path):
    sys.exit(1)
print(json.dumps({"path": path, "name": os.path.basename(path) or "/"}))
PY
    ) || { notify-send 'Carismatic Dock' 'Only local folders can be added'; fail "not a local folder"; }
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
  *) fail "usage: folders.sh icon <folder-path> | add-url <file-url> | order <order-json> <pinned-json> | remove <absolute-path>" ;;
esac
