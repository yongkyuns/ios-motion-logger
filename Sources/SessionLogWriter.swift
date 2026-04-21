import Foundation

struct SessionLogFileDefinition: Sendable {
    let name: String
    let header: String?
}

actor SessionLogWriter {
    nonisolated let sessionDirectoryURL: URL
    nonisolated let fileURLs: [URL]

    private var handlesByName: [String: FileHandle] = [:]

    init(prefix: String, files: [SessionLogFileDefinition]) {
        let root = Self.documentsDirectory()
            .appendingPathComponent("ARLogs", isDirectory: true)
        let sessionTimestamp = makeLogTimestamp().replacingOccurrences(of: ":", with: "-")
        let sessionName = "\(prefix)-\(sessionTimestamp)"
        let sessionDirectoryURL = root.appendingPathComponent(sessionName, isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)

        var resolvedURLs: [URL] = []
        for file in files {
            let url = sessionDirectoryURL.appendingPathComponent(file.name, isDirectory: false)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if let header = file.header, let data = "\(header)\n".data(using: .utf8) {
                try? data.write(to: url, options: .atomic)
            }
            resolvedURLs.append(url)
        }

        self.sessionDirectoryURL = sessionDirectoryURL
        self.fileURLs = resolvedURLs

        for (index, file) in files.enumerated() {
            if let handle = try? FileHandle(forWritingTo: resolvedURLs[index]) {
                _ = try? handle.seekToEnd()
                handlesByName[file.name] = handle
            }
        }
    }

    func append(_ line: String, to fileName: String) {
        guard let handle = handlesByName[fileName] else { return }
        guard let data = "\(line)\n".data(using: .utf8) else { return }

        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    func close() {
        for handle in handlesByName.values {
            try? handle.close()
        }
        handlesByName.removeAll()
    }

    func makeArchive() -> URL? {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARLogExports", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let archiveURL = tempRoot
                .appendingPathComponent(sessionDirectoryURL.lastPathComponent)
                .appendingPathExtension("json")

            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }

            let fileEntries = try fileURLs.map { url -> [String: String] in
                let content = try String(contentsOf: url, encoding: .utf8)
                return [
                    "name": url.lastPathComponent,
                    "content": content
                ]
            }

            let payload: [String: Any] = [
                "session_directory": sessionDirectoryURL.lastPathComponent,
                "exported_at": makeLogTimestamp(),
                "files": fileEntries
            ]

            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: archiveURL, options: .atomic)
            return archiveURL
        } catch {
            return nil
        }
    }

    nonisolated private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
