import Foundation

/// Writes a short launch/runtime trace next to the app's preferences so problems
/// are diagnosable without a console attached.
enum Diag {
    static let path = NSString(string: "~/Library/Logs/murmur.log").expandingTildeInPath

    static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSLog("[murmur] %@", msg)
    }
}
