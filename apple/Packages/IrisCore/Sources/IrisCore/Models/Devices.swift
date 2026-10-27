import Foundation

/// A tri-state for a nullable, optional request field: leave the server value alone, clear it (`null`),
/// or set it.
public enum FieldUpdate<Value: Codable & Hashable & Sendable>: Hashable, Sendable {
  case unchanged
  case clear
  case set(Value)
}

public struct RegisterDeviceRequest: Codable, Hashable, Sendable {
  public var name: String
  public var platform: DevicePlatform
  public var apnsToken: FieldUpdate<String>
  public var apnsEnv: FieldUpdate<APNsEnvironment>
  public var pushToStartToken: FieldUpdate<String>

  public init(
    name: String,
    platform: DevicePlatform,
    apnsToken: FieldUpdate<String> = .unchanged,
    apnsEnv: FieldUpdate<APNsEnvironment> = .unchanged,
    pushToStartToken: FieldUpdate<String> = .unchanged
  ) {
    self.name = name
    self.platform = platform
    self.apnsToken = apnsToken
    self.apnsEnv = apnsEnv
    self.pushToStartToken = pushToStartToken
  }

  private enum CodingKeys: String, CodingKey {
    case name, platform, apnsToken, apnsEnv, pushToStartToken
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    platform = try container.decode(DevicePlatform.self, forKey: .platform)
    apnsToken = try container.decodeUpdate(String.self, forKey: .apnsToken)
    apnsEnv = try container.decodeUpdate(APNsEnvironment.self, forKey: .apnsEnv)
    pushToStartToken = try container.decodeUpdate(String.self, forKey: .pushToStartToken)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(platform, forKey: .platform)
    try container.encodeUpdate(apnsToken, forKey: .apnsToken)
    try container.encodeUpdate(apnsEnv, forKey: .apnsEnv)
    try container.encodeUpdate(pushToStartToken, forKey: .pushToStartToken)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeUpdate<Value: Codable & Hashable & Sendable>(
    _ type: Value.Type, forKey key: Key
  ) throws -> FieldUpdate<Value> {
    guard contains(key) else { return .unchanged }
    if try decodeNil(forKey: key) { return .clear }
    return .set(try decode(type, forKey: key))
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeUpdate<Value: Codable & Hashable & Sendable>(
    _ update: FieldUpdate<Value>, forKey key: Key
  ) throws {
    switch update {
    case .unchanged: break
    case .clear: try encodeNil(forKey: key)
    case .set(let value): try encode(value, forKey: key)
    }
  }
}

public struct RegisterDeviceResponse: Codable, Hashable, Sendable {
  public var device: String
  public var name: String
  public var platform: DevicePlatform
  public var apnsEnv: APNsEnvironment?
  public var hasApnsToken: Bool
  public var hasPushToStartToken: Bool
  public var registeredAt: Date

  public init(
    device: String,
    name: String,
    platform: DevicePlatform,
    apnsEnv: APNsEnvironment? = nil,
    hasApnsToken: Bool,
    hasPushToStartToken: Bool,
    registeredAt: Date
  ) {
    self.device = device
    self.name = name
    self.platform = platform
    self.apnsEnv = apnsEnv
    self.hasApnsToken = hasApnsToken
    self.hasPushToStartToken = hasPushToStartToken
    self.registeredAt = registeredAt
  }

  private enum CodingKeys: String, CodingKey {
    case device, name, platform, apnsEnv, hasApnsToken, hasPushToStartToken, registeredAt
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(device, forKey: .device)
    try container.encode(name, forKey: .name)
    try container.encode(platform, forKey: .platform)
    try container.encode(apnsEnv, forKey: .apnsEnv)
    try container.encode(hasApnsToken, forKey: .hasApnsToken)
    try container.encode(hasPushToStartToken, forKey: .hasPushToStartToken)
    try container.encode(registeredAt, forKey: .registeredAt)
  }
}
