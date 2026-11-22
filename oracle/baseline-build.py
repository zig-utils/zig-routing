#!/usr/bin/env python3
"""Measure a pinned Valhalla tile build after fetching its inputs."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def disk_used(directory):
    fs = os.statvfs(directory)
    return (fs.f_blocks - fs.f_bfree) * fs.f_frsize


def tile_scratch(tiles):
    total = 0
    try:
        for item in tiles.iterdir():
            try:
                if item.is_file():
                    total += item.stat().st_size
            except FileNotFoundError:
                # Completed stages remove their intermediate files.
                pass
    except FileNotFoundError:
        pass
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("run on the native x86-64 Linux benchmark host")
    if not re.fullmatch(r"[a-z0-9-]+", args.dataset):
        parser.error("invalid dataset name")

    oracle = Path(__file__).resolve().parent
    data_root = Path(os.environ.get("ORACLE_DATA", oracle / "data")).resolve()
    data = data_root / args.dataset
    if not (data / "extract.osm.pbf").is_file():
        parser.error("fetch the dataset inputs before measuring its build")
    if args.output.exists():
        parser.error("use a new output file for each build")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.output.parent / f"{args.dataset}-build.log"
    tiles = data / "tiles"
    interval = 5
    initial_disk = peak_disk = disk_used(data)
    peak_scratch = 0
    started_at = datetime.now(timezone.utc).isoformat()
    start = time.monotonic()
    env = {**os.environ, "ORACLE_DATA": str(data_root), "ORACLE_PLATFORM": "linux/amd64"}
    with log_path.open("x") as log:
        with subprocess.Popen([oracle / "build.sh", args.dataset], env=env,
                              stdout=log, stderr=subprocess.STDOUT) as process:
            while process.poll() is None:
                peak_disk = max(peak_disk, disk_used(data))
                peak_scratch = max(peak_scratch, tile_scratch(tiles))
                try:
                    process.wait(timeout=interval)
                except subprocess.TimeoutExpired:
                    pass
            if process.returncode:
                raise SystemExit(f"tile build failed, see {log_path}")

    total_seconds = time.monotonic() - start
    seconds = re.findall(rf"oracle: built {re.escape(args.dataset)} in ([0-9]+)s", log_path.read_text())
    if len(seconds) != 1:
        raise SystemExit(f"missing build time, see {log_path}")
    peak_disk = max(peak_disk, disk_used(data))
    record = {
        "dataset": args.dataset,
        "started_at": started_at,
        "oracle_build_key": (data / "build.key").read_text().strip(),
        "build_seconds": int(seconds[0]),
        "total_seconds_including_input_check": round(total_seconds, 2),
        "sample_interval_seconds": interval,
        "peak_intermediate_tile_files_bytes": peak_scratch,
        "initial_filesystem_used_bytes": initial_disk,
        "peak_filesystem_used_bytes": peak_disk,
        "peak_added_disk_bytes": peak_disk - initial_disk,
        "tile_archive_bytes": (data / "tiles.tar").stat().st_size,
        "graph_tiles": sum(1 for _ in tiles.rglob("*.gph")),
    }
    with args.output.open("x") as output:
        json.dump(record, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
