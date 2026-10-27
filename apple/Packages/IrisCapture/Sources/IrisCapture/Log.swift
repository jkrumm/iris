import os

enum Log {
  static let subsystem = "com.jkrumm.iris"
  static let capture = Logger(subsystem: subsystem, category: "capture")
  static let outbox = Logger(subsystem: subsystem, category: "outbox")
}
