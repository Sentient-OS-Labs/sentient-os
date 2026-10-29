#!/usr/bin/env python3
"""Prepare pinned runtime artifacts locally; never install, upload, or edit the app manifest.

Use an official CLI package plus the complete helper from a read-only official installer.
The caller supplies the CLI SHA-256 from OpenAI's release metadata. Helper signatures are
verified before packaging and again after extraction with the app installer's tar tool.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

TARGET = "aarch64-apple-darwin"
HELPER_NAME = "Codex Computer Use.app"
CLIENT = "Contents/SharedSupport/SkyComputerUseClient.app"
REQUIREMENT = '=anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(root):
    files = []
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError("Runtime contains a link or special file: " + str(path))
        files.append(dict(path=path.relative_to(root).as_posix(), bytes=path.stat().st_size,
                          sha256=sha256(path), executable=bool(mode & 0o111)))
    if not files:
        raise ValueError("Empty runtime")
    return files


def verify_helper(app):
    for relative, identifier, executable in [
        (".", "com.openai.sky.CUAService", "SkyComputerUseService"),
        (CLIENT, "com.openai.sky.CUAService.cli", "SkyComputerUseClient"),
    ]:
        bundle = app / relative
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable:
            raise ValueError("Unexpected helper identity")
        binary = bundle / "Contents/MacOS" / executable
        if not binary.is_file() or not binary.stat().st_mode & 0o111:
            raise ValueError("Missing helper executable")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                        "--test-requirement=" + REQUIREMENT, str(bundle)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not re.fullmatch(r"\d+\.\d+\.\d+", info["CFBundleShortVersionString"]):
        raise ValueError("Unexpected helper version")
    return info


def artifact(path, version, files):
    return dict(version=version, filename=path.name, bytes=path.stat().st_size,
                sha256=sha256(path), files=files)


def prepare(cli_archive, expected_sha256, helper_app, output):
    if sha256(cli_archive) != expected_sha256:
        raise ValueError("CLI archive does not match official SHA-256")
    # A fresh output directory makes immutable names impossible to overwrite accidentally.
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="sentient-release-") as temporary:
        staging = Path(temporary)
        package = staging / "cli"
        package.mkdir()
        with tarfile.open(cli_archive, "r:gz") as archive:
            members = archive.getmembers()
            if not members or any(not (member.isfile() or member.isdir()) or
                                  Path(member.name).is_absolute() or ".." in Path(member.name).parts or
                                  "\\" in member.name for member in members):
                raise ValueError("Unsafe CLI package entries")
            names = [member.name for member in members]
            if len(names) != len(set(names)):
                raise ValueError("Duplicate CLI package entries")
            archive.extractall(package)
        metadata = json.loads((package / "codex-package.json").read_text())
        version = metadata["version"]
        if not re.fullmatch(r"\d+\.\d+\.\d+", version) or metadata.get("target") != TARGET or metadata.get("entrypoint") != "bin/codex":
            raise ValueError("Expected a stable Apple Silicon CLI package")
        reported = subprocess.check_output([str(package / "bin/codex"), "--version"], text=True).strip()
        if reported != "codex-cli " + version:
            raise ValueError("CLI executable and package version disagree")
        cli_files = inventory(package)
        cli_path = output / ("codex-package-" + version + "-" + TARGET + ".tar.gz")
        shutil.copyfile(cli_archive, cli_path)

        if helper_app.is_symlink() or helper_app.name != HELPER_NAME:
            raise ValueError("Expected the complete official helper bundle")
        info = verify_helper(helper_app)
        helper_files = inventory(helper_app)
        helper_version = info["CFBundleShortVersionString"]
        helper_path = output / ("computer-use-" + helper_version + "-arm64.zip")
        # Fixed timestamps and explicit modes omit extended attributes, owner information,
        # AppleDouble sidecars, and local paths while preserving every signed file byte.
        with zipfile.ZipFile(helper_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for record in helper_files:
                path = helper_app / record["path"]
                entry = zipfile.ZipInfo(HELPER_NAME + "/" + record["path"], (1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (stat.S_IFREG | stat.S_IMODE(path.stat().st_mode)) << 16
                archive.writestr(entry, path.read_bytes())
        unpacked = staging / "roundtrip"
        unpacked.mkdir()
        subprocess.run(["/usr/bin/tar", "-xf", str(helper_path), "-C", str(unpacked), "--no-same-owner"], check=True)
        verify_helper(unpacked / HELPER_NAME)
        if inventory(unpacked / HELPER_NAME) != helper_files:
            raise ValueError("Packaged helper did not round-trip exactly")
        release = dict(target=TARGET, helperBuild=int(info["CFBundleVersion"]),
                       cli=artifact(cli_path, version, cli_files),
                       helper=artifact(helper_path, helper_version, helper_files))
        (output / "BundledCodexRelease.json").write_text(json.dumps(release, indent=2) + "\n")
        print(json.dumps({key: {k: v for k, v in release[key].items() if k != "files"}
                          for key in ["cli", "helper"]}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli-archive", required=True, type=Path)
    parser.add_argument("--cli-sha256", required=True)
    parser.add_argument("--helper-app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.cli_archive.resolve(), args.cli_sha256, args.helper_app.absolute(), args.output.absolute())
