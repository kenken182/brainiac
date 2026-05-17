//
//  ScreenshotStore.swift
//  Mindflow — persists captured PNGs to ~/Library/Application Support/Mindflow/screenshots/.
//  Files are keyed by the MemoryRecord's UUID so the dashboard can resolve them
//  back from a record without storing absolute paths everywhere.
//

import Foundation

final class ScreenshotStore {
    private let directory: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Mindflow", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    @discardableResult
    func save(_ pngData: Data, forID id: UUID) throws -> URL {
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        try pngData.write(to: url)
        return url
    }

    func url(forID id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }
}
