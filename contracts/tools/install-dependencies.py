#!/usr/bin/env python3
"""Install hash-checked public contract dependencies without Git metadata."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(part in ("..", ".git") for part in path.parts):
        raise ValueError("Invalid dependency path")
    return path


def verify_files(directory, files):
    for entry in files:
        path = directory / relative_path(entry["path"])
        if path.is_symlink() or not path.is_file():
            raise ValueError("Missing or unsafe dependency file: " + entry["path"])
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Dependency file hash mismatch: " + entry["path"])


def install(root, dependency, archive_directory):
    revision = dependency["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Dependency must use an exact upstream commit")
    relative = relative_path(dependency["install_path"])
    if relative.parts[0] != "lib":
        raise ValueError("Dependencies must stay inside lib")
    target = root / relative
    if not target.resolve().is_relative_to(root):
        raise ValueError("Dependency destination escapes the contract directory")
    for parent in [target, *target.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError("Dependency destinations cannot contain symlinks")
    files = dependency["files"]
    if target.exists():
        verify_files(target, files)
        print("Verified " + dependency["name"] + " " + revision)
        return
    prefix = dependency["archive_prefix"]
    relative_path(prefix)
    url = dependency["archive_url"]
    if not re.fullmatch(r"https://codeload\.github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/tar\.gz/" + revision, url):
        raise ValueError("Invalid public upstream archive URL")
    filename = dependency["name"] + "-" + revision + ".tar.gz"
    with tempfile.TemporaryDirectory(prefix="metrion-contract-dependency-") as temporary:
        temporary = Path(temporary)
        archive_path = archive_directory / filename if archive_directory else temporary / filename
        if archive_directory:
            if not archive_path.is_file():
                raise ValueError("Pinned offline archive is missing: " + filename)
        else:
            subprocess.run([
                "curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
                "--retry", "2", "--max-time", "120", "--output", str(archive_path), url,
            ], check=True)
        staged = temporary / "source"
        staged.mkdir()
        with tarfile.open(archive_path, "r:gz") as archive:
            for entry in files:
                source_path = relative_path(entry["path"])
                member = archive.getmember(prefix + str(source_path))
                if not member.isfile():
                    raise ValueError("Dependency archive entry must be a regular file")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError("Cannot read dependency archive entry")
                data = stream.read()
                if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                    raise ValueError("Pinned upstream content mismatch: " + entry["path"])
                destination = staged / source_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        verify_files(staged, files)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise ValueError("Dependency destination changed during installation")
        shutil.copytree(staged, target)
        verify_files(target, files)
    print("Installed " + dependency["name"] + " " + revision)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-dir", type=Path, help="Use previously downloaded pinned archives without network access")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "DEPENDENCIES.json").read_text())
    for dependency in manifest["dependencies"]:
        install(root, dependency, args.archive_dir)
    print("All required dependency source and license hashes verified.")


if __name__ == "__main__":
    main()
