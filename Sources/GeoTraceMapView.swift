import CoreLocation
import MapKit
import SwiftUI

struct GeoTraceMapView: UIViewRepresentable {
    var traceCoordinates: [CLLocationCoordinate2D]
    var currentLocation: CLLocation?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.showsCompass = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.pitchButtonVisibility = .hidden
        mapView.showsScale = false
        mapView.isRotateEnabled = false
        mapView.overrideUserInterfaceStyle = .dark
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(
            mapView: mapView,
            traceCoordinates: traceCoordinates,
            currentLocation: currentLocation
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let currentFixAnnotation = MKPointAnnotation()
        private var hasAddedAnnotation = false
        private var lastRenderedTraceCount = 0

        func update(
            mapView: MKMapView,
            traceCoordinates: [CLLocationCoordinate2D],
            currentLocation: CLLocation?
        ) {
            if traceCoordinates.count < lastRenderedTraceCount {
                lastRenderedTraceCount = 0
            }

            mapView.removeOverlays(mapView.overlays)

            if traceCoordinates.count >= 2 {
                let polyline = MKGeodesicPolyline(coordinates: traceCoordinates, count: traceCoordinates.count)
                mapView.addOverlay(polyline)
            }

            if let currentLocation {
                let accuracyRadius = max(currentLocation.horizontalAccuracy, 5)
                let accuracyCircle = MKCircle(center: currentLocation.coordinate, radius: accuracyRadius)
                mapView.addOverlay(accuracyCircle)

                currentFixAnnotation.coordinate = currentLocation.coordinate
                if hasAddedAnnotation {
                    UIView.animate(withDuration: 0.12) {
                        self.currentFixAnnotation.coordinate = currentLocation.coordinate
                    }
                } else {
                    hasAddedAnnotation = true
                    mapView.addAnnotation(currentFixAnnotation)
                }
            } else if hasAddedAnnotation {
                hasAddedAnnotation = false
                mapView.removeAnnotation(currentFixAnnotation)
            }

            guard !traceCoordinates.isEmpty || currentLocation != nil else { return }
            guard traceCoordinates.count != lastRenderedTraceCount else { return }

            lastRenderedTraceCount = traceCoordinates.count
            fitVisibleRegion(
                on: mapView,
                traceCoordinates: traceCoordinates,
                currentLocation: currentLocation
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.16, green: 0.84, blue: 0.74, alpha: 0.95)
                renderer.lineWidth = 4
                return renderer
            }

            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.32)
                renderer.fillColor = UIColor(red: 0.16, green: 0.84, blue: 0.74, alpha: 0.12)
                renderer.lineWidth = 1.5
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let reuseIdentifier = "CurrentFix"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) ?? MKAnnotationView(
                annotation: annotation,
                reuseIdentifier: reuseIdentifier
            )
            view.annotation = annotation
            view.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
            view.backgroundColor = .clear
            view.layer.cornerRadius = 9
            view.layer.borderWidth = 2
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.backgroundColor = UIColor(red: 0.16, green: 0.84, blue: 0.74, alpha: 0.95).cgColor
            return view
        }

        private func fitVisibleRegion(
            on mapView: MKMapView,
            traceCoordinates: [CLLocationCoordinate2D],
            currentLocation: CLLocation?
        ) {
            if traceCoordinates.count == 1, let coordinate = traceCoordinates.first {
                let region = MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 140,
                    longitudinalMeters: 140
                )
                mapView.setRegion(region, animated: true)
                return
            }

            var mapRect = MKMapRect.null

            for coordinate in traceCoordinates {
                let point = MKMapPoint(coordinate)
                let rect = MKMapRect(
                    origin: MKMapPoint(x: point.x - 20, y: point.y - 20),
                    size: MKMapSize(width: 40, height: 40)
                )
                mapRect = mapRect.union(rect)
            }

            if let currentLocation {
                let point = MKMapPoint(currentLocation.coordinate)
                let accuracy = max(currentLocation.horizontalAccuracy, 10)
                let metersPerPoint = MKMetersPerMapPointAtLatitude(currentLocation.coordinate.latitude)
                let radius = accuracy / metersPerPoint
                let rect = MKMapRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                mapRect = mapRect.union(rect)
            }

            guard !mapRect.isNull else { return }
            mapView.setVisibleMapRect(
                mapRect,
                edgePadding: UIEdgeInsets(top: 36, left: 24, bottom: 24, right: 24),
                animated: true
            )
        }
    }
}
