import Foundation

/// Diagnostics that survive not having a console attached.
///
/// `devicectl --console` needs the phone unlocked and awake at the moment of
/// the launch, and it drops its own connection; a reproduction that depends on
/// someone using the app at a particular time cannot rely on it. Writing to the
/// app container instead means the session happens whenever it happens and the
/// file is pulled afterwards with
/// `devicectl device copy from --domain-type appDataContainer`.
///
/// Still NSLogs, so an attached console shows the same lines.
enum ShellLog {
  private static let queue = DispatchQueue(label: "shell.log")
  private static let handle: FileHandle? = {
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }
    let url = dir.appendingPathComponent("shell.log")
    // Truncated per launch: the interesting window is always the current run,
    // and an unbounded file on someone's phone is rude.
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
  }()

  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  static func write(_ message: String) {
    NSLog("%@", message)
    queue.async {
      guard let handle, let data = "\(stamp.string(from: Date())) \(message)\n".data(using: .utf8) else {
        return
      }
      try? handle.write(contentsOf: data)
      // Flushed per line: the run being diagnosed is usually the one that ends
      // with the app being killed, and a buffered tail would lose exactly it.
      try? handle.synchronize()
    }
  }
}

/// `NSLog`-shaped, so existing call sites move across unchanged.
func shellLog(_ format: String, _ args: CVarArg...) {
  ShellLog.write(String(format: format, arguments: args))
}
