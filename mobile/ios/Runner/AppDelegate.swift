import Flutter
import MapKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlaceSearchPlugin") {
      PlaceSearchPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleMapPlugin") {
      registrar.register(AppleMapFactory(messenger: registrar.messenger()), withId: "equipay/apple-map")
    }
  }
}

/// Recherche de lieux d'Apple Plans (écoles, restaurants, monuments… et adresses) pour le programme.
/// Canal « equipay/places », méthode « search » : { query } → [{ name, address, latitude, longitude }].
class PlaceSearchPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "equipay/places", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PlaceSearchPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "openDirections" {
      openDirections(call.arguments as? [String: Any] ?? [:], result: result)
      return
    }
    guard call.method == "search",
          let args = call.arguments as? [String: Any],
          let query = args["query"] as? String,
          !query.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    MKLocalSearch(request: request).start { response, _ in
      // Rien trouvé ou hors ligne : liste vide, l'app essaie alors le géocodage d'adresse
      let places = (response?.mapItems ?? []).prefix(5).map { item -> [String: Any] in
        let coordinate = item.placemark.coordinate
        return [
          "name": item.name ?? "",
          "address": item.placemark.title ?? "",
          "latitude": coordinate.latitude,
          "longitude": coordinate.longitude,
        ]
      }
      result(Array(places))
    }
  }
}

extension PlaceSearchPlugin {
  /// Ouvre l'app Plans avec l'itinéraire du jour : départ au 1er lieu, étapes dans l'ordre, arrivée au dernier.
  /// { stops: [[lat, lng, nom]], mode: walking | cycling | driving } → true si Plans s'est ouvert.
  func openDirections(_ args: [String: Any], result: @escaping FlutterResult) {
    let stops = (args["stops"] as? [[Any]] ?? []).compactMap { s -> (CLLocationCoordinate2D, String)? in
      guard s.count >= 2, let lat = s[0] as? Double, let lng = s[1] as? Double else { return nil }
      return (CLLocationCoordinate2D(latitude: lat, longitude: lng), s.count > 2 ? (s[2] as? String ?? "") : "")
    }
    let mode = args["mode"] as? String ?? "walking"
    guard let first = stops.first, let last = stops.last else {
      result(false)
      return
    }
    func point(_ c: CLLocationCoordinate2D) -> String { String(format: "%.6f,%.6f", c.latitude, c.longitude) }
    // Adresse Apple Plans (iOS 18.4+) : un itinéraire à plusieurs étapes, « waypoint » répété dans l'ordre
    var url = URLComponents(string: "https://maps.apple.com/directions")!
    var query = [URLQueryItem(name: "source", value: point(first.0))]
    if stops.count > 2 {
      query += stops.dropFirst().dropLast().map { URLQueryItem(name: "waypoint", value: point($0.0)) }
    }
    query += [URLQueryItem(name: "destination", value: point(last.0)), URLQueryItem(name: "mode", value: mode)]
    url.queryItems = query
    guard let link = url.url else {
      result(false)
      return
    }
    UIApplication.shared.open(link) { opened in
      if opened {
        result(true)
        return
      }
      // Secours (ancien iOS) : Plans avec les lieux, itinéraire du premier au dernier
      let items = stops.map { stop -> MKMapItem in
        let item = MKMapItem(placemark: MKPlacemark(coordinate: stop.0))
        item.name = stop.1
        return item
      }
      let directions = mode == "driving" ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking
      result(MKMapItem.openMaps(with: items, launchOptions: [MKLaunchOptionsDirectionsModeKey: directions]))
    }
  }
}

// MARK: - Carte Apple Plans (programme des voyages)

/// Fabrique de la vue native « equipay/apple-map » affichée dans Flutter.
class AppleMapFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AppleMapView(frame: frame, viewId: viewId, messenger: messenger, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Un repère du programme : numéro dans la bulle, couleur selon les votes.
class PinAnnotation: MKPointAnnotation {
  var pinId = ""
  var label = ""
  var color = UIColor.systemGray
  var faded = false
}

/// Carte Apple Plans (MapKit) avec les repères du programme.
/// Canal « equipay/apple-map/<id> » : « setPins » (Flutter → iOS : repères et itinéraire éventuel),
/// « tap » (iOS → Flutter, id du repère).
class AppleMapView: NSObject, FlutterPlatformView, MKMapViewDelegate {
  private let map: MKMapView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
    map = MKMapView(frame: frame)
    channel = FlutterMethodChannel(name: "equipay/apple-map/\(viewId)", binaryMessenger: messenger)
    super.init()
    map.delegate = self
    map.showsCompass = true
    map.showsScale = true
    map.pointOfInterestFilter = .includingAll
    map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setPins", let args = call.arguments as? [String: Any] {
        self?.update(args, animated: true)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    if let args = args as? [String: Any] {
      update(args, animated: false)
    }
  }

  private var routeRequest = 0

  private func update(_ args: [String: Any], animated: Bool) {
    setPins(args["pins"] as? [[String: Any]] ?? [], animated: animated)
    map.removeOverlays(map.overlays)
    routeRequest += 1
    if let route = args["route"] as? [String: Any], let points = route["points"] as? [[Double]], points.count > 1 {
      drawRoute(points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) },
                walking: (route["mode"] as? String) != "driving", request: routeRequest)
    }
  }

  /// Itinéraire dans les rues entre les étapes successives (Apple Plans) ; ligne droite si introuvable.
  private func drawRoute(_ points: [CLLocationCoordinate2D], walking: Bool, request: Int) {
    for (from, to) in zip(points, points.dropFirst()) {
      let directions = MKDirections.Request()
      directions.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
      directions.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
      directions.transportType = walking ? .walking : .automobile
      MKDirections(request: directions).calculate { [weak self] response, _ in
        // Un nouveau filtre a été choisi entre-temps : on ignore l'ancien tracé
        guard let self = self, request == self.routeRequest else { return }
        let line = response?.routes.first?.polyline ?? MKPolyline(coordinates: [from, to], count: 2)
        self.map.addOverlay(line, level: .aboveRoads)
      }
    }
  }

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
    let renderer = MKPolylineRenderer(polyline: line)
    renderer.strokeColor = UIColor(red: 0.05, green: 0.58, blue: 0.53, alpha: 0.9)  // couleur principale d'EquiPay
    renderer.lineWidth = 5
    renderer.lineCap = .round
    renderer.lineJoin = .round
    return renderer
  }

  func view() -> UIView { map }

  private func setPins(_ pins: [[String: Any]], animated: Bool) {
    map.removeAnnotations(map.annotations)
    let annotations = pins.compactMap { p -> PinAnnotation? in
      guard let lat = p["latitude"] as? Double, let lng = p["longitude"] as? Double else { return nil }
      let a = PinAnnotation()
      a.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
      a.pinId = p["id"] as? String ?? ""
      a.label = p["label"] as? String ?? ""
      a.title = p["title"] as? String
      a.subtitle = p["subtitle"] as? String
      if let argb = p["color"] as? Int { a.color = UIColor(argb: argb) }
      a.faded = p["faded"] as? Bool ?? false
      return a
    }
    map.addAnnotations(annotations)
    // À la création la carte n'a pas encore sa taille : on cadre au cycle suivant
    DispatchQueue.main.async { [weak self] in self?.fit(annotations, animated: animated) }
  }

  /// Cadre la carte sur tous les repères (un seul : vue de quartier).
  private func fit(_ annotations: [PinAnnotation], animated: Bool) {
    guard let first = annotations.first else { return }
    if annotations.count == 1 {
      let region = MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200)
      map.setRegion(region, animated: animated)
      return
    }
    var rect = MKMapRect.null
    for a in annotations {
      let point = MKMapPoint(a.coordinate)
      rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0.1, height: 0.1))
    }
    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 50, bottom: 50, right: 50), animated: animated)
  }

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    guard let pin = annotation as? PinAnnotation else { return nil }
    let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: pin) as! MKMarkerAnnotationView
    view.markerTintColor = pin.color
    view.glyphText = pin.label
    view.alpha = pin.faded ? 0.5 : 1
    view.displayPriority = .required  // jamais masqué ni regroupé : chaque étape du programme reste visible
    view.titleVisibility = .adaptive
    return view
  }

  func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
    guard let pin = view.annotation as? PinAnnotation else { return }
    channel.invokeMethod("tap", arguments: pin.pinId)
    mapView.deselectAnnotation(pin, animated: false)
  }
}

extension UIColor {
  /// Couleur Flutter (0xAARRGGBB).
  convenience init(argb: Int) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }
}
