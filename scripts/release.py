#!/usr/bin/env python3
"""Prepare, stage, verify and publish zig-routing releases."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import struct
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = {
    "linux-x86_64-baseline": ("x86_64-linux-gnu", "baseline", "Linux", "x86_64"),
    "linux-x86_64-v3": ("x86_64-linux-gnu", "x86_64_v3", "Linux", "x86_64"),
    "linux-aarch64": ("aarch64-linux-gnu", "baseline", "Linux", "aarch64"),
    "macos-aarch64": ("aarch64-macos", "baseline", "Darwin", "arm64"),
}
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
SHA = re.compile(r"[0-9a-f]{40}")


def run(*args, cwd=ROOT, capture=False):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=capture).stdout


def output(*args):
    return run(*args, capture=True).strip()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def field(text, name):
    values = re.findall(rf'^\s*\.{name}\s*=\s*"([^"]+)",\s*$', text, re.MULTILINE)
    require(len(values) == 1, f"Expected one .{name} in build.zig.zon")
    return values[0]


def metadata():
    zon = (ROOT / "build.zig.zon").read_text()
    package = json.loads((ROOT / "package.json").read_text())
    version = field(zon, "version")
    require(VERSION.fullmatch(version), "Expected a stable semantic version")
    require(package["version"] == version, "Package versions disagree")
    pins = re.findall(r"^\s+zig:\s+(\S+)\s*$", (ROOT / "deps.yaml").read_text(), re.MULTILINE)
    require(len(pins) == 1, "Expected one Zig pin in deps.yaml")
    pin = pins[0]
    require(package["engines"]["zig"] == pin and field(zon, "minimum_zig_version") == pin.split("+")[0],
            "Zig pins disagree")
    commit = output("git", "rev-parse", "HEAD")
    require(SHA.fullmatch(commit), "Expected a full Git commit SHA")
    return version, pin, commit


def clean_source():
    require(not output("git", "status", "--porcelain"), "Stage releases from a clean checkout")


def tag_for(version, supplied):
    tag = f"v{version}"
    require(supplied is None or supplied == tag, f"Tag must match the package version ({tag})")
    return tag


def prepare(args):
    clean_source()
    previous, _, commit = metadata()
    current_zon = (ROOT / "build.zig.zon").read_text()
    bump = str(Path(args.bump).resolve()) if "/" in args.bump else args.bump
    with tempfile.TemporaryDirectory(prefix="zr-bump-") as workspace:
        path = Path(workspace) / "build.zig.zon"
        path.write_text(current_zon)
        run(bump, args.change, "--no-commit", "--no-tag", "--no-push", "--yes", cwd=workspace)
        updated_zon = path.read_text()
    version = field(updated_zon, "version")
    require(VERSION.fullmatch(version) and version != previous, "zig-bump did not advance the version")
    require(version != "1.0.0" or args.approve_1_0, "Preparing 1.0.0 requires explicit maintainer approval")

    refs = output("git", "tag", "--merged", commit, "--sort=-version:refname", "--list", "v*")
    prior = next((tag for tag in refs.splitlines() if VERSION.fullmatch(tag[1:])), None)
    command = [args.changelog, "--to", commit, "--hide-author-email", "--no-dates"]
    if prior:
        command.extend(["--from", prior])
    with tempfile.TemporaryDirectory(prefix="zr-changelog-") as workspace:
        path = Path(workspace) / "CHANGELOG.md"
        run(*command, "--output", str(path))
        notes = path.read_text().removeprefix("# Changelog").lstrip()
    notes = notes.removeprefix(f"## [{commit}]").strip()
    require(notes, "zig-changelog returned an empty changelog")
    entry = f"## [{version}]\n\n{notes}\n"
    print(f"Prepared release v{version} from {commit}")
    if args.dry_run:
        print(entry)
        return
    package_path = ROOT / "package.json"
    package = json.loads(package_path.read_text())
    package["version"] = version
    log_path = ROOT / "CHANGELOG.md"
    old = log_path.read_text().removeprefix("# Changelog").lstrip()
    (ROOT / "build.zig.zon").write_text(updated_zon)
    package_path.write_text(json.dumps(package, indent=2) + "\n")
    log_path.write_text("# Changelog\n\n" + entry + "\n" + old)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def names(tag, key):
    stem = f"zr-{tag}-{key}"
    archive = f"{stem}.tar.gz"
    return archive, f"{archive}.sha256", f"{stem}.provenance.json"


def binary_header(data, key):
    _, _, system, machine = PLATFORMS[key]
    if system == "Linux":
        arch = 62 if machine == "x86_64" else 183
        valid = (len(data) >= 64 and data.startswith(b"\x7fELF\x02\x01")
                 and struct.unpack_from("<H", data, 18)[0] == arch)
    else:
        valid = (len(data) >= 32 and data.startswith(b"\xcf\xfa\xed\xfe")
                 and struct.unpack_from("<I", data, 4)[0] == 0x0100000C
                 and struct.unpack_from("<I", data, 12)[0] == 2)
    require(valid, f"{key} archive has the wrong binary format or architecture")


def version_smoke(binary, version, commit):
    version_text = output(str(binary), "--version").splitlines()
    require(f"zr {version}" in version_text and f"commit {commit}" in version_text,
            f"{binary.name} --version did not report the release version and commit")
    version_json = json.loads(output(str(binary), "version", "--json"))
    require((version_json["version"], version_json["commit"]) == (version, commit),
            f"{binary.name} JSON version metadata disagrees with the release")
    status = json.loads(output(str(binary), "route", "--action", "status", "{}"))
    require(status["version"] == version and "status" in status["available_actions"],
            f"{binary.name} /status did not report the release version")


def write_archive(path, binary):
    with path.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data, mode in (
                ("zr", binary, 0o755),
                ("LICENSE", (ROOT / "LICENSE").read_bytes(), 0o644),
                ("NOTICE", (ROOT / "NOTICE").read_bytes(), 0o644),
            ):
                header = tarfile.TarInfo(name)
                header.size = len(data)
                header.mode = mode
                archive.addfile(header, io.BytesIO(data))


def build(args):
    clean_source()
    version, pin, commit = metadata()
    tag = tag_for(version, args.tag)
    zig = os.environ.get("ZIG", "zig")
    require(output(zig, "version") == pin, f"Release builds require Zig {pin}")
    destination = args.output.resolve()
    require(not destination.exists(), f"Output already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    keys = [args.platform] if args.platform else PLATFORMS
    with tempfile.TemporaryDirectory(prefix=".zr-release-", dir=destination.parent) as workspace:
        stage = Path(workspace) / "artifacts"
        stage.mkdir()
        for key in keys:
            target, cpu, system, machine = PLATFORMS[key]
            prefix = Path(workspace) / key
            options = [f"-Dtarget={target}", f"-Dcpu={cpu}", "-Doptimize=ReleaseFast", f"-Dcommit={commit}",
                       "--prefix", str(prefix), f"-j{args.jobs}"]
            if args.cache_dir is not None:
                options.extend(["--cache-dir", str(args.cache_dir.resolve())])
            run(zig, "build", *options)
            binary = prefix / "bin" / "zr"
            binary_bytes = binary.read_bytes()
            binary_header(binary_bytes, key)
            native = (platform.system(), platform.machine()) == (system, machine)
            require(native or not args.require_native, f"{key} needs a native runner for its version smoke test")
            if native:
                version_smoke(binary, version, commit)
            archive, checksum, provenance = names(tag, key)
            write_archive(stage / archive, binary_bytes)
            sha = digest((stage / archive).read_bytes())
            (stage / checksum).write_text(f"{sha}  {archive}\n")
            (stage / provenance).write_text(json.dumps({
                "archive": archive,
                "archive_sha256": sha,
                "binary_sha256": digest(binary_bytes),
                "commit": commit,
                "cpu": cpu,
                "native_version_check": native,
                "optimize": "ReleaseFast",
                "platform": key,
                "tag": tag,
                "target": target,
                "toolchain": pin,
                "version": version,
            }, indent=2, sort_keys=True) + "\n")
        verify(stage, tag, keys, args.require_native)
        stage.rename(destination)
    print(f"Staged {len(keys)} release binaries in {destination}")


def verify(directory, tag, keys=PLATFORMS, require_native=False):
    version, pin, commit = metadata()
    tag = tag_for(version, tag)
    selected = []
    for key in keys:
        target, cpu, _, _ = PLATFORMS[key]
        archive, checksum, provenance = names(tag, key)
        path = directory / archive
        sha = digest(path.read_bytes())
        require((directory / checksum).read_text() == f"{sha}  {archive}\n", f"{archive} checksum failed")
        with tarfile.open(path, "r:gz") as member_file:
            require(member_file.getnames() == ["zr", "LICENSE", "NOTICE"], f"{archive} has unexpected entries")
            member = member_file.getmember("zr")
            require(member.isfile() and member.mode == 0o755, f"{archive} does not contain executable zr")
            binary = member_file.extractfile(member).read()
        binary_header(binary, key)
        require(commit.encode() in binary, f"{archive} is missing the embedded commit")
        record = json.loads((directory / provenance).read_text())
        require(type(record["native_version_check"]) is bool, f"{archive} has invalid native-check metadata")
        require(not require_native or record["native_version_check"] is True,
                f"{archive} has no native version verification")
        require(record == {
            "archive": archive, "archive_sha256": sha, "binary_sha256": digest(binary),
            "commit": commit, "cpu": cpu, "native_version_check": record["native_version_check"],
            "optimize": "ReleaseFast", "platform": key, "tag": tag,
            "target": target, "toolchain": pin, "version": version,
        }, f"{archive} provenance disagrees with the release")
        selected.extend(directory / name for name in (archive, checksum, provenance))
    return selected


def gate(args):
    version, _, commit = metadata()
    tag = tag_for(version, args.tag)
    require(output("git", "rev-parse", f"refs/tags/{tag}^{{commit}}") == commit,
            "Release tag must point at the checked-out commit")
    run("git", "merge-base", "--is-ancestor", commit, "origin/main")
    if version == "1.0.0":
        require(args.approve_1_0 and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
                "Publishing 1.0.0 requires an explicit maintainer dispatch")
        actor = os.environ.get("GITHUB_ACTOR")
        require(actor, "The 1.0.0 approval must identify the dispatch actor")
        role = output("gh", "api", f"repos/{args.repo}/collaborators/{actor}/permission", "--jq", ".role_name")
        require(role in ("admin", "maintain"), "The 1.0.0 dispatch actor must be a maintainer or admin")
    runs = json.loads(output("gh", "run", "list", "--repo", args.repo, "--workflow", "ci.yml",
                             "--branch", "main", "--event", "push", "--commit", commit, "--limit", "1",
                             "--json", "databaseId,headSha,status,conclusion"))
    require(runs and runs[0]["headSha"] == commit and runs[0]["status"] == "completed"
            and runs[0]["conclusion"] == "success", "The tagged commit needs a successful main CI run")
    jobs = json.loads(output("gh", "run", "view", str(runs[0]["databaseId"]), "--repo", args.repo, "--json", "jobs"))["jobs"]
    size = any(job["name"] == "Binary size and instantiations" and job["conclusion"] == "success" for job in jobs)
    perf = any(job["name"] == "Test (ubuntu-latest)" and any(
        step["name"] == "Validate assembled fixture bundles" and step["conclusion"] == "success"
        for step in job["steps"]) for job in jobs)
    require(size and perf, "The release needs passing binary size and regional performance checks")
    blockers = json.loads(output("gh", "issue", "list", "--repo", args.repo, "--state", "open",
                                 "--label", "type:gate", "--limit", "1", "--json", "number"))
    require(not blockers, f"Open full-engine release gate #{blockers[0]['number']}" if blockers else "")


def release_notes(version):
    log = (ROOT / "CHANGELOG.md").read_text()
    start = re.search(rf"^## \[{re.escape(version)}\]\s*$", log, re.MULTILINE)
    require(start, f"Missing CHANGELOG.md entry for {version}")
    content = log[start.end():]
    end = re.search(r"^## \[\d+\.\d+\.\d+\]\s*$", content, re.MULTILINE)
    return content[:end.start() if end else None].strip()


def publish(args):
    gate(args)
    version, _, _ = metadata()
    assets = verify(args.output.resolve(), args.tag, require_native=True)
    notes = release_notes(version)
    require(notes, f"Empty CHANGELOG.md entry for {version}")
    view = subprocess.run(("gh", "release", "view", args.tag, "--repo", args.repo, "--json", "isDraft,assets"),
                          cwd=ROOT, text=True, capture_output=True)
    if view.returncode:
        require("release not found" in view.stderr.lower(), view.stderr.strip())
        with tempfile.TemporaryDirectory(prefix="zr-notes-") as temp:
            path = Path(temp) / "notes.md"
            path.write_text(notes + "\n")
            run("gh", "release", "create", args.tag, "--repo", args.repo, "--verify-tag", "--draft",
                "--title", f"zig-routing {args.tag}", "--notes-file", str(path), *map(str, assets))
    else:
        release = json.loads(view.stdout)
        existing = {item["name"]: item.get("digest") for item in release["assets"]}
        missing = []
        for asset in assets:
            if asset.name in existing:
                require(existing[asset.name] == "sha256:" + digest(asset.read_bytes()),
                        f"Existing release asset differs: {asset.name}")
            else:
                missing.append(str(asset))
        if not release["isDraft"]:
            require(not missing, "Published release is missing expected assets")
            run("pantry", "publish", ".", "--verify-existing", "--ignore-scripts")
            print(f"{args.tag} is already published with these assets")
            return
        if missing:
            run("gh", "release", "upload", args.tag, "--repo", args.repo, *missing)
    run("pantry", "publish", ".", "--verify-existing", "--ignore-scripts")
    run("gh", "release", "edit", args.tag, "--repo", args.repo, "--draft=false")


def cli():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare", help="Bump manifests with zig-bump and generate release notes")
    prep.add_argument("change", choices=("patch", "minor", "major"))
    prep.add_argument("--bump", default="bump")
    prep.add_argument("--changelog", default="changelog")
    prep.add_argument("--dry-run", action="store_true")
    prep.add_argument("--approve-1.0", dest="approve_1_0", action="store_true")
    stage = commands.add_parser("build", help="Stage local binaries and checksums")
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--tag")
    stage.add_argument("--platform", choices=PLATFORMS)
    stage.add_argument("--cache-dir", type=Path)
    stage.add_argument("--jobs", type=int, default=1)
    stage.add_argument("--require-native", action="store_true")
    check = commands.add_parser("verify", help="Verify all four release archives")
    check.add_argument("--output", type=Path, required=True)
    check.add_argument("--tag")
    check.add_argument("--require-native", action="store_true")
    commands.add_parser("tag", help="Print the version tag after checking the manifests")
    for name in ("gate", "publish"):
        command = commands.add_parser(name)
        command.add_argument("--repo", default="zig-utils/zig-routing")
        command.add_argument("--tag", required=True)
        command.add_argument("--approve-1.0", dest="approve_1_0", action="store_true")
        if name == "publish":
            command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "verify":
        verify(args.output, args.tag, require_native=args.require_native)
    elif args.command == "tag":
        print(tag_for(metadata()[0], None))
    else:
        globals()[args.command](args)


if __name__ == "__main__":
    cli()
