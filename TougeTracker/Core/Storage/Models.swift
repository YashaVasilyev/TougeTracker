import Foundation
import SwiftData
import CoreLocation
import Observation
import MapKit

// MARK: - Telemetry sample + codecs

/// A single fused telemetry sample. Fixed-layout (trivial POD) so it can be
/// packed/unpacked as raw bytes for compact on-disk storage.
public struct TelemetrySample: Sendable, Equatable {
    public var t: Double          // seconds since drive start
    public var lat: Double
    public var lon: Double
    public var speed: Float       // m/s (GPS; 0 when unavailable)
    public var course: Float      // degrees true (0–360; 0 when unavailable)
    public var altitude: Float    // meters
    public var forwardG: Float    // + accelerating, − braking
    public var lateralG: Float    // + right turn
    public var yawRate: Float     // rad/s, + right turn

    public init(t: Double, lat: Double, lon: Double, speed: Float, course: Float,
                altitude: Float, forwardG: Float, lateralG: Float, yawRate: Float) {
        self.t = t; self.lat = lat; self.lon = lon; self.speed = speed
        self.course = course; self.altitude = altitude; self.forwardG = forwardG
        self.lateralG = lateralG; self.yawRate = yawRate
    }
}

public enum TelemetryCodec {
    public static func pack(_ samples: [TelemetrySample]) -> Data {
        if samples.isEmpty { return Data() }
        return samples.withUnsafeBytes { Data($0) }
    }

    public static func unpack(_ data: Data) -> [TelemetrySample] {
        guard !data.isEmpty else { return [] }
        let stride = MemoryLayout<TelemetrySample>.stride
        let count = data.count / stride
        // `loadUnaligned`, not `load`: the Data's base pointer carries no
        // alignment guarantee (SwiftData blobs are not allocated aligned), and
        // `load` traps when handed a misaligned address.
        return data.withUnsafeBytes { raw in
            (0 ..< count).map {
                raw.loadUnaligned(fromByteOffset: $0 * stride, as: TelemetrySample.self)
            }
        }
    }
}

/// Packs/unpacks `[GeoPoint]` as raw `Float64` lon/lat pairs (matches Tougefinder's
/// interleaved coordinate arrays).
public enum CoordinateCodec {
    public static func pack(_ points: [GeoPoint]) -> Data {
        if points.isEmpty { return Data() }
        return points.withUnsafeBytes { Data($0) }
    }

    public static func unpack(_ data: Data) -> [GeoPoint] {
        guard !data.isEmpty else { return [] }
        let stride = MemoryLayout<GeoPoint>.stride
        let count = data.count / stride
        // See TelemetryCodec.unpack — unaligned load is required here.
        return data.withUnsafeBytes { raw in
            (0 ..< count).map {
                raw.loadUnaligned(fromByteOffset: $0 * stride, as: GeoPoint.self)
            }
        }
    }
}

// MARK: - SwiftData models

@Model
public final class SavedRoute: Identifiable {
    @Attribute(.unique) public var id: Int64        // Tougefinder road id
    public var name: String
    public var type: String
    public var totalScore: Int
    public var curvatureScore: Int
    public var lengthMeters: Double
    public var centerLat: Double
    public var centerLon: Double
    public var createdAt: Date
    public var coordinatesData: Data              // packed GeoPoint
    public var pacenotesData: Data                // JSON-encoded [Pacenote]
    public var pacenotesText: String              // rally-format preview

    public init(id: Int64, name: String, type: String, totalScore: Int, curvatureScore: Int,
                lengthMeters: Double, centerLat: Double, centerLon: Double,
                createdAt: Date = Date(),
                coordinates: [GeoPoint], pacenotes: [Pacenote], pacenotesText: String) {
        self.id = id
        self.name = name
        self.type = type
        self.totalScore = totalScore
        self.curvatureScore = curvatureScore
        self.lengthMeters = lengthMeters
        self.centerLat = centerLat
        self.centerLon = centerLon
        self.createdAt = createdAt
        self.coordinatesData = CoordinateCodec.pack(coordinates)
        self.pacenotesData = (try? JSONEncoder().encode(pacenotes)) ?? Data()
        self.pacenotesText = pacenotesText
    }

    public var coordinates: [GeoPoint] { CoordinateCodec.unpack(coordinatesData) }
    public var pacenotes: [Pacenote] {
        (try? JSONDecoder().decode([Pacenote].self, from: pacenotesData)) ?? []
    }
}

@Model
public final class Drive: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var routeName: String?
    public var routeID: Int64?
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var maxSpeed: Double        // m/s
    public var maxLateralG: Double     // + right magnitude
    public var maxForwardG: Double     // + accel magnitude
    public var maxBrakeG: Double       // + braking magnitude
    public var telemetryData: Data

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date,
                routeName: String?, routeID: Int64?, distanceMeters: Double,
                durationSeconds: Double, maxSpeed: Double, maxLateralG: Double,
                maxForwardG: Double, maxBrakeG: Double, samples: [TelemetrySample]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.routeName = routeName
        self.routeID = routeID
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.maxSpeed = maxSpeed
        self.maxLateralG = maxLateralG
        self.maxForwardG = maxForwardG
        self.maxBrakeG = maxBrakeG
        self.telemetryData = TelemetryCodec.pack(samples)
    }

    public var samples: [TelemetrySample] { TelemetryCodec.unpack(telemetryData) }
    public var sampleCount: Int { samples.count }

    public var summaryText: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return "\(f.string(from: startedAt)) · \(Int(durationSeconds))s · "
             + String(format: "%.1f", distanceMeters) + "m"
    }
}

@Model
public final class RouteTile: Identifiable {
    @Attribute(.unique) public var key: String
    public var fetchedAt: Date
    public var roadsData: Data

    public init(key: String, fetchedAt: Date = Date(), roadsData: Data) {
        self.key = key
        self.fetchedAt = fetchedAt
        self.roadsData = roadsData
    }

    public var roads: [TougeRoad] {
        (try? JSONDecoder().decode([TougeRoad].self, from: roadsData)) ?? []
    }
}

// MARK: - Route store (SwiftData persistence + tile cache)

@MainActor
@Observable
public final class RouteStore {
    private var context: ModelContext

    public init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    public func routes() -> [SavedRoute] {
        (try? context.fetch(FetchDescriptor<SavedRoute>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
    }

    public func drives() -> [Drive] {
        (try? context.fetch(FetchDescriptor<Drive>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))) ?? []
    }

    public func isSaved(id: Int64) -> Bool {
        let pred: Predicate<SavedRoute> = #Predicate { $0.id == id }
        return ((try? context.fetch(FetchDescriptor<SavedRoute>(predicate: pred)))?.isEmpty) == false
    }

    /// Saves (or updates) a road as a `SavedRoute`. Upserts on the unique
    /// `id`: a plain re-insert would trip the unique constraint, and because
    /// the error is swallowed by `try?` it would leave a duplicate object
    /// stranded in the context.
    public func saveRoute(_ road: TougeRoad) -> SavedRoute {
        let coords = road.geoPoints
        let result = PacenoteGenerator.generate(coords)

        if let existing = route(id: road.id) {
            existing.name = road.displayName
            existing.type = road.type ?? ""
            existing.totalScore = road.totalScore ?? 0
            existing.curvatureScore = road.curvatureScore ?? 0
            existing.lengthMeters = road.lengthMeters
            existing.centerLat = road.centerLat ?? 0
            existing.centerLon = road.centerLon ?? 0
            existing.coordinatesData = CoordinateCodec.pack(coords)
            existing.pacenotesData = (try? JSONEncoder().encode(result.turns)) ?? Data()
            existing.pacenotesText = result.text
            try? context.save()
            return existing
        }

        let route = SavedRoute(
            id: road.id, name: road.displayName, type: road.type ?? "",
            totalScore: road.totalScore ?? 0, curvatureScore: road.curvatureScore ?? 0,
            lengthMeters: road.lengthMeters, centerLat: road.centerLat ?? 0, centerLon: road.centerLon ?? 0,
            coordinates: coords, pacenotes: result.turns, pacenotesText: result.text)
        context.insert(route)
        try? context.save()
        return route
    }

    public func route(id: Int64) -> SavedRoute? {
        let pred: Predicate<SavedRoute> = #Predicate { $0.id == id }
        return (try? context.fetch(FetchDescriptor<SavedRoute>(predicate: pred)))?.first
    }

    public func deleteRoute(_ route: SavedRoute) {
        context.delete(route)
        try? context.save()
    }

    public func addDrive(_ drive: Drive) {
        context.insert(drive)
        try? context.save()
    }

    // Tile cache keyed by a 0.25° grid.
    public func cachedRoads(lat: Double, lon: Double) -> [TougeRoad]? {
        let key = tileKey(lat, lon)
        let pred: Predicate<RouteTile> = #Predicate { $0.key == key }
        guard let tile = try? context.fetch(FetchDescriptor<RouteTile>(predicate: pred)).first else { return nil }
        if Date().timeIntervalSince(tile.fetchedAt) < 86_400 { return tile.roads }
        return nil
    }

    public func cacheRoads(_ roads: [TougeRoad], lat: Double, lon: Double) {
        // Remove any existing tile with the same key (upsert)
        let key = tileKey(lat, lon)
        let pred: Predicate<RouteTile> = #Predicate { $0.key == key }
        if let existing = try? context.fetch(FetchDescriptor<RouteTile>(predicate: pred)).first {
            context.delete(existing)
        }
        let tile = RouteTile(key: key, roadsData: (try? JSONEncoder().encode(roads)) ?? Data())
        context.insert(tile)
        try? context.save()
    }

    private func tileKey(_ lat: Double, _ lon: Double) -> String {
        "t_\(Int(floor(lat / 0.25)))_\(Int(floor(lon / 0.25)))"
    }

    // MARK: - Local road source

    /// Loads roads from the bundled tile files, checking the on-disk cache
    /// first. Mirrors Tougefinder's tile-cache fallback: local DB is primary,
    /// everything else is empty.
    public func localRoads(lat: Double, lon: Double) async throws -> [TougeRoad] {
        if let cached = cachedRoads(lat: lat, lon: lon) {
            return cached
        }
        let roads = try await LocalRoadSource.shared.fetchRoads(lat: lat, lon: lon)
        if !roads.isEmpty {
            cacheRoads(roads, lat: lat, lon: lon)
        }
        return roads
    }

    /// Loads roads intersecting a bounding box from the bundled tiles,
    /// checking the cache per-tile.
    public func localRoads(in region: MKCoordinateRegion) async throws -> [TougeRoad] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        let tileSize = 0.25
        let minTileLat = Int(floor(minLat / tileSize))
        let maxTileLat = Int(floor(maxLat / tileSize))
        let minTileLon = Int(floor(minLon / tileSize))
        let maxTileLon = Int(floor(maxLon / tileSize))

        var results: [TougeRoad] = []
        for tileLat in minTileLat...maxTileLat {
            for tileLon in minTileLon...maxTileLon {
                let tileLatCenter = Double(tileLat) * tileSize + tileSize / 2
                let tileLonCenter = Double(tileLon) * tileSize + tileSize / 2
                let roads = try await localRoads(lat: tileLatCenter, lon: tileLonCenter)
                let filtered = roads.filter { road in
                    guard let cla = road.centerLat, let clon = road.centerLon else { return false }
                    return cla >= minLat && cla <= maxLat &&
                           clon >= minLon && clon <= maxLon
                }
                results.append(contentsOf: filtered)
            }
        }
        return results
    }
}
