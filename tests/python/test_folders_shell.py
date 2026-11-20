import json
import os
import subprocess
from pathlib import Path

import pytest


WRAPPER = Path(__file__).resolve().parents[2] / "src" / "folders.sh"


@pytest.fixture
def shell(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    home = tmp_path / "home"
    home.mkdir()
    config = home / "shell.json"
    config.write_text('{"dock":{"pinned":["A"],"folders":[],"order":[]}}')
    # Replace Omarchy's shared library, so no real config or reload is reached.
    (bin_dir / "omarchy-shell-config").write_text('''
CONFIG_FILE="$HOME/shell.json"
NORMALIZE='.'
fail() { echo "$*" >&2; exit 1; }
commit() {
  local program="$1"
  shift
  jq "$@" "$program" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || exit 1
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}
''')
    for name, script in {
        "notify-send": 'printf "%s\\n" "$@" >> "$HOME/notifications"',
        "gio": 'printf "%s\\n" "standard::icon: folder-development, folder"',
        "omarchy-shell": 'echo "unexpected reload" >&2; exit 99',
    }.items():
        path = bin_dir / name
        path.write_text("#!/bin/sh\n" + script + "\n")
        path.chmod(0o755)
    env = dict(os.environ, HOME=str(home), PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
    def run(*args):
        return subprocess.run(["bash", str(WRAPPER), *map(str, args)], cwd=tmp_path,
                              env=env, capture_output=True, text=True, timeout=10)
    return run, config, home


def test_add_order_remove_preserve_configuration(shell, tmp_path):
    run, config, home = shell
    folder = tmp_path / "ação ' $(echo literal)"
    folder.mkdir()
    for _ in range(2):
        result = run("add-url", folder.as_uri())
        assert result.returncode == 0, result.stderr
    dock = json.loads(config.read_text())["dock"]
    assert dock["folders"] == [{"path": str(folder), "name": folder.name}]
    assert dock["pinned"] == ["A"]
    order = ["A", "folder:" + str(folder)]
    assert run("order", json.dumps(order), '["A"]').returncode == 0
    assert json.loads(config.read_text())["dock"]["order"] == order
    assert run("remove", folder).returncode == 0
    dock = json.loads(config.read_text())["dock"]
    assert dock == {"folders": [], "order": ["A"], "pinned": ["A"]}
    assert not (home / "notifications").exists()


def test_icon_and_list_dispatch(shell, tmp_path):
    run, _, _ = shell
    assert run("icon", tmp_path).stdout == "folder-development\n"
    path = tmp_path / "stack"
    path.mkdir()
    (path / "file.txt").touch()
    result = run("list", path)
    assert result.returncode == 0
    assert json.loads(result.stdout) == [{"name": "file.txt", "path": str(path / "file.txt"), "dir": False}]


def test_move_success_and_collision_notification(shell, tmp_path):
    run, _, home = shell
    path = tmp_path / "source"
    path.mkdir()
    source = path / "file ' $(echo literal).txt"
    source.write_text("first")
    destination = tmp_path / "destination"
    destination.mkdir()
    assert run("move", source, destination).returncode == 0
    assert not source.exists()
    source.write_text("second")
    result = run("move", source, destination)
    assert result.returncode == 1
    assert source.read_text() == "second"
    assert (destination / source.name).read_text() == "first"
    assert "Already in that folder: " + source.name in (home / "notifications").read_text()


def test_invalid_url_notifies_without_changing_config(shell):
    run, config, home = shell
    before = config.read_bytes()
    assert run("add-url", "https://example.com").returncode == 1
    assert config.read_bytes() == before
    assert "Only local folders can be added" in (home / "notifications").read_text()


def test_always_visible_preserves_other_settings(shell):
    run, config, _ = shell
    original = json.loads(config.read_text())
    original["dock"]["autohide"] = True
    config.write_text(json.dumps(original))

    for setting, expected in [("on", True), ("off", False)]:
        result = run("always-visible", setting)
        assert result.returncode == 0, result.stderr
        actual = json.loads(config.read_text())
        assert actual["dock"].pop("alwaysVisible") is expected
        assert actual == original


@pytest.mark.parametrize("args", [[], ["list"], ["move", "/one"], ["order", "[]", '[1]'],
                                 ["always-visible"], ["always-visible", "true"]])
def test_invalid_arguments_do_not_change_config(shell, args):
    run, config, _ = shell
    before = config.read_bytes()
    assert run(*args).returncode == 1
    assert config.read_bytes() == before
