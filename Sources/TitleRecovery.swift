import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reconstructs text only from an explicitly supplied ChatCut snapshot.
/// Graphic code, animation and template styling are deliberately not translated.
enum TitleRecovery {
    static func addBasicTitles(fcpxmlURL: URL, overlays: [[String: Any]]) throws -> Int {
        guard !overlays.isEmpty, overlays.count <= 10_000 else { return 0 }
        let document = try XMLDocument(contentsOf: fcpxmlURL, options: [.nodeLoadExternalEntitiesNever])
        guard let resources = try document.nodes(forXPath: "/fcpxml/resources").first as? XMLElement,
              let sequence = try document.nodes(forXPath: "//project/sequence").first as? XMLElement,
              let spine = sequence.elements(forName: "spine").first,
              let formatId = sequence.attribute(forName: "format")?.stringValue,
              let format = resources.elements(forName: "format").first(where: { $0.attribute(forName: "id")?.stringValue == formatId }),
              let frameDuration = format.attribute(forName: "frameDuration")?.stringValue else { return 0 }
        let frame = try ExactTime(frameDuration)
        let children = (spine.children ?? []).compactMap { $0 as? XMLElement }.filter { ["asset-clip", "gap", "clip"].contains($0.name ?? "") }
        guard !children.isEmpty else { return 0 }
        var usedIds = Set((try document.nodes(forXPath: "//*[@id]")).compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue })
        var effectId = "chatcutBasicTitle"
        while usedIds.contains(effectId) { effectId += "x" }
        let effect = element("effect", ["id": effectId, "name": "Basic Title", "uid": ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"])
        resources.addChild(effect)
        usedIds.insert(effectId)
        var count = 0
        let sequenceDuration = try ExactTime(sequence.attribute(forName: "duration")?.stringValue ?? "0s")
        let sequenceStart = try ExactTime(sequence.attribute(forName: "tcStart")?.stringValue ?? "0s")
        for overlay in overlays {
            guard let text = overlay["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 16_384,
                  let startNumber = overlay["startFrame"] as? NSNumber,
                  let durationNumber = overlay["durationInFrames"] as? NSNumber else { continue }
            let startFrame = startNumber.int64Value, frames = durationNumber.int64Value
            guard startFrame >= 0, startFrame <= 100_000_000, frames > 0, frames <= 10_000_000 else { continue }
            let start = frame.multiplied(by: startFrame)
            guard start.seconds < sequenceDuration.seconds else { continue }
            let absoluteStart = sequenceStart + start
            let duration = frame.multiplied(by: frames)
            let parent = try children.last(where: { child in
                let offset = try ExactTime(child.attribute(forName: "offset")?.stringValue ?? "0s")
                return offset.seconds <= absoluteStart.seconds + 0.00000001
            }) ?? children[0]
            let parentOffset = try ExactTime(parent.attribute(forName: "offset")?.stringValue ?? "0s")
            let parentStart = try ExactTime(parent.attribute(forName: "start")?.stringValue ?? "0s")
            let name = overlay["assetName"] as? String ?? "ChatCut text"
            let caption = name.localizedCaseInsensitiveContains("caption")
            let exercise = name.localizedCaseInsensitiveContains("exercise")
            let lane = caption ? 100 : exercise ? 101 : 102
            let title = element("title", ["ref":effectId, "lane":"\(lane)", "offset":(parentStart + absoluteStart - parentOffset).xml,
                    "start":"0s", "duration":duration.xml, "name":String(text.prefix(80)), "role":caption ? "titles.ChatCut Captions" : "titles.ChatCut Graphics"])
            var styleId = "chatcutTitleStyle\(count + 1)"
            while usedIds.contains(styleId) { styleId += "x" }
            usedIds.insert(styleId)
            let textElement = element("text", [:]); let span = element("text-style", ["ref":styleId]); span.stringValue = text; textElement.addChild(span); title.addChild(textElement)
            let styleDefinition = element("text-style-def", ["id":styleId])
            // Verified FCP roundtrip: positive strokeWidth disables Face (outline only);
            // a negative width keeps both the opaque text face and the same outline thickness.
            let style = element("text-style", ["font":"Helvetica Neue", "fontSize":caption ? "112" : exercise ? "96" : "144", "fontFace":"Bold", "fontColor":"1 1 1 1", "alignment":"center", "strokeColor":"0 0 0 1", "strokeWidth":"-3", "shadowColor":"0 0 0 0.75", "shadowOffset":"0 -2", "shadowBlurRadius":"6"])
            styleDefinition.addChild(style); title.addChild(styleDefinition)
            if caption || exercise { title.addChild(element("adjust-transform", ["position": caption ? "0 -38" : "0 -26"])) }
            let disallowed = Set(["marker", "chapter-marker", "rating", "keyword", "analysis-marker", "audio-channel-source", "filter-video", "filter-video-mask", "filter-audio", "metadata"])
            if let index = (parent.children ?? []).firstIndex(where: { disallowed.contains($0.name ?? "") }) { parent.insertChild(title, at: index) }
            else { parent.addChild(title) }
            count += 1
        }
        if count == 0 { effect.detach(); return 0 }
        document.dtd = nil; document.characterEncoding = "UTF-8"; document.isStandalone = false
        var data = document.xmlData(options: [.nodePrettyPrint])
        if let string = String(data: data, encoding: .utf8), let end = string.range(of: "?>") {
            data = Data((String(string[..<end.upperBound]) + "\n<!DOCTYPE fcpxml>" + String(string[end.upperBound...])).utf8)
        }
        let staging = fcpxmlURL.deletingLastPathComponent().appendingPathComponent(".titles-\(UUID().uuidString).fcpxml")
        try data.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }
        if let version = document.rootElement()?.attribute(forName: "version")?.stringValue, let dtd = TimelineConverter.installedDTD(version: version) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint"); process.arguments = ["--nonet","--noout","--dtdvalid",dtd.absoluteString,staging.path]
            let pipe = Pipe(); process.standardError = pipe; try process.run(); let diagnostics = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw NSError(domain:"ChatCutTitles",code:1,userInfo:[NSLocalizedDescriptionKey:"Recovered title XML did not validate: " + String(decoding:diagnostics,as:UTF8.self)]) }
        }
        try data.write(to: fcpxmlURL, options: .atomic)
        return count
    }

    private static func element(_ name: String, _ attributes: [String:String]) -> XMLElement {
        let node = XMLElement(name:name)
        for (key,value) in attributes.sorted(by: { $0.key < $1.key }) { node.addAttribute(XMLNode.attribute(withName:key,stringValue:value) as! XMLNode) }
        return node
    }
}

private struct ExactTime {
    let n: Int64
    let d: Int64
    init(_ string: String) throws {
        let parts = string.replacingOccurrences(of:"s",with:"").split(separator:"/")
        guard let first = parts.first, let numerator = Int64(first), abs(numerator) < 1_000_000_000_000,
              parts.count <= 2 else { throw NSError(domain:"ChatCutTitles",code:2,userInfo:[NSLocalizedDescriptionKey:"Invalid FCPXML time."]) }
        let denominator = parts.count == 2 ? Int64(parts[1]) ?? 0 : 1
        guard denominator > 0, denominator <= 1_000_000_000 else { throw NSError(domain:"ChatCutTitles",code:2,userInfo:[NSLocalizedDescriptionKey:"Invalid FCPXML time denominator."]) }
        self.init(numerator,denominator)
    }
    init(_ numerator: Int64, _ denominator: Int64) { let g = Self.gcd(abs(numerator),denominator); n = numerator/g; d = denominator/g }
    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { var a=a; var b=b; while b != 0 { let r=a%b; a=b; b=r }; return max(a,1) }
    func multiplied(by value:Int64) -> ExactTime { ExactTime(n*value,d) }
    var xml: String { d == 1 ? "\(n)s" : "\(n)/\(d)s" }
    var seconds:Double { Double(n)/Double(d) }
    static func + (a:ExactTime,b:ExactTime) -> ExactTime { let g=gcd(a.d,b.d); return ExactTime(a.n*(b.d/g)+b.n*(a.d/g),a.d*(b.d/g)) }
    static func - (a:ExactTime,b:ExactTime) -> ExactTime { a + ExactTime(-b.n,b.d) }
}
