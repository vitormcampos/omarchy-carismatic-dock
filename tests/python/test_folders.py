import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

import folders


@pytest.mark.parametrize("host", ["", "localhost"])
def test_folder_url_decodes_special_characters(tmp_path, host):
    path = tmp_path / "ação ' $(echo test) # %"
    path.mkdir()
    url = path.as_uri().replace("file://", "file://" + host, 1)
    assert folders.folder_from_url(url) == {"path": str(path), "name": path.name}


@pytest.mark.parametrize("url", [
    "https://example.com/folder", "smb://server/folder", "file://server/tmp",
    "file:relative", "file:///tmp?query", "file:///tmp#fragment", "",
])
def test_invalid_folder_urls(url):
    with pytest.raises(ValueError):
        folders.folder_from_url(url)


def test_folder_url_rejects_missing_paths_and_files(tmp_path):
    path = tmp_path / "file"
    path.write_text("content")
    for entry in [path, tmp_path / "missing"]:
        with pytest.raises(ValueError):
            folders.folder_from_url(entry.as_uri())
    assert folders.folder_from_url("file:///") == {"path": "/", "name": "/"}


def test_listing_sorts_directories_first_and_follows_links(tmp_path):
    (tmp_path / "Z folder").mkdir()
    (tmp_path / "link").symlink_to(tmp_path / "Z folder", target_is_directory=True)
    (tmp_path / "broken").symlink_to(tmp_path / "missing")
    for name in ["b", "A", "ação", ".hidden"]:
        (tmp_path / name).write_text("content")
    items = folders.list_folder(str(tmp_path))
    assert [item["name"] for item in items] == ["link", "Z folder", "A", "ação", "b", "broken"]
    assert [item["dir"] for item in items] == [True, True, False, False, False, False]
    assert all(item["path"] == str(tmp_path / item["name"]) for item in items)


def test_listing_limit_and_unavailable_directory(tmp_path):
    assert folders.list_folder(str(tmp_path)) == []
    for index in range(105):
        (tmp_path / f"{index:03}").touch()
    items = folders.list_folder(str(tmp_path))
    assert len(items) == 100
    assert items[-1]["name"] == "099"
    assert folders.list_folder(str(tmp_path / "missing")) is None
    assert folders.list_folder(str(tmp_path / "000")) is None


def test_listing_io_errors(monkeypatch):
    def fail(_):
        raise PermissionError("denied")
    monkeypatch.setattr(folders.os, "scandir", fail)
    assert folders.list_folder("/unreadable") is None


@pytest.mark.parametrize("attributes,expected", [
    ("metadata::custom-icon-name: custom\nstandard::icon: other", "custom"),
    ("standard::icon: folder-development, folder", "folder-development"),
    ("standard::icon: folder", ""),
    ("standard::icon: folder-symbolic", ""),
    ("standard::icon: inode-directory", ""),
    ("standard::icon: inode-directory-symbolic", ""),
    ("", ""),
    ("metadata::custom-icon: https://example.com/icon\nstandard::icon: fallback", "fallback"),
])
def test_icon_precedence_and_fallback(monkeypatch, attributes, expected):
    calls = []
    def run(args, **kwargs):
        calls.append((args, kwargs))
        return SimpleNamespace(returncode=0, stdout=attributes)
    monkeypatch.setattr(folders.subprocess, "run", run)
    assert folders.folder_icon("/folder with spaces") == expected
    assert calls[0][0][-1] == "/folder with spaces"
    assert calls[0][1] == {"capture_output": True, "text": True}


@pytest.mark.parametrize("as_url", [True, False])
def test_existing_custom_icon_has_priority(tmp_path, monkeypatch, as_url):
    path = tmp_path / "icon with spaces.svg"
    path.touch()
    custom = path.as_uri() if as_url else str(path)
    monkeypatch.setattr(folders.subprocess, "run", lambda *a, **kw: SimpleNamespace(
        returncode=0, stdout=f"metadata::custom-icon: {custom}\nmetadata::custom-icon-name: fallback"))
    assert folders.folder_icon(str(tmp_path)) == custom
    path.unlink()
    assert folders.folder_icon(str(tmp_path)) == "fallback"


def test_icon_gio_failure(monkeypatch):
    monkeypatch.setattr(folders.subprocess, "run", lambda *a, **kw: SimpleNamespace(returncode=1))
    assert folders.folder_icon("/missing") == ""


@pytest.fixture
def move_paths(tmp_path):
    source = tmp_path / "file ' ação.txt"
    source.write_bytes(b"original\x00content")
    destination = tmp_path / "destination"
    destination.mkdir()
    return source, destination, destination / source.name


def test_move_success(move_paths):
    source, destination, target = move_paths
    assert folders.move_file(str(source), str(destination)) == 0
    assert not source.exists()
    assert target.read_bytes() == b"original\x00content"


@pytest.mark.parametrize("collision", ["file", "directory", "broken-link"])
def test_move_existing_target_preserves_source(move_paths, collision):
    source, destination, target = move_paths
    if collision == "file":
        target.write_text("existing")
    elif collision == "directory":
        target.mkdir()
    else:
        target.symlink_to(destination / "missing")
    assert folders.move_file(str(source), str(destination)) == 4
    assert source.read_bytes() == b"original\x00content"
    if collision == "file":
        assert target.read_text() == "existing"
    elif collision == "directory":
        assert target.is_dir()
    else:
        assert target.is_symlink()


@pytest.mark.parametrize("source,folder,status", [
    ("relative", "/tmp", 1), ("/tmp/source", "relative", 1),
    ("/nonexistent-dock-test-source", "/tmp", 2),
])
def test_move_invalid_paths(source, folder, status):
    assert folders.move_file(source, folder) == status


def test_move_missing_destination_and_io_failure(move_paths, monkeypatch):
    source, destination, target = move_paths
    assert folders.move_file(str(source), str(destination / "missing")) == 3
    def fail(*args):
        raise OSError("copy failed")
    monkeypatch.setattr(folders.shutil, "move", fail)
    assert folders.move_file(str(source), str(destination)) == 5
    assert source.exists()
    assert not target.exists()


@pytest.mark.parametrize("operation", ["icon", "add-url", "list", "move"])
def test_cli_dispatch(operation, monkeypatch, capsys):
    monkeypatch.setattr(folders, "folder_icon", lambda path: "custom")
    monkeypatch.setattr(folders, "folder_from_url", lambda path: {"path": "/folder", "name": "folder"})
    monkeypatch.setattr(folders, "list_folder", lambda path: None)
    monkeypatch.setattr(folders, "move_file", lambda source, folder: 4)
    args = [operation, "/source"] + (["/destination"] if operation == "move" else [])
    assert folders.main(args) == (4 if operation == "move" else 0)
    output = capsys.readouterr().out
    assert output == {"icon": "custom\n", "add-url": '{"path": "/folder", "name": "folder"}\n',
                      "list": "null\n", "move": ""}[operation]


def test_cli_invalid_url_is_silent(capsys):
    assert folders.main(["add-url", "https://example.com"]) == 1
    assert capsys.readouterr().out == ""


def test_cli_process(tmp_path):
    helper = Path(folders.__file__).resolve()
    result = subprocess.run(["python3", str(helper), "list", str(tmp_path / "missing")],
                            capture_output=True, text=True, check=True)
    assert json.loads(result.stdout) is None
