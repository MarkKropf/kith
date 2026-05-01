// Vendored from https://github.com/steipete/imsg (MIT)
// Original copyright © Peter Steinberger. See THIRD_PARTY_NOTICES.md.
// Do not edit in-place; see scripts/vendor-sync.sh for upstream syncs.
import Foundation

enum AttachmentResolver {
  static func resolve(_ path: String) -> (resolved: String, missing: Bool) {
    guard !path.isEmpty else { return ("", true) }
    let expanded = (path as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
    return (expanded, !(exists && !isDir.boolValue))
  }

  static func displayName(filename: String, transferName: String) -> String {
    if !transferName.isEmpty { return transferName }
    if !filename.isEmpty { return filename }
    return "(unknown)"
  }
}
