//
//  AnchorPath.swift
//  Mindflow — pure mapping from VisionResult → gbrain page path.
//

import Foundation

enum AnchorPath {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func path(for result: VisionResult) -> String {
        let safeSlug = sanitize(result.slug)
        switch result.anchorType {
        case .linkedin:
            return "people/\(safeSlug)"
        case .email:
            let date = dateFormatter.string(from: Date())
            return "media/email-\(safeSlug)-\(date)"
        case .article, .other:
            return "media/\(safeSlug)"
        }
    }

    static func sanitize(_ slug: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = slug.lowercased().replacingOccurrences(of: " ", with: "-")
        let filtered = lowered.filter { allowed.contains($0) }
        let collapsed = filtered.replacingOccurrences(
            of: "--+", with: "-", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
