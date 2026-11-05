import Foundation

public struct Whoami: Codable, Hashable, Sendable {
  public var device: String

  public init(device: String) {
    self.device = device
  }
}

public struct Health: Codable, Hashable, Sendable {
  public var status: HealthStatus
  /// Names of the downstreams that are currently unhealthy.
  public var degraded: [String]
  public var inflight: Int

  public init(status: HealthStatus, degraded: [String], inflight: Int) {
    self.status = status
    self.degraded = degraded
    self.inflight = inflight
  }
}
