#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import rerun as rr
import rerun.blueprint as rrb

STANDARD_GRAVITY = 9.80665


@dataclass
class LocationSample:
    timestamp: str
    east_m: float
    north_m: float
    up_m: float
    horizontal_accuracy_m: float
    vertical_accuracy_m: float
    speed_mps: float
    course_deg: float


@dataclass
class HeadingSample:
    timestamp: str
    magnetic_heading_deg: float
    true_heading_deg: float
    heading_accuracy_deg: float
    x: float
    y: float
    z: float


@dataclass
class DeviceMotionSample:
    timestamp: str
    roll_deg: float
    pitch_deg: float
    yaw_deg: float
    gravity_x: float
    gravity_y: float
    gravity_z: float
    user_accel_x: float
    user_accel_y: float
    user_accel_z: float
    rotation_x: float
    rotation_y: float
    rotation_z: float
    mag_field_x: float
    mag_field_y: float
    mag_field_z: float


@dataclass
class TripleAxisSample:
    timestamp: str
    x: float
    y: float
    z: float


@dataclass
class BarometerSample:
    timestamp: str
    relative_altitude_m: float
    pressure_kpa: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Visualize exported Core Motion + Core Location Geo logs with Rerun."
    )
    parser.add_argument(
        "input",
        type=Path,
        help="Path to an exported geo-*.json package or a session directory containing the Outdoor log files.",
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
    parser.add_argument(
        "--mapbox-token",
        help="Optional Mapbox token for the embedded Rerun MapView. If omitted, MAPBOX_ACCESS_TOKEN is used.",
    )
    return parser.parse_args()


def parse_timestamp(timestamp: str) -> datetime:
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00"))


def seconds_since(timestamp: str, start: datetime) -> float:
    return (parse_timestamp(timestamp) - start).total_seconds()


def parse_jsonl(content: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def read_export(input_path: Path) -> tuple[dict[str, str], str]:
    input_path = input_path.expanduser().resolve()

    if input_path.is_dir():
        session_name = input_path.name
        files: dict[str, str] = {}
        for path in input_path.iterdir():
            if path.is_file():
                files[path.name] = path.read_text(encoding="utf-8")
        return files, session_name

    payload = json.loads(input_path.read_text(encoding="utf-8"))
    session_name = payload.get("session_directory", input_path.stem)
    files = {entry["name"]: entry["content"] for entry in payload.get("files", [])}
    return files, session_name


def parse_location_csv(content: str) -> list[LocationSample]:
    reader = csv.DictReader(io.StringIO(content))
    raw_rows = list(reader)
    if not raw_rows:
        return []

    ref_lat = float(raw_rows[0]["latitude"])
    ref_lon = float(raw_rows[0]["longitude"])
    ref_alt = float(raw_rows[0]["altitude_m"])
    latitude_scale = 111_132.0
    longitude_scale = max(math.cos(math.radians(ref_lat)) * 111_320.0, 0.0001)

    samples: list[LocationSample] = []
    for row in raw_rows:
        lat = float(row["latitude"])
        lon = float(row["longitude"])
        alt = float(row["altitude_m"])
        north_m = (lat - ref_lat) * latitude_scale
        east_m = (lon - ref_lon) * longitude_scale
        up_m = alt - ref_alt

        samples.append(
            LocationSample(
                timestamp=row["timestamp"],
                east_m=east_m,
                north_m=north_m,
                up_m=up_m,
                horizontal_accuracy_m=float(row["horizontal_accuracy_m"]),
                vertical_accuracy_m=float(row["vertical_accuracy_m"]),
                speed_mps=float(row["speed_mps"]),
                course_deg=float(row["course_deg"]),
            )
        )

    return samples


def parse_heading_csv(content: str) -> list[HeadingSample]:
    reader = csv.DictReader(io.StringIO(content))
    return [
        HeadingSample(
            timestamp=row["timestamp"],
            magnetic_heading_deg=float(row["magnetic_heading_deg"]),
            true_heading_deg=float(row["true_heading_deg"]),
            heading_accuracy_deg=float(row["heading_accuracy_deg"]),
            x=float(row["x"]),
            y=float(row["y"]),
            z=float(row["z"]),
        )
        for row in reader
    ]


def parse_motion_csv(content: str) -> list[DeviceMotionSample]:
    reader = csv.DictReader(io.StringIO(content))
    return [
        DeviceMotionSample(
            timestamp=row["timestamp"],
            roll_deg=float(row["roll_deg"]),
            pitch_deg=float(row["pitch_deg"]),
            yaw_deg=float(row["yaw_deg"]),
            gravity_x=float(row["gravity_x"]),
            gravity_y=float(row["gravity_y"]),
            gravity_z=float(row["gravity_z"]),
            user_accel_x=float(row["user_accel_x"]),
            user_accel_y=float(row["user_accel_y"]),
            user_accel_z=float(row["user_accel_z"]),
            rotation_x=float(row["rotation_x"]),
            rotation_y=float(row["rotation_y"]),
            rotation_z=float(row["rotation_z"]),
            mag_field_x=float(row["mag_field_x"]),
            mag_field_y=float(row["mag_field_y"]),
            mag_field_z=float(row["mag_field_z"]),
        )
        for row in reader
    ]


def parse_triple_axis_csv(content: str, x_key: str, y_key: str, z_key: str) -> list[TripleAxisSample]:
    reader = csv.DictReader(io.StringIO(content))
    return [
        TripleAxisSample(
            timestamp=row["timestamp"],
            x=float(row[x_key]),
            y=float(row[y_key]),
            z=float(row[z_key]),
        )
        for row in reader
    ]


def parse_barometer_csv(content: str) -> list[BarometerSample]:
    reader = csv.DictReader(io.StringIO(content))
    samples: list[BarometerSample] = []
    for row in reader:
        if not row["timestamp"]:
            continue
        samples.append(
            BarometerSample(
                timestamp=row["timestamp"],
                relative_altitude_m=float(row["relative_altitude_m"]),
                pressure_kpa=float(row["pressure_kpa"]),
            )
        )
    return samples


def log_series_static(path: str, names: list[str], colors: list[list[int]]) -> None:
    rr.log(path, rr.SeriesLines(names=names, colors=colors, widths=[2] * len(names)), static=True)


def set_sample_time(timestamp: str, start: datetime, sequence: int) -> None:
    rr.set_time("sample", sequence=sequence)
    rr.set_time("seconds", duration=seconds_since(timestamp, start))


def log_locations(samples: list[LocationSample], start: datetime) -> None:
    trajectory: list[tuple[float, float, float]] = []
    for index, sample in enumerate(samples):
        set_sample_time(sample.timestamp, start, index)
        point = (sample.east_m, sample.north_m, sample.up_m)
        trajectory.append(point)
        rr.log("geo/track", rr.LineStrips3D([trajectory], colors=[[80, 210, 255]], radii=[0.08]))
        rr.log("geo/current_fix", rr.Points3D([point], colors=[[255, 255, 255]], radii=[0.25]))
        rr.log("plots/location", rr.Scalars([sample.east_m, sample.north_m, sample.up_m]))
        rr.log("plots/gps_accuracy_horizontal", rr.Scalars([sample.horizontal_accuracy_m]))
        rr.log("plots/gps_accuracy_vertical", rr.Scalars([sample.vertical_accuracy_m]))
        rr.log("plots/speed_mps", rr.Scalars([sample.speed_mps]))


def log_heading(samples: list[HeadingSample], start: datetime) -> None:
    for index, sample in enumerate(samples):
        set_sample_time(sample.timestamp, start, index)
        rr.log("plots/heading_true_deg", rr.Scalars([sample.true_heading_deg]))
        rr.log("plots/heading_magnetic_deg", rr.Scalars([sample.magnetic_heading_deg]))
        rr.log("plots/heading_accuracy_deg", rr.Scalars([sample.heading_accuracy_deg]))
        rr.log("plots/heading_raw_xyz", rr.Scalars([sample.x, sample.y, sample.z]))


def log_device_motion(samples: list[DeviceMotionSample], start: datetime) -> None:
    for index, sample in enumerate(samples):
        set_sample_time(sample.timestamp, start, index)
        rr.log("plots/attitude_deg", rr.Scalars([sample.roll_deg, sample.pitch_deg, sample.yaw_deg]))
        rr.log(
            "plots/gravity_mps2",
            rr.Scalars(
                [
                    sample.gravity_x * STANDARD_GRAVITY,
                    sample.gravity_y * STANDARD_GRAVITY,
                    sample.gravity_z * STANDARD_GRAVITY,
                ]
            ),
        )
        rr.log(
            "plots/user_accel_mps2",
            rr.Scalars(
                [
                    sample.user_accel_x * STANDARD_GRAVITY,
                    sample.user_accel_y * STANDARD_GRAVITY,
                    sample.user_accel_z * STANDARD_GRAVITY,
                ]
            ),
        )
        rr.log("plots/rotation_rate", rr.Scalars([sample.rotation_x, sample.rotation_y, sample.rotation_z]))
        rr.log("plots/device_motion_mag_field", rr.Scalars([sample.mag_field_x, sample.mag_field_y, sample.mag_field_z]))


def log_triple_axis(samples: list[TripleAxisSample], start: datetime, path: str) -> None:
    for index, sample in enumerate(samples):
        set_sample_time(sample.timestamp, start, index)
        if path == "plots/accelerometer_mps2":
            rr.log(
                path,
                rr.Scalars(
                    [
                        sample.x * STANDARD_GRAVITY,
                        sample.y * STANDARD_GRAVITY,
                        sample.z * STANDARD_GRAVITY,
                    ]
                ),
            )
        else:
            rr.log(path, rr.Scalars([sample.x, sample.y, sample.z]))


def log_barometer(samples: list[BarometerSample], start: datetime) -> None:
    for index, sample in enumerate(samples):
        set_sample_time(sample.timestamp, start, index)
        rr.log("plots/barometer_relative_altitude_m", rr.Scalars([sample.relative_altitude_m]))
        rr.log("plots/barometer_pressure_kpa", rr.Scalars([sample.pressure_kpa]))


def log_json_events(events: list[dict[str, Any]], start: datetime, path: str) -> None:
    for index, event in enumerate(events):
        timestamp = event.get("timestamp")
        if timestamp:
            set_sample_time(timestamp, start, index)
        else:
            rr.set_time("sample", sequence=index)
        rr.log(path, rr.TextLog(json.dumps(event, sort_keys=True)))


def init_static_layout() -> None:
    rr.log("geo", rr.ViewCoordinates.RIGHT_HAND_Z_UP, static=True)
    log_series_static("plots/location", ["east [m]", "north [m]", "up [m]"], [[90, 180, 255], [80, 220, 150], [255, 190, 90]])
    log_series_static("plots/attitude_deg", ["roll [deg]", "pitch [deg]", "yaw [deg]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/gravity_mps2", ["gx [m/s^2]", "gy [m/s^2]", "gz [m/s^2]"], [[220, 220, 220], [150, 150, 255], [150, 255, 200]])
    log_series_static("plots/user_accel_mps2", ["ax [m/s^2]", "ay [m/s^2]", "az [m/s^2]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/rotation_rate", ["wx [rad/s]", "wy [rad/s]", "wz [rad/s]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/device_motion_mag_field", ["mx [uT]", "my [uT]", "mz [uT]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/heading_raw_xyz", ["hx", "hy", "hz"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/accelerometer_mps2", ["ax [m/s^2]", "ay [m/s^2]", "az [m/s^2]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/gyro", ["wx [rad/s]", "wy [rad/s]", "wz [rad/s]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/magnetometer", ["mx [uT]", "my [uT]", "mz [uT]"], [[255, 170, 80], [80, 190, 255], [160, 220, 100]])
    log_series_static("plots/heading_true_deg", ["true heading [deg]"], [[255, 96, 96]])
    log_series_static("plots/heading_magnetic_deg", ["magnetic heading [deg]"], [[255, 200, 120]])
    log_series_static("plots/heading_accuracy_deg", ["heading accuracy [deg]"], [[180, 180, 180]])
    log_series_static("plots/gps_accuracy_horizontal", ["horizontal accuracy [m]"], [[255, 96, 96]])
    log_series_static("plots/gps_accuracy_vertical", ["vertical accuracy [m]"], [[255, 200, 120]])
    log_series_static("plots/speed_mps", ["speed [m/s]"], [[120, 220, 120]])
    log_series_static("plots/barometer_relative_altitude_m", ["relative altitude [m]"], [[180, 120, 255]])
    log_series_static("plots/barometer_pressure_kpa", ["pressure [kPa]"], [[255, 170, 80]])


def log_geo_entities(raw_location_rows: list[dict[str, str]]) -> None:
    if not raw_location_rows:
        return

    lat_lon = [[float(row["latitude"]), float(row["longitude"])] for row in raw_location_rows]

    rr.log(
        "map/track",
        rr.GeoLineStrings(
            lat_lon=[lat_lon],
            colors=[[45, 212, 191]],
            radii=rr.Radius.ui_points(2.0),
        ),
        static=True,
    )
    rr.log(
        "map/fixes",
        rr.GeoPoints(
            lat_lon=lat_lon,
            colors=[[255, 255, 255] for _ in lat_lon],
            radii=rr.Radius.ui_points(2.5),
        ),
        static=True,
    )
    rr.log(
        "map/start",
        rr.GeoPoints(
            lat_lon=[lat_lon[0]],
            colors=[[34, 197, 94]],
            radii=rr.Radius.ui_points(5.0),
        ),
        static=True,
    )
    rr.log(
        "map/end",
        rr.GeoPoints(
            lat_lon=[lat_lon[-1]],
            colors=[[239, 68, 68]],
            radii=rr.Radius.ui_points(5.0),
        ),
        static=True,
    )


def send_blueprint(use_mapbox: bool, has_barometer: bool) -> None:
    map_background = rrb.MapProvider.MapboxDark if use_mapbox else rrb.MapProvider.OpenStreetMap
    active_tab = "Barometer" if has_barometer else "Position"
    blueprint = rrb.Blueprint(
        rrb.Horizontal(
            rrb.MapView(
                origin="/",
                contents=["/map/**"],
                name="Map",
                zoom=17.0,
                background=map_background,
            ),
            rrb.Tabs(
                rrb.TimeSeriesView(origin="/", contents=["/plots/location"], name="Position"),
                rrb.TimeSeriesView(
                    origin="/",
                    contents=["/plots/heading_true_deg", "/plots/heading_magnetic_deg", "/plots/heading_accuracy_deg"],
                    name="Heading",
                ),
                rrb.TimeSeriesView(
                    origin="/",
                    contents=["/plots/attitude_deg", "/plots/user_accel_mps2", "/plots/rotation_rate", "/plots/gravity_mps2"],
                    name="Motion",
                ),
                rrb.TimeSeriesView(
                    origin="/",
                    contents=["/plots/accelerometer_mps2", "/plots/gyro", "/plots/magnetometer"],
                    name="Raw IMU",
                ),
                rrb.TimeSeriesView(
                    origin="/",
                    contents=["/plots/barometer_relative_altitude_m", "/plots/barometer_pressure_kpa"],
                    name="Barometer",
                ),
                rrb.TextLogView(origin="/", contents=["/status/**", "/events/**"], name="Logs"),
                active_tab=active_tab,
                name="Telemetry",
            ),
            column_shares=[0.55, 0.45],
        ),
        collapse_panels=True,
    )
    rr.send_blueprint(blueprint)


def main() -> None:
    args = parse_args()
    files, session_name = read_export(args.input)
    raw_location_rows = list(csv.DictReader(io.StringIO(files.get("location.csv", ""))))

    location_samples = parse_location_csv(files.get("location.csv", ""))
    heading_samples = parse_heading_csv(files.get("heading.csv", ""))
    motion_samples = parse_motion_csv(files.get("device_motion.csv", ""))
    accelerometer_samples = parse_triple_axis_csv(files.get("accelerometer.csv", ""), "ax_g", "ay_g", "az_g")
    gyro_samples = parse_triple_axis_csv(files.get("gyro.csv", ""), "gx_rps", "gy_rps", "gz_rps")
    magnetometer_samples = parse_triple_axis_csv(files.get("magnetometer.csv", ""), "mx_uT", "my_uT", "mz_uT")
    barometer_samples = parse_barometer_csv(files.get("barometer.csv", ""))
    status_events = parse_jsonl(files.get("status.jsonl", ""))
    event_logs = parse_jsonl(files.get("events.jsonl", ""))

    candidate_timestamps = [
        samples[0].timestamp
        for samples in [
            location_samples,
            heading_samples,
            motion_samples,
            accelerometer_samples,
            gyro_samples,
            magnetometer_samples,
            barometer_samples,
        ]
        if samples
    ]
    candidate_timestamps += [row["timestamp"] for row in status_events[:1] if "timestamp" in row]
    candidate_timestamps += [row["timestamp"] for row in event_logs[:1] if "timestamp" in row]

    if not candidate_timestamps:
        raise ValueError("No Geo samples found in export")

    start = min(parse_timestamp(timestamp) for timestamp in candidate_timestamps)
    mapbox_token = args.mapbox_token or os.environ.get("MAPBOX_ACCESS_TOKEN")
    if mapbox_token:
        os.environ["RERUN_MAPBOX_ACCESS_TOKEN"] = mapbox_token

    rr.init(f"arkit_geo_log_{session_name}", spawn=args.spawn)
    if args.save:
        rr.save(args.save)

    init_static_layout()
    log_geo_entities(raw_location_rows)
    send_blueprint(use_mapbox=bool(mapbox_token), has_barometer=bool(barometer_samples))
    log_locations(location_samples, start)
    log_heading(heading_samples, start)
    log_device_motion(motion_samples, start)
    log_triple_axis(accelerometer_samples, start, "plots/accelerometer_mps2")
    log_triple_axis(gyro_samples, start, "plots/gyro")
    log_triple_axis(magnetometer_samples, start, "plots/magnetometer")
    log_barometer(barometer_samples, start)
    log_json_events(status_events, start, "status/log")
    log_json_events(event_logs, start, "events/log")

    print(
        "Loaded "
        f"{len(location_samples)} location, "
        f"{len(heading_samples)} heading, "
        f"{len(motion_samples)} device-motion, "
        f"{len(accelerometer_samples)} accelerometer, "
        f"{len(gyro_samples)} gyro, "
        f"{len(magnetometer_samples)} magnetometer, "
        f"{len(barometer_samples)} barometer samples"
    )
    print(f"Loaded {len(status_events)} status rows and {len(event_logs)} events from {session_name}")
    if args.save:
        print(f"Saved Rerun recording to {args.save}")


if __name__ == "__main__":
    main()
