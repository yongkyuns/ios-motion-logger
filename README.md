# iOS Motion Logger

An iPhone app for logging motion and location sensor data with live visualizations.

It includes:

- `World Demo`: ARKit-based trajectory and semantic mapping views
- `Geo Demo`: Core Location + Core Motion logging for GPS, heading, device motion, accelerometer, gyroscope, magnetometer, and barometer
- export of on-device session logs as a single JSON package
- Python helpers to visualize exported logs in Rerun or on a Mapbox map

## Requirements

- Xcode 16+
- iOS 17+
- a physical iPhone for sensor and AR features
- `xcodegen` to regenerate the Xcode project

## Setup

1. Generate the Xcode project:

   ```bash
   xcodegen generate
   ```

2. Open `MonocularSLAMDemo.xcodeproj` in Xcode.
3. Select your Apple development team in Signing & Capabilities.
4. Build and run on an iPhone.

The repository does not include a personal development team or private bundle identifier. Update signing locally before installing to a device.

## Logging

The `Geo Demo` exports a JSON package containing embedded CSV and JSONL files such as:

- `geo_location.csv`
- `geo_heading.csv`
- `geo_device_motion.csv`
- `geo_accelerometer.csv`
- `geo_gyro.csv`
- `geo_magnetometer.csv`
- `geo_barometer.csv`
- `geo_status.jsonl`
- `geo_events.jsonl`

Session files are first written into the app's `Documents/ARLogs/<session>/` directory and then packaged for sharing.

## Environment Variables

No personal tokens are stored in the repository. The visualization scripts read credentials from environment variables instead.

Mapbox:

```bash
export MAPBOX_ACCESS_TOKEN=your_mapbox_token
export RERUN_MAPBOX_ACCESS_TOKEN="$MAPBOX_ACCESS_TOKEN"
```

## Visualization

### Rerun

```bash
python3 scripts/view_geo_log_rerun.py ~/Downloads/geo-YYYY-MM-DDTHH-MM-SS.sssZ.json --spawn
```

If `RERUN_MAPBOX_ACCESS_TOKEN` is set, the embedded Rerun map uses Mapbox Dark.

### Mapbox HTML

```bash
python3 scripts/view_geo_log_mapbox.py ~/Downloads/geo-YYYY-MM-DDTHH-MM-SS.sssZ.json
```

This reads `MAPBOX_ACCESS_TOKEN` automatically, or you can pass `--token`.

## Privacy and Publishing

This public repo intentionally excludes:

- personal Apple signing team identifiers
- personal bundle identifiers
- private access tokens
- local export artifacts and editor metadata

See [.env.example](.env.example) for the expected environment-variable names.

## License

MIT. See [LICENSE](LICENSE).
