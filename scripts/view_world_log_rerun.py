#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import io
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import rerun as rr


@dataclass
class WorldPoseSample:
    timestamp: str
    uptime_seconds: float
    position: tuple[float, float, float]
    roll_deg: float
    pitch_deg: float
    yaw_deg: float
    tracking_state: str
    mapping_state: str
    raw_feature_count: int
    map_feature_count: int
    semantic_chunk_count: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Visualize exported ARKit world-tracking logs with Rerun."
    )
    parser.add_argument(
        "input",
        type=Path,
        help="Path to an exported world-*.json package or a session directory containing world_pose.csv.",
    )
    parser.add_argument(
        "--save",
        type=Path,
        help="Optional .rrd output path. Useful in headless environments.",
    )
    parser.add_argument(
        "--spawn",
        action="store_true",
        help="Spawn the Rerun viewer immediately.",
    )
    return parser.parse_args()


def read_export(input_path: Path) -> tuple[list[WorldPoseSample], list[dict[str, Any]], str]:
    input_path = input_path.expanduser().resolve()

    if input_path.is_dir():
        session_name = input_path.name
        pose_csv = input_path.joinpath("world_pose.csv").read_text(encoding="utf-8")
        event_jsonl = input_path.joinpath("world_events.jsonl").read_text(encoding="utf-8")
    else:
        payload = json.loads(input_path.read_text(encoding="utf-8"))
        session_name = payload.get("session_directory", input_path.stem)
        files = {entry["name"]: entry["content"] for entry in payload.get("files", [])}
        pose_csv = files["world_pose.csv"]
        event_jsonl = files.get("world_events.jsonl", "")

    poses = parse_pose_csv(pose_csv)
    events = parse_jsonl(event_jsonl)
    return poses, events, session_name


def parse_pose_csv(content: str) -> list[WorldPoseSample]:
    reader = csv.DictReader(io.StringIO(content))
    samples: list[WorldPoseSample] = []

    for row in reader:
        samples.append(
            WorldPoseSample(
                timestamp=row["timestamp"],
                uptime_seconds=float(row["uptime_seconds"]),
                position=(float(row["x"]), float(row["y"]), float(row["z"])),
                roll_deg=float(row["roll_deg"]),
                pitch_deg=float(row["pitch_deg"]),
                yaw_deg=float(row["yaw_deg"]),
                tracking_state=row["tracking_state"],
                mapping_state=row["mapping_state"],
                raw_feature_count=int(row["raw_feature_count"]),
                map_feature_count=int(row["map_feature_count"]),
                semantic_chunk_count=int(row["semantic_chunk_count"]),
            )
        )

    if not samples:
        raise ValueError("No pose samples found in world_pose.csv")

    return samples


def parse_jsonl(content: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []

    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        events.append(json.loads(line))

    return events


def euler_degrees_to_xyzw(roll_deg: float, pitch_deg: float, yaw_deg: float) -> tuple[float, float, float, float]:
    roll = math.radians(roll_deg)
    pitch = math.radians(pitch_deg)
    yaw = math.radians(yaw_deg)

    cy = math.cos(yaw * 0.5)
    sy = math.sin(yaw * 0.5)
    cp = math.cos(pitch * 0.5)
    sp = math.sin(pitch * 0.5)
    cr = math.cos(roll * 0.5)
    sr = math.sin(roll * 0.5)

    w = cr * cp * cy + sr * sp * sy
    x = sr * cp * cy - cr * sp * sy
    y = cr * sp * cy + sr * cp * sy
    z = cr * cp * sy - sr * sp * cy
    return x, y, z, w


def log_static_scene() -> None:
    rr.log("world", rr.ViewCoordinates.RIGHT_HAND_Y_UP, static=True)
    rr.log(
        "plots/raw_feature_count",
        rr.SeriesLines(names="raw_feature_count", colors=[[90, 180, 255]], widths=[2]),
        static=True,
    )
    rr.log(
        "plots/map_feature_count",
        rr.SeriesLines(names="map_feature_count", colors=[[255, 180, 90]], widths=[2]),
        static=True,
    )
    rr.log(
        "plots/semantic_chunk_count",
        rr.SeriesLines(names="semantic_chunk_count", colors=[[120, 220, 120]], widths=[2]),
        static=True,
    )


def log_events(events: list[dict[str, Any]], first_uptime_seconds: float) -> None:
    for index, event in enumerate(events):
        rr.set_time("event", sequence=index)
        rr.set_time("uptime", duration=first_uptime_seconds + index * 0.001)
        message = json.dumps(event, sort_keys=True)
        rr.log("events/log", rr.TextLog(message))


def log_poses(poses: list[WorldPoseSample]) -> None:
    trajectory: list[tuple[float, float, float]] = []
    last_tracking_state: str | None = None
    last_mapping_state: str | None = None

    for frame_index, sample in enumerate(poses):
        trajectory.append(sample.position)

        rr.set_time("frame", sequence=frame_index)
        rr.set_time("uptime", duration=sample.uptime_seconds)

        rr.log(
            "world/device",
            rr.Transform3D(
                translation=sample.position,
                quaternion=rr.Quaternion(
                    xyzw=euler_degrees_to_xyzw(sample.roll_deg, sample.pitch_deg, sample.yaw_deg)
                ),
                axis_length=0.08,
            ),
        )
        rr.log(
            "world/trajectory",
            rr.LineStrips3D([trajectory], colors=[[255, 96, 96]], radii=[0.01]),
        )
        rr.log(
            "world/device/position",
            rr.Points3D([sample.position], colors=[[255, 255, 255]], radii=[0.03]),
        )

        rr.log("plots/raw_feature_count", rr.Scalars([sample.raw_feature_count]))
        rr.log("plots/map_feature_count", rr.Scalars([sample.map_feature_count]))
        rr.log("plots/semantic_chunk_count", rr.Scalars([sample.semantic_chunk_count]))

        if sample.tracking_state != last_tracking_state:
            rr.log("status/tracking", rr.TextLog(sample.tracking_state))
            last_tracking_state = sample.tracking_state

        if sample.mapping_state != last_mapping_state:
            rr.log("status/mapping", rr.TextLog(sample.mapping_state))
            last_mapping_state = sample.mapping_state


def main() -> None:
    args = parse_args()
    poses, events, session_name = read_export(args.input)

    rr.init(f"arkit_world_log_{session_name}", spawn=args.spawn)
    if args.save:
        rr.save(args.save)

    log_static_scene()
    log_events(events, poses[0].uptime_seconds)
    log_poses(poses)

    print(f"Loaded {len(poses)} pose samples and {len(events)} events from {session_name}")
    if args.save:
        print(f"Saved Rerun recording to {args.save}")


if __name__ == "__main__":
    main()
