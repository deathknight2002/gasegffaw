//
//  RitualTextProvider.swift
//  Bornless Ritual — ritual text lookup (ARCHITECTURE §10 "Ritual text": the HUD shows
//  the current stage's lines in the selected edition; docs/SOURCES.md §4a for the beat
//  names; Resources/RitualText.json schema: editions{goodwin1852,samekh1930} +
//  stages[] {id,title,element,quarter,lines{edition:[String]},barbarousNames[],
//  barbarousNamesGoodwin[]} + notes).
//
//  Role: loads RitualText.json once from the app bundle (a missing or malformed file is
//  tolerated — every lookup then falls back to RitualCore's stage titles and
//  `RhythmSpec.names`), maps `RitualStage` onto the JSON stage ids (the file uses the
//  1929 section names "opening", "climax" and "closing" for oath, sigilSpin and
//  manifestation) and answers the HUD's questions: title, lines, barbarous names and
//  the six Spirit beat names for an edition. Immutable after init, so it is `Sendable`
//  and may be read from any thread.
//

import Foundation
import RitualCore

// MARK: - JSON schema

/// Provenance record of one edition (`editions.<key>` in RitualText.json).
struct RitualTextEditionInfo: Decodable, Sendable, Equatable {
    /// Title of the source work.
    let title: String?
    /// Translator (Goodwin).
    let translator: String?
    /// Author (Crowley).
    let author: String?
    /// Year of publication.
    let year: Int?
    /// Archive URL.
    let url: String?
    /// Whether the text is in the public domain.
    let publicDomain: Bool?
}

/// One entry of `stages[]` in RitualText.json.
struct RitualTextStage: Decodable, Sendable, Equatable {
    /// JSON stage id ("opening", "air", …, "closing").
    let id: String
    /// Display title.
    let title: String?
    /// Element name or `null`.
    let element: String?
    /// Quarter name or `null`.
    let quarter: String?
    /// Lines keyed by edition id.
    let lines: [String: [String]]?
    /// Barbarous names in the 1929 Samekh orthography.
    let barbarousNames: [String]?
    /// Barbarous names transliterated from Goodwin's Greek.
    let barbarousNamesGoodwin: [String]?
}

/// The whole RitualText.json document.
struct RitualTextDocument: Decodable, Sendable, Equatable {
    /// Edition provenance by edition id.
    let editions: [String: RitualTextEditionInfo]?
    /// Stage entries in ritual order.
    let stages: [RitualTextStage]
    /// Free-text provenance notes.
    let notes: String?
}

// MARK: - Provider

/// Read-only access to the ritual text for the HUD and the debug panel.
final class RitualTextProvider: Sendable {
    /// Bundle resource name (without extension).
    static let resourceName = "RitualText"
    /// Bundle resource extension.
    static let resourceExtension = "json"
    /// Ritual seconds each line stays on screen before the HUD advances to the next.
    static let defaultSecondsPerLine = 3.5

    /// The decoded document, or `nil` when the resource is missing or malformed.
    let document: RitualTextDocument?
    /// Human-readable reason the document is `nil` (for the debug panel), else `nil`.
    let loadError: String?

    private let stagesByID: [String: RitualTextStage]

    /// Creates a provider over an already-decoded document (also used by tests).
    ///
    /// - Parameters:
    ///   - document: Decoded RitualText.json, or `nil` to run in fallback mode.
    ///   - loadError: Why the document is missing, if it is.
    init(document: RitualTextDocument?, loadError: String? = nil) {
        self.document = document
        self.loadError = loadError
        var byID: [String: RitualTextStage] = [:]
        for stage in document?.stages ?? [] where byID[stage.id] == nil {
            byID[stage.id] = stage
        }
        self.stagesByID = byID
    }

    /// Loads `RitualText.json` from `bundle`; never throws (fallback mode on failure).
    ///
    /// - Parameter bundle: Bundle holding the resource (the main bundle in the app).
    convenience init(bundle: Bundle = Bundle.main) {
        guard let url = bundle.url(forResource: RitualTextProvider.resourceName,
                                   withExtension: RitualTextProvider.resourceExtension) else {
            self.init(document: nil, loadError: "RitualText.json is not in the bundle")
            return
        }
        do {
            let document = try RitualTextProvider.load(from: url)
            self.init(document: document, loadError: nil)
        } catch {
            self.init(document: nil, loadError: "RitualText.json failed to decode: \(error)")
        }
    }

    /// Decodes a RitualText.json file.
    ///
    /// - Parameter url: File URL of the JSON document.
    /// - Throws: Any file-reading or decoding error.
    static func load(from url: URL) throws -> RitualTextDocument {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RitualTextDocument.self, from: data)
    }

    /// Whether the JSON document was loaded.
    var isLoaded: Bool { document != nil }

    // MARK: Stage mapping

    /// JSON stage ids that may carry the text of `stage`, most specific first.
    ///
    /// RitualText.json follows the 1929 section labels: the oath is "opening", the
    /// sigil spin is "climax" ("I am He, the Bornless Spirit") and the manifestation is
    /// "closing" ("Such are the Words"). The RitualCore id is accepted as well so a
    /// future regeneration of the file with RitualCore ids keeps working.
    static func jsonStageIDs(for stage: RitualStage) -> [String] {
        switch stage {
        case .oath: return ["oath", "opening"]
        case .air: return ["air"]
        case .fire: return ["fire"]
        case .water: return ["water"]
        case .earth: return ["earth"]
        case .spirit: return ["spirit"]
        case .sigilSpin: return ["sigilSpin", "climax"]
        case .manifestation: return ["manifestation", "closing"]
        }
    }

    /// The JSON entry for a stage, if the file has one.
    func entry(for stage: RitualStage) -> RitualTextStage? {
        for id in RitualTextProvider.jsonStageIDs(for: stage) {
            if let found = stagesByID[id] {
                return found
            }
        }
        return nil
    }

    // MARK: Lookups

    /// Stage title: RitualCore's `RitualStage.title` (the HUD keeps the gameplay names;
    /// the JSON titles are section headings of the source text).
    func title(for stage: RitualStage) -> String {
        stage.title
    }

    /// Section heading of the source text for a stage, e.g. "I am He, the Bornless Spirit".
    func sourceHeading(for stage: RitualStage) -> String? {
        entry(for: stage)?.title
    }

    /// The stage's lines in `edition`; falls back to the other edition, then to an
    /// empty array when the file is missing.
    func lines(for stage: RitualStage, edition: RitualTextEdition) -> [String] {
        guard let lines = entry(for: stage)?.lines else { return [] }
        if let exact = lines[edition.rawValue], !exact.isEmpty {
            return exact
        }
        for other in RitualTextEdition.allCases where other != edition {
            if let fallback = lines[other.rawValue], !fallback.isEmpty {
                return fallback
            }
        }
        return []
    }

    /// Barbarous names of a stage in the edition's orthography (Goodwin's
    /// transliteration or the 1929 Samekh spelling); empty when unknown.
    func barbarousNames(for stage: RitualStage, edition: RitualTextEdition) -> [String] {
        guard let entry = entry(for: stage) else { return [] }
        switch edition {
        case .goodwin1852:
            return entry.barbarousNamesGoodwin ?? entry.barbarousNames ?? []
        case .samekh1930:
            return entry.barbarousNames ?? entry.barbarousNamesGoodwin ?? []
        }
    }

    /// The six Spirit beat names shown on the rhythm markers (docs/SOURCES.md §4a):
    /// `RhythmSpec.names` (Goodwin's transliteration) for the Goodwin edition, the
    /// Samekh `barbarousNames` for Liber Samekh when the file supplies exactly six.
    func beatNames(edition: RitualTextEdition) -> [String] {
        let fallback = RhythmSpec.names
        guard edition == .samekh1930 else { return fallback }
        let samekh = barbarousNames(for: .spirit, edition: .samekh1930)
        return samekh.count == fallback.count ? samekh : fallback
    }

    /// Display title of an edition ("Liber Samekh (1930)"), from the file when present.
    func editionTitle(_ edition: RitualTextEdition) -> String {
        if let info = document?.editions?[edition.rawValue], let title = info.title, let year = info.year {
            return "\(title) (\(year))"
        }
        return edition.displayName
    }

    // MARK: Line cycling

    /// Index of the line to show `stageSeconds` after the stage began, cycling through
    /// `count` lines every `secondsPerLine`; `nil` when there are no lines.
    ///
    /// - Parameters:
    ///   - count: Number of lines available.
    ///   - stageSeconds: Ritual seconds since the stage started (negative values clamp to 0).
    ///   - secondsPerLine: Dwell time per line.
    static func lineIndex(count: Int, stageSeconds: Double, secondsPerLine: Double = defaultSecondsPerLine) -> Int? {
        guard count > 0 else { return nil }
        let dwell = max(secondsPerLine, 0.001)
        let step = Int((max(stageSeconds, 0) / dwell).rounded(.down))
        return step % count
    }

    /// The line to show for a stage at a moment in the stage, with its index.
    ///
    /// - Parameters:
    ///   - stage: Current stage.
    ///   - edition: Selected edition.
    ///   - stageSeconds: Ritual seconds since the stage started.
    func currentLine(for stage: RitualStage, edition: RitualTextEdition, stageSeconds: Double) -> (index: Int, text: String)? {
        let lines = lines(for: stage, edition: edition)
        guard let index = RitualTextProvider.lineIndex(count: lines.count, stageSeconds: stageSeconds) else { return nil }
        return (index, lines[index])
    }
}
