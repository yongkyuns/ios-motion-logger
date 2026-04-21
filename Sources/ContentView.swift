import SwiftUI

struct ContentView: View {
    @State private var demoMode: DemoMode = .geo

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.02, green: 0.03, blue: 0.04)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar(safeAreaTop: proxy.safeAreaInsets.top)

                    Group {
                        switch demoMode {
                        case .world:
                            WorldTrackingDemoView()
                        case .geo:
                            GeoTrackingDemoView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .statusBar(hidden: true)
    }

    private func topBar(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(DemoMode.allCases) { mode in
                    Button {
                        demoMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(demoMode == mode ? Color.black : Color.white.opacity(0.86))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                demoMode == mode
                                    ? Color.white
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, safeAreaTop > 0 ? 6 : 8)
            .padding(.bottom, 8)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.06),
                    Color(red: 0.02, green: 0.03, blue: 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }
}

private enum DemoMode: String, CaseIterable, Identifiable {
    case world
    case geo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .world:
            return "Current Demo"
        case .geo:
            return "Geo Demo"
        }
    }
}

private struct WorldTrackingDemoView: View {
    @StateObject private var viewModel = ARTrackingViewModel()
    @State private var visibleSemanticClasses: Set<SemanticSurfaceClass> = SemanticSurfaceClass.defaultVisible
    @State private var isFollowingDevice = true
    @State private var exportItems: [URL] = []
    @State private var isPreparingExport = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                panel {
                    ZStack(alignment: .topLeading) {
                        ARViewContainer(
                            viewModel: viewModel,
                            visibleSemanticClasses: visibleSemanticClasses
                        )

                        semanticControls
                            .padding(.top, 8)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(height: min(max(proxy.size.height * 0.22, 150), 190))

                panel {
                    ZStack(alignment: .topTrailing) {
                        ThreeDMapView(
                            trajectoryPoints: viewModel.trajectory3DPoints,
                            featurePoints: viewModel.mapFeaturePoints,
                            semanticMeshChunks: viewModel.semanticMeshChunks,
                            visibleSemanticClasses: visibleSemanticClasses,
                            currentDevicePosition: viewModel.currentCameraPosition,
                            currentDeviceYawRadians: viewModel.currentCameraYawRadians,
                            isFollowingDevice: isFollowingDevice,
                            onManualCameraControl: {
                                if isFollowingDevice {
                                    isFollowingDevice = false
                                }
                            }
                        )

                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Follow") {
                                isFollowingDevice = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Reset") {
                                isFollowingDevice = true
                                viewModel.resetTracking()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Export Logs") {
                                guard !isPreparingExport else { return }
                                isPreparingExport = true
                                Task {
                                    let archiveURL = await viewModel.makeExportArchive()
                                    await MainActor.run {
                                        isPreparingExport = false
                                        if let archiveURL {
                                            exportItems = [archiveURL]
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isPreparingExport)
                        }
                        .padding(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 0)
        }
        .sheet(isPresented: exportSheetBinding) {
            ActivityViewController(items: exportItems.map { $0 as Any })
        }
    }

    private var semanticControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SemanticSurfaceClass.allCases) { semanticClass in
                    semanticChip(for: semanticClass)
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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

    private func semanticChip(for semanticClass: SemanticSurfaceClass) -> some View {
        let isVisible = visibleSemanticClasses.contains(semanticClass)

        return Button {
            if isVisible {
                visibleSemanticClasses.remove(semanticClass)
            } else {
                visibleSemanticClasses.insert(semanticClass)
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(semanticClass.color)
                    .frame(width: 8, height: 8)
                Text(semanticClass.title)
                    .font(.caption)
                    .foregroundStyle(isVisible ? Color.white : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((isVisible ? semanticClass.color.opacity(0.22) : Color.white.opacity(0.04)), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isVisible ? semanticClass.color.opacity(0.9) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { !exportItems.isEmpty },
            set: { isPresented in
                if !isPresented {
                    exportItems = []
                }
            }
        )
    }
}

private struct GeoTrackingDemoView: View {
    @StateObject private var viewModel = ARGeoTrackingViewModel()
    @State private var exportItems: [URL] = []
    @State private var isPreparingExport = false

    var body: some View {
        VStack(spacing: 10) {
            actionRow
                .padding(.horizontal, 12)

            ARGeoTrackingViewContainer(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.02, green: 0.03, blue: 0.04))
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: exportSheetBinding) {
            ActivityViewController(items: exportItems.map { $0 as Any })
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Reset Sensors") {
                viewModel.resetTracking()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Export Logs") {
                guard !isPreparingExport else { return }
                isPreparingExport = true
                Task {
                    let archiveURL = await viewModel.makeExportArchive()
                    await MainActor.run {
                        isPreparingExport = false
                        if let archiveURL {
                            exportItems = [archiveURL]
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isPreparingExport)

            Text(viewModel.sensorStateText)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { !exportItems.isEmpty },
            set: { isPresented in
                if !isPresented {
                    exportItems = []
                }
            }
        )
    }
}

#Preview {
    ContentView()
}
