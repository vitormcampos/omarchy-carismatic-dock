"""Filesystem helpers for folders.sh, importable without running commands."""

import argparse
import json
import os
import shutil
import subprocess
from urllib.parse import unquote_to_bytes, urlsplit


def folder_icon(path):
    result = subprocess.run(
        ["gio", "info", "-a", "standard::icon,metadata::custom-icon,metadata::custom-icon-name", path],
        capture_output=True, text=True,
    )
    if result.returncode:
        return ""
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
                return custom
        elif os.path.isabs(custom) and os.path.isfile(custom):
            return custom

    name = attrs.get("metadata::custom-icon-name", "")
    if name:
        return name
    name = attrs.get("standard::icon", "").split(",", 1)[0].strip()
    return name if name not in ("", "folder", "folder-symbolic", "inode-directory", "inode-directory-symbolic") else ""


def folder_from_url(value):
    url = urlsplit(value)
    if url.scheme != "file" or url.netloc not in ("", "localhost") or url.query or url.fragment:
        raise ValueError("not a local folder")
    path = os.path.normpath(os.fsdecode(unquote_to_bytes(url.path)))
    if not os.path.isabs(path) or not os.path.isdir(path):
        raise ValueError("not a local folder")
    return {"path": path, "name": os.path.basename(path) or "/"}


def list_folder(path):
    try:
        with os.scandir(path) as entries:
            items = []
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                try:
                    is_dir = entry.is_dir(follow_symlinks=True)
                except OSError:
                    is_dir = False
                items.append({"name": entry.name, "path": entry.path, "dir": is_dir})
    except OSError:
        return None
    items.sort(key=lambda item: (not item["dir"], item["name"].casefold()))
    return items[:100]


def move_file(source, folder):
    """Return the exit status expected by the shell wrapper.

    This preserves the original check-then-move behavior. Atomic collision
    protection is a separate change tracked in spec 004.
    """
    if not os.path.isabs(source) or not os.path.isabs(folder):
        return 1
    if not os.path.exists(source):
        return 2
    if not os.path.isdir(folder):
        return 3
    target = os.path.join(folder, os.path.basename(source.rstrip("/")))
    if os.path.lexists(target):
        return 4
    try:
        shutil.move(source, folder)
    except OSError:
        return 5
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("icon", "add-url", "list"):
        commands.add_parser(command).add_argument("path")
    move = commands.add_parser("move")
    move.add_argument("source")
    move.add_argument("folder")
    args = parser.parse_args(argv)

    if args.command == "icon":
        icon = folder_icon(args.path)
        if icon:
            print(icon)
    elif args.command == "add-url":
        try:
            folder = folder_from_url(args.path)
        except ValueError:
            return 1
        print(json.dumps(folder))
    elif args.command == "list":
        print(json.dumps(list_folder(args.path), ensure_ascii=False))
    else:
        return move_file(args.source, args.folder)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
