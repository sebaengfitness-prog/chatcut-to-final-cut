import Foundation

@main struct TitleRecoveryTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TitleTestFailure(message: message) }
    }
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ChatCutTitleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try testSyntheticSnapshot(scratch)
        try testTimecodeAndEscaping(scratch)
        try testSidecarMismatchCleanup(scratch)
        print("PASS: \(assertions) title and export integration assertions.")
    }
    static func nodes(_ d: XMLDocument, _ xpath: String) throws -> [XMLElement] { try d.nodes(forXPath: xpath).compactMap { $0 as? XMLElement } }
    static func attr(_ n: XMLElement, _ name: String) -> String { n.attribute(forName: name)?.stringValue ?? "" }
    static func seconds(_ string: String) -> Double {
        let values = string.dropLast().split(separator: "/").compactMap { Double($0) }
        return values.count == 2 ? values[0]/values[1] : values.first ?? .nan
    }
    static func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs-rhs) < 0.0000001 }
    static func signature(_ node: XMLElement) -> String {
        let attributes = (node.attributes ?? []).map { ($0.name ?? "") + "=" + ($0.stringValue ?? "") }.sorted().joined(separator: ";")
        let children = (node.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name != "title" }.map(signature).joined(separator: "|")
        return (node.name ?? "") + "[" + attributes + "]{" + children + "}"
    }
    static func document(_ path: String) throws -> XMLDocument { try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodeLoadExternalEntitiesNever]) }
    static func testSyntheticSnapshot(_ scratch: URL) throws {
        let input = SyntheticFixtures.inputURL
        let warningURL = SyntheticFixtures.warningURL
        let media = try SyntheticFixtures.makeMedia(in: scratch)
        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: warningURL)) as! [String: Any]
        let overlays = snapshot["overlays"] as! [[String: Any]]
        try expect(overlays.count == 5, "Synthetic snapshot contains five caption, label and graphic examples")
        let base = try TimelineConverter.convert(inputURL: input, mediaRoots: [media], outputDirectory: scratch.appendingPathComponent("titles"))
        let before = try document(base.outputPath)
        let beforeClips = try nodes(before, "//asset-clip | //clip | //audio").map(signature)
        let recovered = try TitleRecovery.addBasicTitles(fcpxmlURL: URL(fileURLWithPath: base.outputPath), overlays: overlays)
        let after = try document(base.outputPath)
        let titles = try nodes(after, "//title")
        try expect(recovered == 5 && titles.count == 5, "All synthetic titles are saved in native XML")
        try expect(try nodes(after, "//asset-clip | //clip | //audio").map(signature) == beforeClips, "Title recovery changes no media placement, trim, timing or effect")
        try expect(try nodes(after, "//asset").count == 3, "Title recovery preserves all three synthetic source assets")
        let effects = try nodes(after, "//effect[@name='Basic Title']")
        try expect(effects.count == 1, "All titles share one native Basic Title resource")
        try expect(attr(effects[0], "uid") == ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti", "The Basic Title UID uses Final Cut's standard template convention without requiring its installation")
        let styles = try nodes(after, "//title/text-style-def/text-style")
        try expect(styles.count == 5 && styles.allSatisfy { (Double(attr($0, "strokeWidth")) ?? 0) < 0 }, "Every recovered title enables the text face using the negative stroke-width convention")
        try expect(styles.allSatisfy { attr($0, "fontColor") == "1 1 1 1" }, "Every recovered title retains opaque white fill")
        try expect(styles.allSatisfy { abs(Double(attr($0, "strokeWidth")) ?? 0) == 3 && attr($0, "strokeColor") == "0 0 0 1" }, "The filled title keeps its three-unit opaque black outline")
        var unmatched = overlays
        for title in titles {
            guard let parent = title.parent as? XMLElement else { throw TitleTestFailure(message: "Title has no timeline parent") }
            let timelineStart = seconds(attr(parent, "offset")) + seconds(attr(title, "offset")) - seconds(attr(parent, "start"))
            let duration = seconds(attr(title, "duration"))
            let text = title.elements(forName: "text").first?.stringValue ?? ""
            guard let index = unmatched.firstIndex(where: { overlay in
                let start = (overlay["startFrame"] as! NSNumber).doubleValue * 1001.0 / 24000
                let length = (overlay["durationInFrames"] as! NSNumber).doubleValue * 1001.0 / 24000
                return close(timelineStart, start) && close(duration, length) && text == overlay["text"] as? String
            }) else { throw TitleTestFailure(message: "Recovered title differs in text, exact start or duration: \(text)") }
            unmatched.remove(at: index)
            try expect(attr(title, "start") == "0s", "Each title's local timeline starts at zero")
        }
        try expect(unmatched.isEmpty, "Every synthetic overlay matches exact NTSC timing and text")
        let sequence = try nodes(after, "//sequence")[0]
        try expect(close(seconds(attr(sequence, "duration")), 240 * 1001.0 / 24000), "Media sequence duration stays unchanged despite the synthetic upstream three-frame delta")
        let finalTitle = titles.first { $0.elements(forName: "text").first?.stringValue == "Final sample caption" }!
        try expect(close(seconds(attr(finalTitle, "duration")), 15 * 1001.0 / 24000), "The last caption preserves its full duration beyond the shorter exported sequence")
        let service = try ExportService.convert(inputURL: input, mediaRoots: [media], outputDirectory: scratch.appendingPathComponent("service"), warningURL: warningURL)
        try expect(service.missingMedia.isEmpty, "End-to-end conversion resolves synthetic media without personal folders")
        try expect(service.warnings.contains { $0.contains("Recovered 5 text overlays") }, "The report states how many text overlays were recovered")
        try expect(service.warnings.contains { $0.contains("3 frame delta") }, "The report preserves the upstream timing discrepancy")
        try expect(service.warnings.contains { $0.contains("2") && $0.contains("crossfade") }, "The report preserves the upstream audio crossfade warning")
    }
    static func testTimecodeAndEscaping(_ scratch: URL) throws {
        let native = """
        <fcpxml version="1.10"><resources><format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/><asset id="r2" name="Media" start="100s" duration="10s" hasVideo="1" format="r1"><media-rep kind="original-media" src="file:///missing/media.mov"/></asset></resources><project name="Timecode"><sequence format="r1" duration="1001/500s" tcStart="3600s"><spine><asset-clip ref="r2" offset="3600s" start="100s" duration="1001/1000s"/><gap offset="3601001/1000s" start="0s" duration="1001/1000s"/></spine></sequence></project></fcpxml>
        """
        let path = scratch.appendingPathComponent("timecode.fcpxml")
        try Data(native.utf8).write(to: path)
        let escapedText = "A & B <C> \"quotes\" Ω\nnext"
        let overlays: [[String: Any]] = [
            ["assetName": "Speech caption", "text": escapedText, "startFrame": 15, "durationInFrames": 10],
            ["assetName": "Exercise label", "text": "ON THE GAP", "startFrame": 45, "durationInFrames": 10]
        ]
        try expect(try TitleRecovery.addBasicTitles(fcpxmlURL: path, overlays: overlays) == 2, "NTSC test overlays are recovered")
        let d = try document(path.path)
        let titles = try nodes(d, "//title")
        try expect(titles[0].elements(forName: "text").first?.stringValue == escapedText, "XML escaping preserves ampersands, brackets, quotes, Unicode and line breaks")
        let styles = try nodes(d, "//title/text-style-def/text-style")
        try expect(styles.allSatisfy { attr($0, "strokeWidth") == "-3" && attr($0, "fontColor") == "1 1 1 1" }, "Face remains enabled for escaped multiline captions and exercise labels")
        let firstParent = titles[0].parent as! XMLElement
        let firstTimelineStart = seconds(attr(firstParent, "offset")) + seconds(attr(titles[0], "offset")) - seconds(attr(firstParent, "start"))
        try expect(close(firstTimelineStart, 3600 + 15 * 1001.0 / 30000), "Title start includes sequence timecode origin and parent's source-time coordinates")
        let secondParent = titles[1].parent as! XMLElement
        try expect(secondParent.name == "gap", "Later title attaches to the correct magnetic-storyline gap")
        let secondTimelineStart = seconds(attr(secondParent, "offset")) + seconds(attr(titles[1], "offset")) - seconds(attr(secondParent, "start"))
        try expect(close(secondTimelineStart, 3600 + 45 * 1001.0 / 30000), "Gap title exact start is retained")
        try expect(try TitleRecovery.addBasicTitles(fcpxmlURL: path, overlays: overlays) == 2, "Adding to an existing native title document keeps IDs unique")
        let twice = try document(path.path)
        let allIDs = try twice.nodes(forXPath: "//*[@id]").compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        try expect(Set(allIDs).count == allIDs.count, "Native effect and text-style IDs have no collisions")
    }
    static func testSidecarMismatchCleanup(_ scratch: URL) throws {
        let input = SyntheticFixtures.inputURL
        let sidecar = scratch.appendingPathComponent("mismatch.warnings.json")
        try Data("{\"sourceXMLSHA256\":\"wrong\",\"overlays\":[]}".utf8).write(to: sidecar)
        let output = scratch.appendingPathComponent("mismatch-output")
        var rejected = false
        do { _ = try ExportService.convert(inputURL: input, mediaRoots: [], outputDirectory: output, warningURL: sidecar) }
        catch { rejected = error.localizedDescription.contains("different XML export") }
        try expect(rejected, "A mismatched project snapshot is explicitly rejected")
        let files = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
        try expect(files.isEmpty, "Failed snapshot validation leaves no misleading native XML or completed report")
    }

}
struct TitleTestFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
