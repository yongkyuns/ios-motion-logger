#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import io
import json
import os
from pathlib import Path

import plotly.graph_objects as go


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render exported Geo logs on a Mapbox map."
    )
    parser.add_argument(
        "input",
        type=Path,
        help="Path to an exported geo-*.json package or a session directory containing location.csv.",
    )
    parser.add_argument(
        "--token",
        help="Mapbox access token. If omitted, MAPBOX_ACCESS_TOKEN is used.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output HTML path. Defaults to <session>.html next to the input.",
    )
    return parser.parse_args()


def read_location_csv(input_path: Path) -> tuple[list[dict[str, str]], str]:
    input_path = input_path.expanduser().resolve()

    if input_path.is_dir():
        session_name = input_path.name
        location_csv = input_path.joinpath("location.csv").read_text(encoding="utf-8")
    else:
        payload = json.loads(input_path.read_text(encoding="utf-8"))
        session_name = payload.get("session_directory", input_path.stem)
        files = {entry["name"]: entry["content"] for entry in payload.get("files", [])}
        location_csv = files["location.csv"]

    rows = list(csv.DictReader(io.StringIO(location_csv)))
    if not rows:
        raise ValueError("No location rows found in location.csv")

    return rows, session_name


def make_hover_text(row: dict[str, str]) -> str:
    return (
        f"time: {row['timestamp']}<br>"
        f"lat/lon: {row['latitude']}, {row['longitude']}<br>"
        f"alt: {row['altitude_m']} m<br>"
        f"hAcc/vAcc: {row['horizontal_accuracy_m']} / {row['vertical_accuracy_m']} m<br>"
        f"speed: {row['speed_mps']} m/s<br>"
        f"course: {row['course_deg']} deg"
    )


def build_figure(rows: list[dict[str, str]], session_name: str, token: str) -> go.Figure:
    lats = [float(row["latitude"]) for row in rows]
    lons = [float(row["longitude"]) for row in rows]
    alts = [float(row["altitude_m"]) for row in rows]
    hover_text = [make_hover_text(row) for row in rows]

    center_lat = sum(lats) / len(lats)
    center_lon = sum(lons) / len(lons)
    lat_span = max(lats) - min(lats)
    lon_span = max(lons) - min(lons)
    max_span = max(lat_span, lon_span, 1e-5)

    if max_span < 5e-5:
        zoom = 18
    elif max_span < 2e-4:
        zoom = 16
    elif max_span < 1e-3:
        zoom = 14
    else:
        zoom = 12

    fig = go.Figure()

    fig.add_trace(
        go.Scattermapbox(
            lat=lats,
            lon=lons,
            mode="lines+markers",
            line={"width": 4, "color": "#2dd4bf"},
            marker={
                "size": 8,
                "color": alts,
                "colorscale": "Turbo",
                "showscale": True,
                "colorbar": {"title": "Altitude (m)"},
            },
            text=hover_text,
            hovertemplate="%{text}<extra>track</extra>",
            name="GPS Track",
        )
    )

    fig.add_trace(
        go.Scattermapbox(
            lat=[lats[0]],
            lon=[lons[0]],
            mode="markers+text",
            marker={"size": 16, "color": "#22c55e"},
            text=["Start"],
            textposition="top right",
            hovertemplate=hover_text[0] + "<extra>start</extra>",
            name="Start",
        )
    )

    fig.add_trace(
        go.Scattermapbox(
            lat=[lats[-1]],
            lon=[lons[-1]],
            mode="markers+text",
            marker={"size": 16, "color": "#ef4444"},
            text=["End"],
            textposition="top right",
            hovertemplate=hover_text[-1] + "<extra>end</extra>",
            name="End",
        )
    )

    fig.update_layout(
        title={
            "text": f"{session_name} GPS track",
            "x": 0.02,
            "xanchor": "left",
        },
        mapbox={
            "accesstoken": token,
            "style": "mapbox://styles/mapbox/satellite-streets-v12",
            "center": {"lat": center_lat, "lon": center_lon},
            "zoom": zoom,
        },
        margin={"l": 0, "r": 0, "t": 48, "b": 0},
        legend={"x": 0.01, "y": 0.99},
        paper_bgcolor="#0b0f14",
        plot_bgcolor="#0b0f14",
    )

    return fig


def default_output_path(input_path: Path, session_name: str) -> Path:
    if input_path.is_dir():
        return input_path.joinpath(f"{session_name}-mapbox.html")
    return input_path.with_name(f"{session_name}-mapbox.html")


def main() -> None:
    args = parse_args()
    token = args.token or os.environ.get("MAPBOX_ACCESS_TOKEN")
    if not token:
        raise SystemExit("Missing Mapbox token. Pass --token or set MAPBOX_ACCESS_TOKEN.")
    rows, session_name = read_location_csv(args.input)
    output_path = (args.output or default_output_path(args.input.expanduser().resolve(), session_name)).expanduser().resolve()
    figure = build_figure(rows, session_name, token)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.write_html(output_path, include_plotlyjs="cdn")
    print(f"Saved Mapbox view to {output_path}")


if __name__ == "__main__":
    main()
