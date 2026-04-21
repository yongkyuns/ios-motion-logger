# iOS Motion Logger

[![CI](https://github.com/yongkyuns/ios-motion-logger/actions/workflows/ci.yml/badge.svg)](https://github.com/yongkyuns/ios-motion-logger/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](#requirements)

📱 A friendly iPhone app for logging motion, location, and AR sensor data, then exporting it for analysis.

This repo gives you two demos:

- 🏠 `Indoor`: ARKit-based tracking, trajectory, and semantic mapping
- 🌤️ `Outdoor`: Core Location + Core Motion logging for GPS, heading, attitude, accelerometer, gyroscope, magnetometer, and barometer

It also includes:

- 📦 one-tap export of session logs as a single JSON package
- 🗺️ Python tools to visualize exported logs in Rerun or on a Mapbox map
- 🤖 CI that builds the app and validates the Rerun pipeline

## ✨ What You Can Do

- Record live sensor data on an iPhone
- Export sessions for offline debugging and analysis
- Visualize GPS tracks, IMU streams, heading, and barometer data in Rerun
- Inspect logs without keeping any personal Apple team IDs or tokens in the repo

## ✅ Requirements

- Xcode 16+
- iOS 17+
- A physical iPhone for sensor and AR features
- `xcodegen` if you want to regenerate the Xcode project from `project.yml`
- Python 3.10+ for the visualization scripts

## 🚀 Quick Start

### 1. Clone the repo

```bash
git clone git@github.com:yongkyuns/ios-motion-logger.git
cd ios-motion-logger
```

### 2. Open the app in Xcode

You can use the checked-in project directly:

```bash
open MonocularSLAMDemo.xcodeproj
```

If you want to regenerate it first:

```bash
xcodegen generate
open MonocularSLAMDemo.xcodeproj
```

### 3. Set up signing

In Xcode:

1. Select the `MonocularSLAMDemo` target
2. Open `Signing & Capabilities`
3. Choose your Apple development team
4. Build and run on your iPhone

This public repo intentionally does not include a personal team ID or personal bundle identifier.

## 🧭 Using the App

### Indoor

Use `Indoor` when you want:

- ARKit trajectory tracking
- semantic mapping / mesh visualization
- indoor AR logging workflows

### Outdoor

Use `Outdoor` when you want:

- GPS position and accuracy
- heading / compass
- device attitude
- raw IMU streams
- barometer / relative altitude

If the barometer says it needs permission, enable:

`Settings > Privacy & Security > Motion & Fitness`

Then make sure:

- `Fitness Tracking` is on
- this app is allowed to access Motion & Fitness

## 📂 Export Format

`Outdoor` exports a single JSON package that contains embedded CSV and JSONL files such as:

- `geo_location.csv`
- `geo_heading.csv`
- `geo_device_motion.csv`
- `geo_accelerometer.csv`
- `geo_gyro.csv`
- `geo_magnetometer.csv`
- `geo_barometer.csv`
- `geo_status.jsonl`
- `geo_events.jsonl`

The app first writes raw files to:

```text
Documents/ARLogs/<session>/
```

Then it packages them into one shareable `.json` export.

## 📊 Visualize Logs Step by Step

### Option A: Rerun

Install the Python dependency:

```bash
python3 -m pip install rerun-sdk
```

Run the Geo viewer:

```bash
python3 scripts/view_geo_log_rerun.py ~/Downloads/geo-YYYY-MM-DDTHH-MM-SS.sssZ.json --spawn
```

Useful notes:

- The viewer includes map, position, heading, motion, raw IMU, barometer, and logs
- If barometer samples are present, the `Barometer` tab opens by default
- You can save a headless recording instead of spawning the UI:

```bash
python3 scripts/view_geo_log_rerun.py ~/Downloads/geo-YYYY-MM-DDTHH-MM-SS.sssZ.json --save /tmp/geo.rrd
```

### Option B: Mapbox HTML

Set your token:

```bash
export MAPBOX_ACCESS_TOKEN=your_mapbox_token
export RERUN_MAPBOX_ACCESS_TOKEN="$MAPBOX_ACCESS_TOKEN"
```

Then generate the HTML map:

```bash
python3 scripts/view_geo_log_mapbox.py ~/Downloads/geo-YYYY-MM-DDTHH-MM-SS.sssZ.json
```

## 🔐 Environment Variables

No personal tokens are stored in this repo.

For local Mapbox-backed visualizations, use:

```bash
export MAPBOX_ACCESS_TOKEN=your_mapbox_token
export RERUN_MAPBOX_ACCESS_TOKEN="$MAPBOX_ACCESS_TOKEN"
```

See [.env.example](.env.example) for the expected variable names.

## 🤖 CI Pipeline

The GitHub Actions workflow does two concrete checks on every push and pull request:

1. Builds the iOS app with unsigned device-compatible settings
2. Runs the Geo Rerun script headlessly against a checked-in sample export and saves a `.rrd` artifact

The sample input used by CI lives at:

- [fixtures/geo-sample.json](fixtures/geo-sample.json)

The workflow file is:

- [.github/workflows/ci.yml](.github/workflows/ci.yml)

## 🧼 Privacy Notes

This public repo intentionally excludes:

- personal Apple signing team identifiers
- personal bundle identifiers
- private access tokens
- local export artifacts
- editor and device-specific metadata

## 📄 License

MIT. See [LICENSE](LICENSE).
