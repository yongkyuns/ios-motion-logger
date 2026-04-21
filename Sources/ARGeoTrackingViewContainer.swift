import Charts
import SwiftUI

private enum GeoSignalScope: String, CaseIterable, Identifiable {
    case location
    case heading
    case attitude
    case acceleration
    case gyro
    case magnetometer
    case barometer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location:
            return "Position"
        case .heading:
            return "Heading"
        case .attitude:
            return "Attitude"
        case .acceleration:
            return "Accel"
        case .gyro:
            return "Gyro"
        case .magnetometer:
            return "Mag"
        case .barometer:
            return "Baro"
        }
    }

    var subtitle: String {
        switch self {
        case .location:
            return "Relative north, east, and altitude in meters"
        case .heading:
            return "Compass heading in degrees"
        case .attitude:
            return "Roll, pitch, and yaw in degrees"
        case .acceleration:
            return "Accelerometer axes in g"
        case .gyro:
            return "Rotation rate in radians per second"
        case .magnetometer:
            return "Magnetic field in microtesla"
        case .barometer:
            return "Relative altitude in meters"
        }
    }

    @MainActor
    func samples(from viewModel: ARGeoTrackingViewModel) -> [GeoSignalSample] {
        switch self {
        case .location:
            return viewModel.locationHistory
        case .heading:
            return viewModel.headingHistory
        case .attitude:
            return viewModel.attitudeHistory
        case .acceleration:
            return viewModel.accelerometerHistory
        case .gyro:
            return viewModel.gyroHistory
        case .magnetometer:
            return viewModel.magnetometerHistory
        case .barometer:
            return viewModel.barometerHistory
        }
    }

    func color(for series: String) -> Color {
        switch (self, series) {
        case (.location, "North"):
            return Color(red: 0.20, green: 0.82, blue: 0.64)
        case (.location, "East"):
            return Color(red: 0.38, green: 0.67, blue: 0.98)
        case (.location, "Altitude"):
            return Color(red: 0.97, green: 0.65, blue: 0.28)
        case (.heading, _):
            return Color(red: 0.94, green: 0.36, blue: 0.30)
        case (_, "Roll"):
            return Color(red: 0.97, green: 0.65, blue: 0.28)
        case (_, "Pitch"):
            return Color(red: 0.32, green: 0.77, blue: 0.95)
        case (_, "Yaw"):
            return Color(red: 0.61, green: 0.86, blue: 0.43)
        case (_, "X"):
            return Color(red: 0.97, green: 0.65, blue: 0.28)
        case (_, "Y"):
            return Color(red: 0.32, green: 0.77, blue: 0.95)
        case (_, "Z"):
            return Color(red: 0.61, green: 0.86, blue: 0.43)
        case (_, "Relative Altitude"):
            return Color(red: 0.87, green: 0.59, blue: 0.96)
        default:
            return .white
        }
    }
}

struct ARGeoTrackingViewContainer: View {
    @ObservedObject var viewModel: ARGeoTrackingViewModel
    @State private var selectedScope: GeoSignalScope = .attitude

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                mapPanel
                    .frame(height: min(max(proxy.size.height * 0.32, 190), 260))

                VStack(alignment: .leading, spacing: 10) {
                    scopePicker

                    Text(selectedScope.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.58))

                    chartPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .layoutPriority(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                metricStrip
            }
            .padding(.horizontal, 12)
            .padding(.top, 0)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.03, green: 0.04, blue: 0.06))
        }
    }

    private var mapPanel: some View {
        panel {
            GeoTraceMapView(
                traceCoordinates: viewModel.traceCoordinates,
                currentLocation: viewModel.currentLocationSnapshot
            )
        }
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GeoSignalScope.allCases) { scope in
                    Button {
                        selectedScope = scope
                    } label: {
                        Text(scope.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedScope == scope ? Color.black : Color.white.opacity(0.82))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedScope == scope
                                    ? Color.white
                                    : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var chartPanel: some View {
        let samples = selectedScope.samples(from: viewModel)
        let groupedSeries = Dictionary(grouping: samples) { sample in
            GeoSeriesSegmentKey(series: sample.series, segmentID: sample.segmentID)
        }
        let sortedKeys = groupedSeries.keys.sorted {
            if $0.series == $1.series {
                return $0.segmentID < $1.segmentID
            }
            return $0.series < $1.series
        }

        return VStack(alignment: .leading, spacing: 10) {
            if samples.isEmpty {
                emptyState
            } else {
                Chart {
                    ForEach(sortedKeys, id: \.self) { key in
                        if let seriesSamples = groupedSeries[key]?.sorted(by: { $0.timestamp < $1.timestamp }) {
                            ForEach(Array(seriesSamples.enumerated()), id: \.element.id) { index, sample in
                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Value", sample.value),
                                    series: .value("Trace", key.chartSeriesID)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(selectedScope.color(for: key.series))
                                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                                if index == seriesSamples.count - 1 {
                                    PointMark(
                                        x: .value("Time", sample.timestamp),
                                        y: .value("Value", sample.value)
                                    )
                                    .foregroundStyle(selectedScope.color(for: key.series))
                                    .symbolSize(36)
                                }
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.white.opacity(0.1))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.white.opacity(0.24))
                        AxisValueLabel(format: .dateTime.minute().second())
                            .foregroundStyle(Color.white.opacity(0.48))
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text("Waiting for samples")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Grant permissions and move the device to populate this signal.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var metricStrip: some View {
        let entries = latestEntries(for: selectedScope.samples(from: viewModel))

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries, id: \.series) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.series.uppercased())
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.5))
                        Text(entry.displayValue)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func latestEntries(for samples: [GeoSignalSample]) -> [(series: String, displayValue: String)] {
        let grouped = Dictionary(grouping: samples, by: \.series)

        return grouped.keys.sorted().compactMap { series in
            guard let sample = grouped[series]?.last else { return nil }
            return (series, String(format: "%.2f", sample.value))
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct GeoSeriesSegmentKey: Hashable {
    let series: String
    let segmentID: Int

    var chartSeriesID: String {
        "\(series)-\(segmentID)"
    }
}
