import SwiftUI
import GoogleMaps
import GoogleNavigation

/// Shared registration, without starting a navigation session, GPS or a map.
@MainActor
enum GoogleMapsBootstrap {
    private static var configured = false
    static func configure(apiKey: String) -> Bool {
        if configured { return true }
        GMSNavigationServices.setAbnormalTerminationReportingEnabled(false)
        configured = GMSServices.provideAPIKey(apiKey)
        return configured
    }
}

struct GoogleRouteOverview: View {
    let stops: [RouteStop]
    let driverLocation: Coordinate?
    private var apiKey: String? { GoogleNavigationConfiguration(info: Bundle.main.infoDictionary ?? [:]).apiKey }
    private var testing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitesting")
        #else
        false
        #endif
    }
    var body: some View {
        if testing {
            #if DEBUG
            TestRouteDiagram(stops: stops)
            #endif
        } else if let apiKey {
            GoogleStopPins(stops: stops, driverLocation: driverLocation, apiKey: apiKey)
        } else {
            Text("Mappa Google non ancora configurata. Le tappe restano disponibili nell’elenco.")
                .font(.subheadline).foregroundStyle(.secondary).padding()
        }
    }
}

/// Google-source points are never drawn on Apple maps. No OSRM route geometry is drawn here.
private struct GoogleStopPins: UIViewRepresentable {
    let stops: [RouteStop]
    let driverLocation: Coordinate?
    let apiKey: String
    func makeUIView(context: Context) -> UIView {
        guard GoogleMapsBootstrap.configure(apiKey: apiKey) else { return UIView() }
        let map = GMSMapView(options: GMSMapViewOptions())
        map.isMyLocationEnabled = false
        map.settings.myLocationButton = false
        return map
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard let map = view as? GMSMapView else { return }
        map.clear()
        var coordinates: [Coordinate] = []
        for (index, stop) in stops.enumerated() {
            guard stop.googlePlaceId != nil, let coordinate = stop.displayCoordinate(), coordinate.isValid else { continue }
            coordinates.append(coordinate)
            let marker = GMSMarker(position: coordinate.clCoordinate)
            marker.title = "\(index + 1). \(stop.title)"
            marker.map = map
        }
        if let driverLocation, driverLocation.isValid {
            coordinates.append(driverLocation)
            let marker = GMSMarker(position: driverLocation.clCoordinate)
            marker.title = "Corriere"
            marker.icon = GMSMarker.markerImage(with: .systemBlue)
            marker.map = map
        }
        if let first = coordinates.first {
            var bounds = GMSCoordinateBounds(coordinate: first.clCoordinate, coordinate: first.clCoordinate)
            for coordinate in coordinates.dropFirst() { bounds = bounds.includingCoordinate(coordinate.clCoordinate) }
            if coordinates.count == 1 { map.camera = GMSCameraPosition(target: first.clCoordinate, zoom: 15) }
            else { map.moveCamera(GMSCameraUpdate.fit(bounds, withPadding: 40)) }
        }
    }
}

#if DEBUG
/// A labelled, schematic stop order for screenshots. No map tiles, geography or SDK requests.
private struct TestRouteDiagram: View {
    let stops: [RouteStop]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Schema tappe · TEST", systemImage: "testtube.2")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityIdentifier("route_map_test_mode")
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(stops.prefix(4).enumerated()), id: \.element.id) { index, stop in
                    VStack(spacing: 8) {
                        Text("\(index + 1)").font(.headline)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.white)
                            .background(stop.kind == .pickup ? Color.orange : Color.green, in: Circle())
                        Text(stop.title).font(.caption.weight(.semibold))
                        Text(stop.address).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity)
                }
            }
            if stops.count > 4 { Text("Altre \(stops.count - 4) tappe nell’elenco").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground))
    }
}
#endif
