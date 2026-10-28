import Foundation

/// The split of a reply, kept by its text: a thread re-renders often and a reply never changes, so it is cut once.
/// Main actor only (views build it); `NSCache` is not `Sendable`.
@MainActor
enum MessageBlockCache {
  private final class Entry {
    let blocks: [MessageBlock]
    init(_ blocks: [MessageBlock]) { self.blocks = blocks }
  }

  private static let cache: NSCache<NSString, Entry> = {
    let cache = NSCache<NSString, Entry>()
    cache.countLimit = 64
    return cache
  }()

  static func blocks(for markdown: String) -> [MessageBlock] {
    let key = markdown as NSString
    if let entry = cache.object(forKey: key) { return entry.blocks }
    let blocks = MessageBlock.split(markdown)
    cache.setObject(Entry(blocks), forKey: key)
    return blocks
  }
}
