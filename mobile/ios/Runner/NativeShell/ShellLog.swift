import Foundation

enum ShellLog {
  private static let queue = DispatchQueue(label: "shell.log")
  private static let handle: FileHandle? = {
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }
    let url = dir.appendingPathComponent("shell.log")
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
      try? handle.synchronize()
    }
  }
}

func shellLog(_ format: String, _ args: CVarArg...) {
  ShellLog.write(String(format: format, arguments: args))
}
