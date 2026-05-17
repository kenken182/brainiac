//
//  Models.swift
//  Mindflow — shared data types for the save pipeline.
//

import Foundation

enum AnchorType: String, Codable {
    case linkedin
    case email
    case article
    case other
}

struct VisionResult: Codable {
    let anchorType: AnchorType
    let slug: String
    let concepts: [String]

    enum CodingKeys: String, CodingKey {
        case anchorType = "anchor_type"
        case slug
        case concepts
    }
}
