import Foundation
import CryptoKit

enum ExportService {
    static func convert(inputURL: URL, mediaRoots: [URL], outputDirectory: URL, warningURL: URL? = nil) throws -> ConversionResult {
        let base = try TimelineConverter.convert(inputURL: inputURL, mediaRoots: mediaRoots, outputDirectory: outputDirectory)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(atPath: base.outputPath)
                try? FileManager.default.removeItem(atPath: base.reportPath)
            }
        }
        var warnings = base.warnings
        let sidecar = warningURL ?? inputURL.deletingPathExtension().appendingPathExtension("warnings.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let data = try Data(contentsOf: sidecar)
            guard data.count < 2_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ChatCutToFinalCut", code: 12, userInfo: [NSLocalizedDescriptionKey: "The export warning file is not a valid JSON object."])
            }
            if let expected = object["sourceXMLSHA256"] as? String {
                let actual = SHA256.hash(data: try Data(contentsOf: inputURL)).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw NSError(domain: "ChatCutToFinalCut", code: 13, userInfo: [NSLocalizedDescriptionKey: "The project snapshot belongs to a different XML export. Export fresh XML and a matching snapshot."]) }
            }
            let recovered = try TitleRecovery.addBasicTitles(fcpxmlURL: URL(fileURLWithPath: base.outputPath), overlays: object["overlays"] as? [[String: Any]] ?? [])
            if recovered > 0 { warnings.append("Recovered \(recovered) text overlays as editable Basic Titles. ChatCut animation, graphic backgrounds and template styling are unavailable; review their placement in Final Cut.") }
            if let details = object["messages"] as? [String] { warnings.append(contentsOf: details) }
            if let dropped = object["droppedItemTypes"] as? [String: Int] {
                for (kind, count) in dropped.sorted(by: { $0.key < $1.key }) where count > 0 {
                    if kind == "motion-graphic" && recovered > 0 { warnings.append("ChatCut omitted \(count) motion graphics from its XML; \(recovered) were rebuilt as text titles using the supplied project snapshot.") }
                    else { warnings.append("ChatCut omitted \(count) \(kind) items from this XML. They are absent from the Final Cut timeline.") }
                }
            }
            if let count = object["droppedTransitions"] as? Int, count > 0 {
                warnings.append("ChatCut omitted \(count) transitions from this XML. Recreate them in Final Cut.")
            }
        } else if inputURL.pathExtension.lowercased() == "xml" {
            warnings.append("ChatCut's legacy XML can omit motion graphics, captions and transitions before conversion. Use its export warnings to check whether separate graphics or subtitle files are needed.")
        }
        let result = ConversionResult(inputPath: base.inputPath, outputPath: base.outputPath, reportPath: base.reportPath,
                                      projectName: base.projectName, clipCount: base.clipCount, missingMedia: base.missingMedia,
                                      warnings: Array(Set(warnings)).sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: URL(fileURLWithPath: result.reportPath), options: .atomic)
        completed = true
        return result
    }
}
