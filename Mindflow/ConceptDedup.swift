//
//  ConceptDedup.swift
//  Mindflow — concept slug resolution.
//
//  v1: just slugify. Sonnet tends to use consistent terminology across captures, so
//  the same concept ("rate limiting") usually produces the same slug both times,
//  giving us automatic same-slug dedup at the storage layer (gbrain put overwrites).
//
//  True semantic dedup (catching synonyms like "rate limiting" vs "request throttling")
//  is a v1.x feature — needs gbrain embeddings + a score threshold.
//

import Foundation

@MainActor
final class ConceptDedup {
    func resolve(concepts: [String]) async -> [String] {
        concepts.map { AnchorPath.sanitize($0) }
    }
}
