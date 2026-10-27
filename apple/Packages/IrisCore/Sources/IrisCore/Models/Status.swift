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

/// A live herdr tab, for the Tab picker.
public struct HerdTab: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var repo: String
  public var label: String
  public var agentState: AgentState
  public var lastActivity: Date?

  public init(id: String, repo: String, label: String, agentState: AgentState, lastActivity: Date? = nil) {
    self.id = id
    self.repo = repo
    self.label = label
    self.agentState = agentState
    self.lastActivity = lastActivity
  }

  private enum CodingKeys: String, CodingKey {
    case id, repo, label, agentState, lastActivity
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(repo, forKey: .repo)
    try container.encode(label, forKey: .label)
    try container.encode(agentState, forKey: .agentState)
    try container.encode(lastActivity, forKey: .lastActivity)
  }
}

public struct Herd: Codable, Hashable, Sendable {
  public var tabs: [HerdTab]

  public init(tabs: [HerdTab]) {
    self.tabs = tabs
  }
}
