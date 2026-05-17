//
//  GbrainSaver.swift
//  Mindflow — compose markdown + shell out `gbrain put <path>` with the body on stdin.
//

import Foundation

enum GbrainSaverError: Error {
    case putFailed(Int, String)
}

@MainActor
final class GbrainSaver {
    private let gbrainPath: String

    init(gbrainPath: String = "/Users/keefeho/.bun/bin/gbrain") {
        self.gbrainPath = gbrainPath
    }

    func save(
        path: String,
        transcript: String,
        conceptSlugs: [String],
        anchorType: AnchorType
    ) async throws {
        let body = buildMarkdown(
            transcript: transcript,
            conceptSlugs: conceptSlugs,
            anchorType: anchorType
        )
        try await putRaw(path: path, body: body)
    }

    /// Shell `gbrain put <path>` with `body` on stdin. Used directly when the
    /// caller already composed a full markdown page (frontmatter + content).
    func putRaw(path: String, body: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gbrainPath)
        process.arguments = ["put", path]

        // gbrain is a Bun .ts script (#!/usr/bin/env bun) — child needs PATH that finds `bun`.
        // Cover common install locations: Homebrew (Apple Silicon + Intel) + Bun installer default.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.bun/bin",
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(extraPaths.joined(separator: ":")):\(existingPath)"
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        stdin.fileHandleForWriting.write(body.data(using: .utf8) ?? Data())
        try? stdin.fileHandleForWriting.close()

        await Task.detached {
            process.waitUntilExit()
        }.value

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw GbrainSaverError.putFailed(Int(process.terminationStatus), errText)
        }
    }

    private func buildMarkdown(
        transcript: String,
        conceptSlugs: [String],
        anchorType: AnchorType
    ) -> String {
        let wikilinks = conceptSlugs
            .map { "[[concepts/\($0)]]" }
            .joined(separator: " ")
        let isoDate = ISO8601DateFormatter().string(from: Date())

        return """
        ---
        anchor-type: \(anchorType.rawValue)
        captured-at: \(isoDate)
        captured-by: Brainiac
        ---
        # Voice note

        \(transcript.isEmpty ? "_(empty)_" : transcript)

        ## Concepts

        \(wikilinks)
        """
    }
}
