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


@dataclass
class WorldMapPointSample:
    timestamp: str
    uptime_seconds: float
    position: tuple[float, float, float]


@dataclass
class SemanticMeshGroupSample:
    semantic_class: str
    vertices: list[tuple[float, float, float]]


@dataclass
class SemanticMeshEvent:
    timestamp: str
    uptime_seconds: float
    event_type: str
    chunk_id: str
    groups: list[SemanticMeshGroupSample]


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


def read_export(
    input_path: Path,
) -> tuple[list[WorldPoseSample], list[WorldMapPointSample], list[SemanticMeshEvent], list[dict[str, Any]], str]:
    input_path = input_path.expanduser().resolve()

    if input_path.is_dir():
        session_name = input_path.name
        pose_csv = input_path.joinpath("world_pose.csv").read_text(encoding="utf-8")
        map_points_csv = read_optional_file(input_path.joinpath("world_map_points.csv"))
        semantic_mesh_jsonl = read_optional_file(input_path.joinpath("world_semantic_mesh.jsonl"))
        event_jsonl = input_path.joinpath("world_events.jsonl").read_text(encoding="utf-8")
    else:
        payload = json.loads(input_path.read_text(encoding="utf-8"))
        session_name = payload.get("session_directory", input_path.stem)
        files = {entry["name"]: entry["content"] for entry in payload.get("files", [])}
        pose_csv = files["world_pose.csv"]
        map_points_csv = files.get("world_map_points.csv", "")
        semantic_mesh_jsonl = files.get("world_semantic_mesh.jsonl", "")
        event_jsonl = files.get("world_events.jsonl", "")

    poses = parse_pose_csv(pose_csv)
    map_points = parse_map_points_csv(map_points_csv)
    semantic_mesh_events = parse_semantic_mesh_jsonl(semantic_mesh_jsonl)
    events = parse_jsonl(event_jsonl)
    return poses, map_points, semantic_mesh_events, events, session_name


def read_optional_file(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


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


def parse_map_points_csv(content: str) -> list[WorldMapPointSample]:
    if not content.strip():
        return []

    reader = csv.DictReader(io.StringIO(content))
    samples: list[WorldMapPointSample] = []

    for row in reader:
        samples.append(
            WorldMapPointSample(
                timestamp=row["timestamp"],
                uptime_seconds=float(row["uptime_seconds"]),
                position=(float(row["x"]), float(row["y"]), float(row["z"])),
            )
        )

    return samples


def parse_semantic_mesh_jsonl(content: str) -> list[SemanticMeshEvent]:
    if not content.strip():
        return []

    rows = parse_jsonl(content)
    events: list[SemanticMeshEvent] = []

    for row in rows:
        groups: list[SemanticMeshGroupSample] = []
        for group in row.get("groups", []):
            vertices = [
                (float(vertex[0]), float(vertex[1]), float(vertex[2]))
                for vertex in group.get("vertices", [])
                if len(vertex) == 3
            ]
            groups.append(
                SemanticMeshGroupSample(
                    semantic_class=str(group.get("semantic_class", "none")),
                    vertices=vertices,
                )
            )

        events.append(
            SemanticMeshEvent(
                timestamp=str(row["timestamp"]),
                uptime_seconds=float(row["uptime_seconds"]),
                event_type=str(row["type"]),
                chunk_id=str(row["chunk_id"]),
                groups=groups,
            )
        )

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


def semantic_color_rgb(semantic_class: str) -> list[int]:
    return {
        "floor": [52, 199, 89],
        "wall": [10, 132, 255],
        "ceiling": [255, 149, 0],
        "table": [175, 82, 222],
        "seat": [255, 45, 85],
        "window": [90, 200, 250],
        "door": [162, 132, 94],
        "none": [142, 142, 147],
    }.get(semantic_class, [142, 142, 147])


def log_map_points(map_points: list[WorldMapPointSample]) -> None:
    cumulative_points: list[tuple[float, float, float]] = []

    for sample in map_points:
        cumulative_points.append(sample.position)
        rr.set_time("uptime", duration=sample.uptime_seconds)
        rr.log(
            "world/map_points",
            rr.Points3D(cumulative_points, colors=[[200, 200, 200]], radii=[0.008]),
        )


def log_semantic_mesh_events(events: list[SemanticMeshEvent]) -> None:
    for event in events:
        rr.set_time("uptime", duration=event.uptime_seconds)
        chunk_path = f"world/semantic_mesh/{event.chunk_id}"

        if event.event_type == "remove_chunk":
            rr.log(chunk_path, rr.Clear(recursive=True))
            continue

        rr.log(chunk_path, rr.Clear(recursive=True))

        for group in event.groups:
            if not group.vertices:
                continue

            rr.log(
                f"{chunk_path}/{group.semantic_class}",
                rr.Points3D(
                    group.vertices,
                    colors=[semantic_color_rgb(group.semantic_class)],
                    radii=[0.004],
                ),
            )


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
    poses, map_points, semantic_mesh_events, events, session_name = read_export(args.input)

    rr.init(f"arkit_world_log_{session_name}", spawn=args.spawn)
    if args.save:
        rr.save(args.save)

    log_static_scene()
    log_events(events, poses[0].uptime_seconds)
    log_map_points(map_points)
    log_semantic_mesh_events(semantic_mesh_events)
    log_poses(poses)

    print(
        f"Loaded {len(poses)} pose samples, "
        f"{len(map_points)} map points, "
        f"{len(semantic_mesh_events)} semantic mesh events, "
        f"and {len(events)} events from {session_name}"
    )
    if args.save:
        print(f"Saved Rerun recording to {args.save}")


if __name__ == "__main__":
    main()
