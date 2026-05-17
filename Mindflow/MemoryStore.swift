//
//  MemoryStore.swift
//  Mindflow — append-only JSONL log of every memory saved. Lives at
//  ~/Library/Application Support/Mindflow/memories.jsonl. Loaded once on init,
//  appended in-process + to disk on each save. @Observable so the dashboard
//  list updates the moment MindflowSaver appends a new record.
//

import Foundation
import Observation

@Observable
final class MemoryStore {
    private(set) var memories: [MemoryRecord] = []
    /// Transient per-memory enrichment state. Absent = idle/done. Drives the
    /// "Processing…" pill in the sidebar row while topic extraction + concept
    /// upserts run in the background. Cleared on completion (or failure).
    private(set) var enrichmentStatus: [UUID: EnrichmentStatus] = [:]
    private let logURL: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Mindflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logURL = dir.appendingPathComponent("memories.jsonl")
        loadAll()
        print("[MemoryStore] loaded \(memories.count) memories from \(logURL.path)")
    }

    func append(_ record: MemoryRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0A) // newline

        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: logURL)
        }

        memories.insert(record, at: 0)
    }

    func setEnrichmentStatus(_ status: EnrichmentStatus?, for id: UUID) {
        if let status {
            enrichmentStatus[id] = status
        } else {
            enrichmentStatus.removeValue(forKey: id)
        }
    }

    private func loadAll() {
        guard FileManager.default.fileExists(atPath: logURL.path),
              let data = try? Data(contentsOf: logURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [MemoryRecord] = []
        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty,
                  let record = try? decoder.decode(MemoryRecord.self, from: Data(line)) else {
                continue
            }
            loaded.append(record)
        }
        memories = loaded.reversed()
    }
}
