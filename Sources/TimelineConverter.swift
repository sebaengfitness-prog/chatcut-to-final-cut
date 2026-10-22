import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ConversionResult: Codable {
    let inputPath: String
    let outputPath: String
    let reportPath: String
    let projectName: String
    let clipCount: Int
    let missingMedia: [String]
    let warnings: [String]
}

enum TimelineConversionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Converts interchange XML only. It never edits ChatCut's project or source media.
struct TimelineConverter {
    static func convert(inputURL: URL, mediaRoots: [URL], outputDirectory: URL) throws -> ConversionResult {
        let document = try readDocument(inputURL)
        guard let root = document.rootElement() else { throw failure("The XML has no root element.") }
        let resolver = MediaResolver(inputDirectory: inputURL.deletingLastPathComponent(), roots: mediaRoots)
        var warnings: [String] = []
        let output: XMLDocument
        let projectName: String
        let clipCount: Int
        switch root.name {
        case "xmeml":
            let legacy = try LegacyConversion(root: root, resolver: resolver)
            output = legacy.document
            projectName = legacy.name
            clipCount = legacy.clipCount
            warnings = legacy.warnings
        case "fcpxml":
            guard let version = root.attribute(forName: "version")?.stringValue,
                  version.range(of: #"^1\.[0-9]+$"#, options: .regularExpression) != nil else {
                throw failure("Native FCPXML must declare a supported numeric version.")
            }
            output = document
            for asset in descendants(root, named: "asset") {
                if let src = asset.attribute(forName: "src") { src.stringValue = resolver.resolve(src.stringValue ?? "") }
                for rep in asset.elements(forName: "media-rep") {
                    if let src = rep.attribute(forName: "src") {
                        let oldValue = src.stringValue ?? ""
                        src.stringValue = resolver.resolve(oldValue)
                        // Security scoped bookmarks and signatures refer to the old file.
                        if src.stringValue != oldValue {
                            rep.removeAttribute(forName: "sig")
                            for bookmark in rep.elements(forName: "bookmark") { bookmark.detach() }
                        }
                    }
                }
            }
            projectName = descendants(root, named: "project").first?.attribute(forName: "name")?.stringValue
                ?? inputURL.deletingPathExtension().lastPathComponent
            clipCount = mediaPlacementCount(root)
            warnings.append("Native FCPXML was retained in its original version; existing edits and effects were preserved.")
        default:
            throw failure("Expected an xmeml or fcpxml root element; found \(root.name ?? "unknown").")
        }
        warnings += resolver.warnings
        if !resolver.missing.isEmpty {
            warnings.append("\(resolver.missing.count) media file(s) remain offline. Choose their media folders and convert again, or relink them in Final Cut Pro.")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let safeName = projectName.replacingOccurrences(of: #"[/:\x00-\x1F]"#, with: "_", options: .regularExpression)
        let stem = String((safeName.isEmpty ? "ChatCut Project" : safeName).prefix(180))
        var outputURL = outputDirectory.appendingPathComponent(stem + ".fcpxml")
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) || outputURL.standardizedFileURL == inputURL.standardizedFileURL {
            outputURL = outputDirectory.appendingPathComponent(stem + " \(suffix).fcpxml")
            suffix += 1
        }
        output.dtd = nil
        output.characterEncoding = "UTF-8"
        output.isStandalone = false
        // Plain, local DOCTYPE avoids all external input entities and remains compatible with FCP.
        var xmlData = output.xmlData(options: [.nodePrettyPrint])
        if let text = String(data: xmlData, encoding: .utf8), let end = text.range(of: "?>") {
            xmlData = Data((String(text[..<end.upperBound]) + "\n<!DOCTYPE fcpxml>" + String(text[end.upperBound...])).utf8)
        }
        let stagingURL = outputDirectory.appendingPathComponent(".converter-\(UUID().uuidString).fcpxml")
        try xmlData.write(to: stagingURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        if let version = output.rootElement()?.attribute(forName: "version")?.stringValue {
            if let dtd = installedDTD(version: version) {
                try validate(url: stagingURL, dtd: dtd)
            } else {
                warnings.append("Final Cut Pro's FCPXML \(version) DTD was not found; XML was parsed safely, but schema validation was unavailable.")
            }
        }
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        let reportURL = outputURL.deletingPathExtension().appendingPathExtension("report.json")
        let result = ConversionResult(inputPath: inputURL.path, outputPath: outputURL.path, reportPath: reportURL.path,
                                      projectName: projectName, clipCount: clipCount,
                                      missingMedia: resolver.missing.sorted(), warnings: unique(warnings))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(result).write(to: reportURL, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: outputURL); throw error }
        return result
    }

    static func installedDTD(version: String) -> URL? {
        guard version.range(of: #"^1\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let filename = "FCPXMLv" + version.replacingOccurrences(of: ".", with: "_") + ".dtd"
        let appPaths = ["/Applications/Final Cut Pro.app", "/Applications/Final Cut Pro Trial.app"]
        for app in appPaths {
            let url = URL(fileURLWithPath: app).appendingPathComponent("Contents/Frameworks/Interchange.framework/Versions/A/Resources/" + filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func validate(url: URL, dtd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--nonet", "--noout", "--dtdvalid", dtd.absoluteString, url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let diagnostics = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("Final Cut Pro schema validation failed: " + (String(data: diagnostics, encoding: .utf8) ?? "unknown error"))
        }
    }

    private static func readDocument(_ url: URL) throws -> XMLDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
            throw failure("Choose an XML file smaller than 64 MB.")
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw failure("The XML must use UTF-8 encoding.") }
        // Reject any entity declaration and all external DTD identifiers before invoking an XML parser.
        guard text.range(of: #"<!\s*ENTITY\b|<!\s*DOCTYPE\s+[^>]*(?:\bSYSTEM\b|\bPUBLIC\b|\[)"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else {
            throw failure("XML entity declarations and external DTDs are not allowed.")
        }
        let limiter = XMLLimits()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = limiter
        guard parser.parse(), limiter.error == nil else { throw failure(limiter.error ?? parser.parserError?.localizedDescription ?? "Invalid XML.") }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.uri?.isEmpty != false,
              root.name == "xmeml" || root.name == "fcpxml" else { throw failure("Only namespace-free xmeml or fcpxml documents are supported.") }
        return document
    }
}

private final class XMLLimits: NSObject, XMLParserDelegate {
    var depth = 0
    var nodes = 0
    var error: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        nodes += 1
        if depth > 128 || nodes > 250_000 || attributeDict.count > 100 || attributeDict.values.contains(where: { $0.utf8.count > 1_048_576 }) {
            error = "XML exceeds the converter's depth, node or attribute limits."
            parser.abortParsing()
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

private struct Rational: Equatable, Comparable {
    let n: Int64
    let d: Int64
    init(_ n: Int64, _ d: Int64 = 1) {
        precondition(d != 0)
        let sign: Int64 = d < 0 ? -1 : 1
        let factor = Self.gcd(abs(n), abs(d))
        self.n = n / factor * sign
        self.d = abs(d) / factor
    }
    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a; var b = b
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return max(a, 1)
    }
    static let zero = Rational(0)
    static func + (lhs: Rational, rhs: Rational) -> Rational {
        let g = gcd(lhs.d, rhs.d)
        return Rational(lhs.n * (rhs.d / g) + rhs.n * (lhs.d / g), lhs.d * (rhs.d / g))
    }
    static func - (lhs: Rational, rhs: Rational) -> Rational { lhs + Rational(-rhs.n, rhs.d) }
    static func * (lhs: Rational, rhs: Rational) -> Rational {
        let g1 = gcd(abs(lhs.n), rhs.d), g2 = gcd(abs(rhs.n), lhs.d)
        return Rational((lhs.n / g1) * (rhs.n / g2), (lhs.d / g2) * (rhs.d / g1))
    }
    static func < (lhs: Rational, rhs: Rational) -> Bool { lhs.double < rhs.double }
    var double: Double { Double(n) / Double(d) }
    var time: String { d == 1 ? "\(n)s" : "\(n)/\(d)s" }
    static func decimal(_ value: String) -> Rational? {
        guard let number = Double(value), number.isFinite, abs(number) < 1_000_000 else { return nil }
        for (approximate, exact) in [(23.976, Rational(24000, 1001)), (29.97, Rational(30000, 1001)), (59.94, Rational(60000, 1001)), (119.88, Rational(120000, 1001))] {
            if abs(number - approximate) < 0.0001 { return exact }
        }
        return Rational(Int64((number * 1_000_000).rounded()), 1_000_000)
    }
}

private struct Rate {
    let fps: Rational
    var frame: Rational { Rational(fps.d, fps.n) }
    init(_ node: XMLElement?, fallback: Rate? = nil) throws {
        guard let value = childText(node, "timebase") else {
            if let fallback { self = fallback; return }
            throw failure("The sequence has no valid frame rate.")
        }
        guard let base = Rational.decimal(value), base.double > 0, base.double <= 240,
              base.n <= 240_000, base.d <= 1001 else { throw failure("Unsupported or invalid frame rate: \(value).") }
        if childText(node, "ntsc")?.uppercased() == "TRUE", base.d == 1 {
            fps = base * Rational(1000, 1001)
        } else { fps = base }
    }
    func time(_ frames: Int64) -> Rational { Rational(frames) * frame }
}

private final class MediaResolver {
    let inputDirectory: URL
    let roots: [URL]
    var missing = Set<String>()
    var warnings: [String] = []
    var cache: [String: String] = [:]
    var basenameIndex: [String: Set<URL>]?
    init(inputDirectory: URL, roots: [URL]) { self.inputDirectory = inputDirectory; self.roots = roots.map(\.standardizedFileURL) }
    func resolve(_ raw: String) -> String {
        if let cached = cache[raw] { return cached }
        if let url = URL(string: raw), let scheme = url.scheme, scheme != "file" {
            warnings.append("Remote media URL was retained without downloading: \(raw)")
            cache[raw] = raw
            return raw
        }
        let decoded: String
        if raw.hasPrefix("file://./") { decoded = String(raw.dropFirst("file://./".count)).removingPercentEncoding ?? String(raw.dropFirst("file://./".count)) }
        else if let url = URL(string: raw), url.isFileURL {
            decoded = url.path
        } else { decoded = raw.removingPercentEncoding ?? raw }
        let absolute = decoded.hasPrefix("/")
        let original = absolute ? URL(fileURLWithPath: decoded) : inputDirectory.appendingPathComponent(decoded)
        if exists(original) { return remember(raw, original) }
        var candidates = Set<URL>()
        if !absolute {
            for root in roots {
                let candidate = root.appendingPathComponent(decoded).standardizedFileURL
                if exists(candidate) { candidates.insert(candidate.resolvingSymlinksInPath()) }
            }
        } else {
            // Match directory structure beneath a selected root before considering a basename.
            let components = decoded.split(separator: "/").map(String.init)
            if components.count > 1 {
                for start in 0..<(components.count - 1) {
                    let suffix = components[start...].joined(separator: "/")
                    for root in roots {
                        let candidate = root.appendingPathComponent(suffix).standardizedFileURL
                        if exists(candidate) { candidates.insert(candidate.resolvingSymlinksInPath()) }
                    }
                    if !candidates.isEmpty { break }
                }
            }
        }
        if candidates.count == 1, let candidate = candidates.first { return remember(raw, candidate) }
        if candidates.isEmpty {
            buildIndex()
            candidates = basenameIndex?[original.lastPathComponent] ?? []
            if candidates.count == 1, let candidate = candidates.first { return remember(raw, candidate) }
        }
        let missingPath = original.standardizedFileURL.path
        missing.insert(missingPath)
        if candidates.count > 1 { warnings.append("Ambiguous media name '\(original.lastPathComponent)' matched \(candidates.count) files; no automatic relink was made.") }
        cache[raw] = original.standardizedFileURL.absoluteString
        return cache[raw]!
    }
    private func remember(_ raw: String, _ url: URL) -> String { let value = url.standardizedFileURL.absoluteString; cache[raw] = value; return value }
    private func exists(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    private func buildIndex() {
        guard basenameIndex == nil else { return }
        basenameIndex = [:]
        var count = 0
        for root in roots {
            if exists(root) { basenameIndex?[root.lastPathComponent, default: []].insert(root.resolvingSymlinksInPath()); continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                count += 1
                if count > 250_000 { warnings.append("Media search stopped after 250,000 entries; choose a more specific media folder."); return }
                if exists(url) { basenameIndex?[url.lastPathComponent, default: []].insert(url.resolvingSymlinksInPath()) }
            }
        }
    }
}

private struct LegacySource {
    let id: String
    let node: XMLElement
    let rate: Rate
    let origin: Rational
    var length: Rational
    let video: Bool
    let audio: Bool
    let formatID: String?
    let url: String
}

private struct LegacyClip {
    let node: XMLElement
    let name: String
    let sourceID: String
    let mediaType: String
    let trackIndex: Int
    let offset: Rational
    let duration: Rational
    let sourceStart: Rational
    let sourceEnd: Rational
    let sourceOrigin: Rational
    let inFrame: Int64
    let outFrame: Int64
    let rate: Rate
    let sourceTrack: Int64
    let enabled: Bool
    let volume: Double?
    let volumeKeys: [(Int64, Double)]
    let retimed: Bool
    let reverse: Bool
}

private final class LegacyConversion {
    let document: XMLDocument
    let name: String
    let clipCount: Int
    var warnings: [String] = []
    init(root: XMLElement, resolver: MediaResolver) throws {
        let sequences = descendants(root, named: "sequence").filter { $0.child("media") != nil }
        guard let sequence = sequences.first else { throw failure("The legacy XML contains no timeline sequence.") }
        guard sequences.count == 1 else { throw failure("This XML contains multiple sequences. Export one ChatCut project at a time.") }
        name = childText(sequence, "name") ?? "ChatCut Project"
        let sequenceRate = try Rate(sequence.child("rate"))
        let sample = sequence.child("media")?.child("video")?.child("format")?.child("samplecharacteristics")
        let width = try positiveDimension(childText(sample, "width"), fallback: 1920)
        let height = try positiveDimension(childText(sample, "height"), fallback: 1080)
        if sample == nil { warnings.append("Sequence dimensions were absent; 1920 × 1080 was used.") }
        let tcOrigin = sequenceRate.time(try integer(sequence.child("timecode"), "frame", fallback: 0))
        let tcFormat = childText(sequence.child("timecode"), "displayformat") == "DF" ? "DF" : "NDF"
        let fcpxml = element("fcpxml", ["version": "1.10"])
        document = XMLDocument(rootElement: fcpxml)
        let resources = element("resources")
        fcpxml.addChild(resources)
        resources.addChild(makeFormat(id: "r1", rate: sequenceRate, width: width, height: height, sample: sample))
        // A file can be defined after the first <file id="…"/> reference.
        var fileNodes: [String: XMLElement] = [:]
        for file in descendants(root, named: "file") {
            if let id = file.attribute(forName: "id")?.stringValue, file.child("pathurl") != nil {
                if let prior = fileNodes[id], childText(prior, "pathurl") != childText(file, "pathurl") { throw failure("Conflicting definitions for file ID \(id).") }
                fileNodes[id] = file
            }
        }
        var sourceKeys: [String: String] = [:]
        var sources: [String: LegacySource] = [:]
        var resourceCounter = 2
        for key in fileNodes.keys.sorted() {
            let file = fileNodes[key]!
            let videoSample = file.child("media")?.child("video")?.child("samplecharacteristics")
            let rate = try Rate(file.child("rate") ?? videoSample?.child("rate"), fallback: sequenceRate)
            let video = file.child("media")?.child("video") != nil
            let audio = file.child("media")?.child("audio") != nil
            let sourceOrigin = rate.time(try integer(file.child("timecode"), "frame", fallback: 0))
            let sourceDuration = rate.time(try integer(file, "duration", fallback: 0))
            let sourceID = "r\(resourceCounter)"; resourceCounter += 1
            let formatID: String?
            if video {
                formatID = "r\(resourceCounter)"; resourceCounter += 1
                resources.addChild(makeFormat(id: formatID!, rate: rate,
                                               width: try positiveDimension(childText(videoSample, "width"), fallback: width),
                                               height: try positiveDimension(childText(videoSample, "height"), fallback: height), sample: videoSample))
            } else { formatID = nil }
            sourceKeys[key] = sourceID
            sources[sourceID] = LegacySource(id: sourceID, node: file, rate: rate, origin: sourceOrigin,
                                             length: sourceDuration, video: video, audio: audio,
                                             formatID: formatID, url: resolver.resolve(childText(file, "pathurl") ?? ""))
        }
        var clips: [LegacyClip] = []
        for mediaType in ["video", "audio"] {
            let tracks = sequence.child("media")?.child(mediaType)?.elements(forName: "track") ?? []
            for (trackIndex, track) in tracks.enumerated() {
                let trackEnabled = childText(track, "enabled")?.uppercased() != "FALSE"
                for transition in track.elements(forName: "transitionitem") {
                    warnings.append("Transition '\(childText(transition.child("effect"), "name") ?? "unknown")' on \(mediaType) track \(trackIndex + 1) was replaced by the XML's clip boundaries.")
                }
                for generator in track.elements(forName: "generatoritem") {
                    warnings.append("Generator or title '\(childText(generator, "name") ?? "unknown")' on \(mediaType) track \(trackIndex + 1) is unsupported and was omitted.")
                }
                for node in track.elements(forName: "clipitem") {
                    let clipName = childText(node, "name") ?? "Clip"
                    guard let fileKey = node.child("file")?.attribute(forName: "id")?.stringValue,
                          let sourceID = sourceKeys[fileKey], let source = sources[sourceID] else {
                        warnings.append("Clip '\(clipName)' has no resolvable file definition and was omitted (possibly a nested sequence or generated title).")
                        continue
                    }
                    let startFrame = try integer(node, "start")
                    let endFrame = try integer(node, "end")
                    guard startFrame >= 0, endFrame > startFrame else { throw failure("Clip '\(clipName)' has unsupported or invalid start/end frames. Re-export without legacy transition boundary sentinels (-1).") }
                    let sourceRate = try Rate(node.child("rate"), fallback: source.rate)
                    let inFrame = try integer(node, "in", fallback: 0)
                    let outFrame = try integer(node, "out", fallback: inFrame + endFrame - startFrame)
                    guard inFrame >= 0, outFrame >= inFrame else { throw failure("Clip '\(clipName)' has an invalid source trim.") }
                    let offset = sequenceRate.time(startFrame)
                    let duration = sequenceRate.time(endFrame - startFrame)
                    let sourceStart = source.origin + sourceRate.time(inFrame)
                    let sourceEnd = source.origin + sourceRate.time(outFrame)
                    let neededLength = sourceEnd - source.origin
                    if source.length < neededLength {
                        if source.length != .zero { warnings.append("Source duration for '\(clipName)' was shorter than its trim; the resource duration was expanded to include the trim.") }
                        sources[sourceID]?.length = neededLength
                    }
                    var volume: Double?
                    var volumeKeys: [(Int64, Double)] = []
                    var speedEffect = false
                    var reverse = false
                    for filter in node.elements(forName: "filter") {
                        guard let effect = filter.child("effect") else { continue }
                        let effectID = childText(effect, "effectid")?.lowercased() ?? ""
                        if mediaType == "audio", effectID == "audiolevels" {
                            if let parameter = effect.elements(forName: "parameter").first(where: { childText($0, "parameterid") == "level" }) {
                                volume = try nonnegativeDouble(childText(parameter, "value"), label: "Audio level") ?? (parameter.elements(forName: "keyframe").isEmpty ? nil : 1)
                                for key in parameter.elements(forName: "keyframe") {
                                    let when = try integer(key, "when")
                                    if let value = try nonnegativeDouble(childText(key, "value"), label: "Audio keyframe") { volumeKeys.append((when, value)) }
                                }
                            }
                        } else if effectID == "timeremap" {
                            let params = effect.elements(forName: "parameter")
                            if params.contains(where: { !$0.elements(forName: "keyframe").isEmpty }) {
                                warnings.append("Variable speed on '\(clipName)' is unsupported; its source endpoints and timeline duration were mapped at constant speed.")
                            }
                            speedEffect = true
                            reverse = params.contains(where: { childText($0, "parameterid") == "reverse" && ["TRUE", "1"].contains(childText($0, "value")?.uppercased() ?? "") })
                        } else {
                            warnings.append("Effect '\(childText(effect, "name") ?? effectID)' on '\(clipName)' is unsupported and was omitted.")
                        }
                    }
                    let sourceSpan = sourceEnd - sourceStart
                    let discrepancy = abs(sourceSpan.double - duration.double)
                    let retimed = speedEffect || discrepancy > sequenceRate.frame.double * 0.55
                    if retimed && !speedEffect { warnings.append("Clip '\(clipName)' has different source and timeline lengths; a constant speed mapping preserves both endpoints.") }
                    let sourceTrack = try integer(node.child("sourcetrack"), "trackindex", fallback: 1)
                    clips.append(LegacyClip(node: node, name: clipName, sourceID: sourceID, mediaType: mediaType, trackIndex: trackIndex,
                                            offset: offset, duration: duration, sourceStart: sourceStart, sourceEnd: sourceEnd,
                                            sourceOrigin: source.origin, inFrame: inFrame, outFrame: outFrame, rate: sourceRate, sourceTrack: sourceTrack,
                                            enabled: trackEnabled && childText(node, "enabled")?.uppercased() != "FALSE",
                                            volume: volume, volumeKeys: volumeKeys, retimed: retimed, reverse: reverse))
                }
            }
        }
        guard !clips.isEmpty else { throw failure("The XML contains no supported media clips.") }
        // xmeml lists the audio and picture of each camera edit as separate linked records.
        // FCP currently discards asset-clip.srcEnable, so it must never select components here.
        // Merge only a unique, reciprocal linked pair with exactly matching ranges and state.
        var pairedAudio: [ObjectIdentifier: LegacyClip] = [:]
        var consumedAudio = Set<ObjectIdentifier>()
        for video in clips where video.mediaType == "video" {
            guard let videoID = video.node.attribute(forName: "id")?.stringValue else { continue }
            let linkedAudioIDs = linkedIDs(video.node, type: "audio")
            let candidates = clips.filter { audio in
                guard audio.mediaType == "audio", let audioID = audio.node.attribute(forName: "id")?.stringValue else { return false }
                return linkedAudioIDs.contains(audioID) && linkedIDs(audio.node, type: "video").contains(videoID)
            }
            guard linkedAudioIDs.count == 1, candidates.count == 1, let audio = candidates.first,
                  audio.sourceID == video.sourceID, audio.offset == video.offset, audio.duration == video.duration,
                  audio.sourceStart == video.sourceStart, audio.sourceEnd == video.sourceEnd,
                  audio.rate.fps == video.rate.fps, audio.retimed == video.retimed, audio.reverse == video.reverse,
                  audio.enabled == video.enabled, audio.sourceTrack == 1,
                  linkedIDs(audio.node, type: "video").count == 1,
                  sources[video.sourceID]?.audio == true, sources[video.sourceID]?.video == true,
                  !consumedAudio.contains(ObjectIdentifier(audio.node)) else { continue }
            pairedAudio[ObjectIdentifier(video.node)] = audio
            consumedAudio.insert(ObjectIdentifier(audio.node))
        }
        let placements = clips.filter { !consumedAudio.contains(ObjectIdentifier($0.node)) }
        clipCount = placements.count
        if !pairedAudio.isEmpty {
            warnings.append("Combined \(pairedAudio.count) exact linked video/audio pairs into one editable AV clip per edit; audio gain and automation remain on the combined clip.")
        }
        for id in sources.keys.sorted(by: resourceIDOrder) {
            let source = sources[id]!
            var attrs = ["id": id, "name": childText(source.node, "name") ?? URL(string: source.url)?.lastPathComponent ?? id,
                         "start": source.origin.time, "duration": source.length.time,
                         "hasVideo": source.video ? "1" : "0", "hasAudio": source.audio ? "1" : "0"]
            if let formatID = source.formatID { attrs["format"] = formatID; attrs["videoSources"] = "1" }
            if source.audio {
                let audio = source.node.child("media")?.child("audio")
                attrs["audioSources"] = "1"
                attrs["audioChannels"] = childText(audio, "channelcount") ?? "2"
                attrs["audioRate"] = childText(audio?.child("samplecharacteristics"), "samplerate") ?? "48000"
            }
            let asset = element("asset", attrs)
            asset.addChild(element("media-rep", ["kind": "original-media", "src": source.url]))
            resources.addChild(asset)
        }
        let maximumEnd = clips.map { $0.offset + $0.duration }.max() ?? .zero
        let statedDuration = sequenceRate.time(try integer(sequence, "duration", fallback: 0))
        let timelineDuration = max(statedDuration, maximumEnd)
        if statedDuration < maximumEnd { warnings.append("The stated sequence duration was shorter than its clips; the output includes their complete ranges.") }
        let library = element("library", ["colorProcessing": "standard"])
        let event = element("event", ["name": "ChatCut Import"])
        let project = element("project", ["name": name])
        let outputSequence = element("sequence", ["format": "r1", "duration": timelineDuration.time, "tcStart": tcOrigin.time,
                                                  "tcFormat": tcFormat, "audioLayout": "stereo", "audioRate": "48k"])
        let spine = element("spine")
        outputSequence.addChild(spine); project.addChild(outputSequence); event.addChild(project); library.addChild(event); fcpxml.addChild(library)
        // The lowest video track is the magnetic storyline. Every other track keeps its own lane.
        let primary = placements.filter { $0.mediaType == "video" && $0.trackIndex == 0 }.sorted { $0.offset < $1.offset }
        let hasPrimaryOverlap = zip(primary, primary.dropFirst()).contains { $0.offset + $0.duration > $1.offset }
        var parents: [(offset: Rational, duration: Rational, localStart: Rational, element: XMLElement)] = []
        if primary.isEmpty || hasPrimaryOverlap {
            let gap = element("gap", ["name": "Timeline", "offset": tcOrigin.time, "start": "0s", "duration": timelineDuration.time])
            spine.addChild(gap)
            parents.append((.zero, timelineDuration, .zero, gap))
            if hasPrimaryOverlap { warnings.append("Overlapping clips on the lowest video track were preserved as connected clips above a gap storyline.") }
        } else {
            var cursor = Rational.zero
            for clip in primary {
                if clip.offset > cursor {
                    let gap = element("gap", ["name": "Gap", "offset": (tcOrigin + cursor).time, "start": "0s", "duration": (clip.offset - cursor).time])
                    spine.addChild(gap); parents.append((cursor, clip.offset - cursor, .zero, gap))
                }
                let item = makeClip(clip, pairedAudio: pairedAudio[ObjectIdentifier(clip.node)], source: sources[clip.sourceID]!,
                                    offset: tcOrigin + clip.offset, lane: nil)
                spine.addChild(item)
                parents.append((clip.offset, clip.duration, clip.retimed ? .zero : clip.sourceStart, item))
                cursor = clip.offset + clip.duration
            }
            if cursor < timelineDuration {
                let gap = element("gap", ["name": "Gap", "offset": (tcOrigin + cursor).time, "start": "0s", "duration": (timelineDuration - cursor).time])
                spine.addChild(gap); parents.append((cursor, timelineDuration - cursor, .zero, gap))
            }
        }
        for clip in placements where primary.isEmpty || hasPrimaryOverlap || !(clip.mediaType == "video" && clip.trackIndex == 0) {
            let parent = parents.last(where: { $0.offset <= clip.offset }) ?? parents[0]
            let relativeOffset = parent.localStart + clip.offset - parent.offset
            let lane = clip.mediaType == "video" ? clip.trackIndex + (hasPrimaryOverlap || primary.isEmpty ? 1 : 0) : -(clip.trackIndex + 1)
            appendConnected(makeClip(clip, pairedAudio: pairedAudio[ObjectIdentifier(clip.node)], source: sources[clip.sourceID]!,
                                     offset: relativeOffset, lane: lane), to: parent.element)
        }
        let unsupportedMarkers = descendants(sequence, named: "marker").count
        if unsupportedMarkers > 0 { warnings.append("\(unsupportedMarkers) legacy marker(s) were omitted; review the source XML for their notes.") }
        if clips.contains(where: { !$0.volumeKeys.isEmpty }) {
            warnings.append("Audio gain keyframes were converted to editable decibel values. Zero gain uses the -96 dB floor, and interpolation between gain points may differ from ChatCut.")
        }
        warnings.append("This conversion preserves only information present in the input XML. ChatCut effects, captions, voice isolation and graphics omitted by its export cannot be reconstructed from this file.")
    }

    private func makeClip(_ clip: LegacyClip, pairedAudio: LegacyClip?, source: LegacySource, offset: Rational, lane: Int?) -> XMLElement {
        var attrs = ["name": clip.name, "offset": offset.time,
                     "start": clip.retimed ? "0s" : clip.sourceStart.time, "duration": clip.duration.time,
                     "enabled": clip.enabled ? "1" : "0"]
        if let lane { attrs["lane"] = String(lane) }
        let item: XMLElement
        if pairedAudio != nil {
            attrs["ref"] = clip.sourceID
            attrs["audioRole"] = "dialogue"
            item = element("asset-clip", attrs)
        } else if clip.mediaType == "audio" {
            attrs["ref"] = clip.sourceID
            attrs["role"] = "dialogue"
            if clip.sourceTrack > 1 { attrs["srcID"] = String(clip.sourceTrack) }
            item = element("audio", attrs)
        } else {
            if let format = source.formatID { attrs["format"] = format }
            item = element("clip", attrs)
            // An explicit video component imports as picture only, even from an AV source file.
            let video = element("video", ["ref": clip.sourceID, "name": clip.name, "offset": clip.sourceStart.time,
                                          "start": clip.sourceStart.time, "duration": max(clip.sourceEnd - clip.sourceStart, source.rate.frame).time])
            item.addChild(video)
        }
        if clip.retimed {
            let map = element("timeMap", ["frameSampling": "floor", "preservesPitch": "1"])
            map.addChild(element("timept", ["time": "0s", "value": (clip.reverse ? clip.sourceEnd : clip.sourceStart).time, "interp": "linear"]))
            map.addChild(element("timept", ["time": clip.duration.time, "value": (clip.reverse ? clip.sourceStart : clip.sourceEnd).time, "interp": "linear"]))
            if item.name == "clip" { item.insertChild(map, at: 0) } else { item.addChild(map) }
        }
        let audio = pairedAudio ?? (clip.mediaType == "audio" ? clip : nil)
        if let audio, let volume = audio.volume {
            let adjustment = element("adjust-volume", ["amount": decibels(volume)])
            if !audio.volumeKeys.isEmpty {
                let parameter = element("param", ["name": "amount", "value": decibels(volume)])
                let animation = element("keyframeAnimation")
                let mappedKeys = audio.volumeKeys.map { frame, gain -> (Rational, Double) in
                    // Legacy keyframe `when` is measured in source frames, not from the trim's in point.
                    let time: Rational
                    if audio.retimed {
                        if audio.outFrame > audio.inFrame {
                            let relativeFrame = audio.reverse ? audio.outFrame - frame : frame - audio.inFrame
                            time = audio.duration * Rational(relativeFrame, audio.outFrame - audio.inFrame)
                        } else { time = .zero }
                    } else { time = audio.sourceOrigin + audio.rate.time(frame) }
                    return (time, gain)
                }.sorted { $0.0 < $1.0 }
                for (time, gain) in mappedKeys {
                    // FCP's volume runtime rejects `interp` even though the generic DTD allows it.
                    animation.addChild(element("keyframe", ["time": time.time, "value": decibels(gain), "curve": "linear"]))
                }
                parameter.addChild(animation); adjustment.addChild(parameter)
            } else if volume == 0, pairedAudio == nil {
                item.removeAttribute(forName: "enabled")
                item.addAttribute(XMLNode.attribute(withName: "enabled", stringValue: "0") as! XMLNode)
            }
            item.addChild(adjustment)
            if volume == 0, audio.volumeKeys.isEmpty, pairedAudio != nil {
                // Muting an AV asset must not disable its picture.
                let channelCount = Int(childText(source.node.child("media")?.child("audio"), "channelcount") ?? "2") ?? 2
                let channels = (1...max(1, min(channelCount, 64))).map(String.init).joined(separator: ",")
                item.addChild(element("audio-channel-source", ["srcCh": channels, "role": "dialogue", "enabled": "0"]))
            }
        }
        return item
    }
}

private func makeFormat(id: String, rate: Rate, width: Int, height: Int, sample: XMLElement?) -> XMLElement {
    var attrs = ["id": id, "frameDuration": rate.frame.time, "width": String(width), "height": String(height), "colorSpace": "1-1-1 (Rec. 709)"]
    let dominance = childText(sample, "fielddominance")?.lowercased()
    attrs["fieldOrder"] = dominance == "upper" ? "upper first" : dominance == "lower" ? "lower first" : "progressive"
    return element("format", attrs)
}
private func decibels(_ gain: Double) -> String {
    // Materialize a Double before the C varargs call; an integer -96 branch becomes NaN otherwise.
    let value: Double = gain <= 0 ? -96.0 : max(-96.0, 20 * log10(gain))
    return String(format: "%.6fdB", locale: Locale(identifier: "en_US_POSIX"), value)
}
private func nonnegativeDouble(_ value: String?, label: String) throws -> Double? {
    guard let value else { return nil }
    guard let number = Double(value), number.isFinite, number >= 0, number <= 1_000_000 else { throw failure("\(label) is invalid.") }
    return number
}
private func positiveDimension(_ value: String?, fallback: Int) throws -> Int {
    guard let value else { return fallback }
    guard let number = Int(value), number > 0, number <= 32_768 else { throw failure("Invalid video dimensions.") }
    return number
}
private func integer(_ node: XMLElement?, _ name: String, fallback: Int64? = nil) throws -> Int64 {
    guard let text = childText(node, name) else { if let fallback { return fallback }; throw failure("Required \(name) frame count is absent.") }
    guard let number = Int64(text), number >= -1_000_000_000, number <= 1_000_000_000 else { throw failure("Invalid or excessive \(name) frame count.") }
    return number
}
private func childText(_ node: XMLElement?, _ name: String) -> String? { node?.child(name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
private extension XMLElement { func child(_ name: String) -> XMLElement? { elements(forName: name).first } }
private func descendants(_ node: XMLElement, named: String) -> [XMLElement] {
    var result: [XMLElement] = []
    for child in node.children ?? [] {
        guard let child = child as? XMLElement else { continue }
        if child.name == named { result.append(child) }
        result += descendants(child, named: named)
    }
    return result
}
private func element(_ name: String, _ attributes: [String: String] = [:]) -> XMLElement {
    let node = XMLElement(name: name)
    for key in attributes.keys.sorted() { node.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key]!) as! XMLNode) }
    return node
}
private func failure(_ message: String) -> TimelineConversionError { .invalid(message) }
private func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }
private func resourceIDOrder(_ lhs: String, _ rhs: String) -> Bool { (Int(lhs.dropFirst()) ?? 0) < (Int(rhs.dropFirst()) ?? 0) }
private func linkedIDs(_ node: XMLElement, type: String) -> Set<String> {
    Set(node.elements(forName: "link").filter { childText($0, "mediatype") == type }.compactMap { childText($0, "linkclipref") })
}
private func mediaPlacementCount(_ root: XMLElement) -> Int {
    var count = 0
    func visit(_ node: XMLElement, insidePlacement: Bool) {
        if node.name == "resources" { return }
        let placement = ["asset-clip", "clip", "audio", "video", "ref-clip", "sync-clip", "mc-clip"].contains(node.name ?? "")
        let connected = node.attribute(forName: "lane")?.stringValue.flatMap(Int.init).map { $0 != 0 } ?? false
        if placement && (!insidePlacement || connected) { count += 1 }
        for child in node.children ?? [] {
            if let child = child as? XMLElement { visit(child, insidePlacement: insidePlacement || placement) }
        }
    }
    visit(root, insidePlacement: false)
    return count
}
private func appendConnected(_ anchor: XMLElement, to parent: XMLElement) {
    // DTD story order places anchors before markers, channel adjustments, filters and metadata.
    let postAnchorNames = Set(["marker", "chapter-marker", "rating", "keyword", "analysis-marker",
                               "audio-channel-source", "audio-role-source", "filter-video", "filter-video-mask", "filter-audio", "metadata"])
    if let index = (parent.children ?? []).firstIndex(where: { postAnchorNames.contains($0.name ?? "") }) {
        parent.insertChild(anchor, at: index)
    } else { parent.addChild(anchor) }
}
