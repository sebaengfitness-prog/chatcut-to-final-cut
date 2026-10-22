import Foundation

@main struct TimelineConverterTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ChatCutConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try testLayeredTimeline(scratch)
        try testAmbiguousRelink(scratch)
        try testInputSafety(scratch)
        try testNativePassThrough(scratch)
        try testSpeed(scratch)
        try testLinkedComponentMapping(scratch)
        try testRetimedGain(scratch)
        try testSyntheticLinkedExport(scratch)
        print("PASS: \(assertions) portable converter assertions (installed DTD validation is optional).")
    }
    static func write(_ text: String, _ path: URL) throws { try Data(text.utf8).write(to: path) }
    static func fixture(_ scratch: URL, _ name: String, _ text: String) throws -> URL {
        let url = scratch.appendingPathComponent(name + ".xml")
        try write(text, url)
        return url
    }
    static func nodes(_ document: XMLDocument, _ xpath: String) throws -> [XMLElement] { try document.nodes(forXPath: xpath).compactMap { $0 as? XMLElement } }
    static func attr(_ element: XMLElement, _ name: String) -> String { element.attribute(forName: name)?.stringValue ?? "" }
    static func seconds(_ text: String) -> Double {
        let pieces = text.dropLast().split(separator: "/").compactMap { Double($0) }
        return pieces.count == 2 ? pieces[0] / pieces[1] : pieces.first ?? .nan
    }
    static func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.000001 }
    static let layered = """
    <xmeml version="4"><sequence><name>Layer &amp; Trim Test</name><rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate><duration>120</duration>
    <timecode><frame>108000</frame><displayformat>DF</displayformat></timecode><media><video><format><samplecharacteristics><width>3840</width><height>2160</height></samplecharacteristics></format><track>
    <clipitem><name>First</name><file id="video"/><rate><timebase>60</timebase><ntsc>TRUE</ntsc></rate><start>30</start><end>60</end><in>60</in><out>120</out></clipitem>
    <clipitem><name>Second</name><file id="video"><name>Camera.mp4</name><pathurl>file://./sub/Camera%20Clip.mp4</pathurl><rate><timebase>60</timebase><ntsc>TRUE</ntsc></rate><duration>600</duration><timecode><frame>600</frame></timecode><media><video><samplecharacteristics><width>1920</width><height>1080</height></samplecharacteristics></video><audio><channelcount>2</channelcount></audio></media></file><rate><timebase>60</timebase><ntsc>TRUE</ntsc></rate><start>90</start><end>120</end><in>180</in><out>240</out></clipitem>
    </track><track><clipitem><name>Upper</name><file id="video"/><rate><timebase>60</timebase><ntsc>TRUE</ntsc></rate><start>60</start><end>90</end><in>120</in><out>180</out><filter><effect><effectid>unsupported</effectid><name>Fancy Look</name></effect></filter></clipitem><generatoritem><name>Title</name></generatoritem><transitionitem><effect><name>Dissolve</name></effect></transitionitem></track></video>
    <audio><track><clipitem><name>Sound</name><file id="sound"><name>Sound.wav</name><pathurl>file://./Sound.wav</pathurl><rate><timebase>24</timebase><ntsc>TRUE</ntsc></rate><duration>240</duration><media><audio><channelcount>1</channelcount><samplecharacteristics><samplerate>48000</samplerate></samplecharacteristics></audio></media></file><rate><timebase>24</timebase><ntsc>TRUE</ntsc></rate><start>0</start><end>120</end><in>24</in><out>120</out><filter><effect><effectid>audiolevels</effectid><parameter><parameterid>level</parameterid><value>0.5</value><keyframe><when>0</when><value>0</value></keyframe><keyframe><when>24</when><value>0.5</value></keyframe></parameter></effect></filter></clipitem></track></audio>
    </media></sequence></xmeml>
    """
    static func testLayeredTimeline(_ scratch: URL) throws {
        let media = scratch.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("video", media.appendingPathComponent("sub/Camera Clip.mp4"))
        try write("audio", media.appendingPathComponent("Sound.wav"))
        let input = try fixture(scratch, "layered", layered)
        let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [media], outputDirectory: scratch.appendingPathComponent("output"))
        try expect(result.clipCount == 4, "Preserve all four visual/audio edits")
        try expect(result.missingMedia.isEmpty, "Resolve percent-encoded file://./ paths using an exact relative path")
        let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
        let sequence = try nodes(d, "//sequence")[0]
        let formats = try nodes(d, "//format")
        try expect(formats.contains { attr($0, "frameDuration") == "1001/30000s" }, "Sequence retains NTSC 29.97 rational")
        try expect(formats.contains { attr($0, "frameDuration") == "1001/60000s" }, "Source retains separate NTSC 59.94 rational")
        try expect(attr(sequence, "tcFormat") == "DF", "Drop frame display is retained")
        try expect(close(seconds(attr(sequence, "tcStart")), 3603.6), "Sequence timecode origin is retained")
        try expect(close(seconds(attr(sequence, "duration")), 4.004), "Sequence duration is retained")
        let primary = try nodes(d, "//sequence/spine/clip")
        try expect(primary.count == 2, "Lowest video track is the editable magnetic storyline")
        try expect(try nodes(d, "//sequence/spine/gap").count == 2, "Explicit lead and internal gaps are retained")
        try expect(close(seconds(attr(primary[0], "start")), 11.011), "Source origin plus trim retained")
        try expect(close(seconds(attr(primary[0], "offset")), 3604.601), "Primary timeline start includes sequence tcStart")
        try expect(primary[0].elements(forName: "video").count == 1 && primary[0].elements(forName: "audio").isEmpty, "Unpaired video has an explicit picture component and no implicit source audio")
        let upper = try nodes(d, "//clip[@name='Upper']")[0]
        try expect(attr(upper, "lane") == "1", "Upper visual layer retained as connected clip")
        // It attaches to the gap beginning at 2.002 seconds: gap local timeline starts at zero.
        try expect(attr(upper, "offset") == "0s", "Connected clip offset is expressed in the parent's local coordinate system")
        let audio = try nodes(d, "//audio[@name='Sound']")[0]
        try expect(attr(audio, "lane") == "-1" && attr(audio, "role") == "dialogue", "Independent audio lane is an explicit audio component")
        let volume = try nodes(d, "//audio[@name='Sound']/adjust-volume")[0]
        try expect(attr(volume, "amount") == "-6.020600dB", "Linear gain maps correctly to decibels")
        try expect(try nodes(d, "//keyframe").count == 2, "Gain keyframes remain editable")
        try expect(try nodes(d, "//adjust-volume//keyframe[@interp]").isEmpty, "Volume keyframes omit interpolation attributes rejected by Final Cut Pro at import")
        let gainKeys = try nodes(d, "//audio[@name='Sound']//keyframe")
        try expect(attr(gainKeys[0], "value") == "-96.000000dB", "Zero gain is encoded as a finite Double in the C formatter")
        try expect(attr(gainKeys[0], "time") == "0s" && attr(gainKeys[1], "time") == "1001/1000s", "Legacy gain keyframe times use source frames without adding the trim twice")
        try expect(result.warnings.contains { $0.contains("Fancy Look") }, "Unsupported filter is reported")
        try expect(result.warnings.contains { $0.contains("Title") }, "Unsupported generator is reported")
        try expect(result.warnings.contains { $0.contains("Dissolve") }, "Unsupported transition is reported")
        let report = try JSONDecoder().decode(ConversionResult.self, from: Data(contentsOf: URL(fileURLWithPath: result.reportPath)))
        try expect(report.clipCount == result.clipCount && report.outputPath == result.outputPath, "Conversion report describes the actual saved output")
        let again = try TimelineConverter.convert(inputURL: input, mediaRoots: [media], outputDirectory: scratch.appendingPathComponent("output"))
        try expect(again.outputPath != result.outputPath, "Repeated conversion never overwrites a previous output")
    }
    static func testAmbiguousRelink(_ scratch: URL) throws {
        let root = scratch.appendingPathComponent("ambiguous")
        for directory in ["one", "two"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try write("asset", root.appendingPathComponent(directory + "/Camera Clip.mp4"))
        }
        let input = try fixture(scratch, "ambiguous", layered)
        let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [root], outputDirectory: scratch.appendingPathComponent("ambiguous-output"))
        try expect(result.missingMedia.count == 2, "Ambiguous basename remains offline, alongside absent audio")
        try expect(result.warnings.contains { $0.contains("Ambiguous media name") }, "Ambiguous media gets an explicit warning")
    }
    static func testInputSafety(_ scratch: URL) throws {
        let cases = [
            "<!DOCTYPE xmeml [<!ENTITY xxe SYSTEM 'file:///etc/passwd'>]><xmeml>&xxe;</xmeml>",
            "<!DOCTYPE xmeml SYSTEM 'https://example.com/evil.dtd'><xmeml/>",
            "<html><sequence/></html>",
            "<xmeml xmlns='https://example.com/custom'><sequence/></xmeml>",
            String(repeating: "<x>", count: 140) + String(repeating: "</x>", count: 140),
            layered.replacingOccurrences(of: "<start>30</start>", with: "<start>-9223372036854775808</start>"),
            layered.replacingOccurrences(of: "<start>30</start>", with: "<start>-1</start>")
        ]
        for (index, xml) in cases.enumerated() {
            let input = try fixture(scratch, "unsafe\(index)", xml)
            var rejected = false
            do { _ = try TimelineConverter.convert(inputURL: input, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("unsafe-output")) }
            catch { rejected = true }
            try expect(rejected, "Reject unsafe or malformed input \(index)")
        }
    }
    static func testNativePassThrough(_ scratch: URL) throws {
        let native = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE fcpxml><fcpxml version="1.10"><resources><format id="r1" frameDuration="1/25s" width="1920" height="1080"/><asset id="r2" name="Native" start="0s" duration="10s" hasVideo="1" format="r1"><media-rep kind="original-media" src="./media/sub/Camera%20Clip.mp4" sig="old"><bookmark>OLD</bookmark></media-rep></asset></resources><project name="Native"><sequence format="r1" duration="5s"><spine><asset-clip ref="r2" start="0s" duration="5s"><timeMap><timept time="0s" value="0s"/><timept time="5s" value="10s"/></timeMap><adjust-transform scale="1.1 1.1"/></asset-clip></spine></sequence></project></fcpxml>
        """
        let input = try fixture(scratch, "native", native)
        let original = try Data(contentsOf: input)
        let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("native-output"))
        let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
        try expect(result.missingMedia.isEmpty, "Native relative URL is resolved against its input directory")
        try expect(try nodes(d, "//timeMap/timept").count == 2, "Native time map is preserved")
        try expect(try nodes(d, "//adjust-transform").count == 1, "Native effect is preserved")
        let rep = try nodes(d, "//media-rep")[0]
        try expect(attr(rep, "src").hasPrefix("file:///"), "Native relative file URL becomes absolute for a relocated output")
        try expect(try nodes(d, "//bookmark").isEmpty && attr(rep, "sig").isEmpty, "Relinking discards stale source bookmarks and signatures")
        try expect(try Data(contentsOf: input) == original, "Native input file stays unchanged")
        try expect(result.clipCount == 1, "Native media placement count excludes resources and inner component nodes")
    }
    static func testSpeed(_ scratch: URL) throws {
        let speed = layered.replacingOccurrences(of: "<out>120</out></clipitem>", with: "<out>180</out><filter><effect><effectid>timeremap</effectid><parameter><parameterid>speed</parameterid><value>200</value></parameter></effect></filter></clipitem>")
        let input = try fixture(scratch, "speed", speed)
        let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [scratch.appendingPathComponent("media")], outputDirectory: scratch.appendingPathComponent("speed-output"))
        let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
        let first = try nodes(d, "//clip[@name='First']")[0]
        try expect(attr(first, "start") == "0s", "Retimed clip starts in its adjusted local timeline")
        let points = try nodes(d, "//clip[@name='First']/timeMap/timept")
        try expect(points.count == 2, "Constant speed gets a valid native time map")
        try expect(close(seconds(attr(points[1], "value")) - seconds(attr(points[0], "value")), 2.002), "Speed map preserves the exact source interval")
        try expect(close(seconds(attr(points[1], "time")), 1.001), "Speed map preserves timeline duration")
    }
    static func testSyntheticLinkedExport(_ scratch: URL) throws {
        let media = try SyntheticFixtures.makeMedia(in: scratch)
        let original = try Data(contentsOf: SyntheticFixtures.inputURL)
        let result = try TimelineConverter.convert(inputURL: SyntheticFixtures.inputURL, mediaRoots: [media],
                                                   outputDirectory: scratch.appendingPathComponent("synthetic-output"))
        let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
        try expect(result.clipCount == 12, "Ten linked AV pairs and two sound effects become twelve independent placements")
        try expect(try nodes(d, "//asset").count == 3, "Repeated file references resolve to three synthetic source assets")
        try expect(try nodes(d, "//asset-clip").count == 10, "Each exact linked camera pair becomes one editable AV placement")
        try expect(try nodes(d, "//audio").count == 2 && nodes(d, "//clip").isEmpty, "Only independent sound effects occupy separate audio components")
        try expect(try nodes(d, "//sequence/spine/asset-clip").count == 6 && nodes(d, "//asset-clip[@lane='1']").count == 4, "All six primary and four connected edits survive, including genuine overlaps")
        try expect(try nodes(d, "//*[@srcEnable]").isEmpty, "Generated AV placements do not use component-selection attributes discarded by Final Cut")
        try expect(try nodes(d, "//adjust-volume").count == 6 && nodes(d, "//keyframe").count == 24, "All synthetic AV and sound-effect gain envelopes remain editable")
        try expect(try nodes(d, "//adjust-volume//keyframe[@interp]").isEmpty, "Volume automation omits unsupported interpolation attributes")
        let keys = try nodes(d, "//keyframe")
        try expect(keys.allSatisfy { Double(attr($0, "value").replacingOccurrences(of: "dB", with: ""))?.isFinite == true }, "Gain automation contains only finite numeric values")
        try expect(keys.filter { attr($0, "value") == "-96.000000dB" }.count == 12, "Both endpoints of every synthetic gain envelope remain muted")
        let trimmed = try nodes(d, "//asset-clip[@name='Upper 01']")[0]
        let firstKey = try nodes(d, "//asset-clip[@name='Upper 01']//keyframe")[0]
        try expect(attr(trimmed, "start") == "1001/2000s" && attr(firstKey, "time") == "1001/2000s", "Trimmed camera audio begins its fade at the source in-point, not twice that in-point")
        try expect(result.missingMedia.isEmpty, "All synthetic media resolve inside the temporary test directory")
        if ProcessInfo.processInfo.environment["CHATCUT_EXPECT_NO_FCP"] == "1" {
            try expect(TimelineConverter.installedDTD(version: "1.10") == nil, "This portable run cannot access an installed Final Cut DTD")
            try expect(result.warnings.contains { $0.contains("schema validation was unavailable") }, "Without Final Cut, conversion succeeds and clearly reports unavailable schema validation")
        }
        let format = try nodes(d, "//format[@id='r1']")[0]
        try expect(attr(format, "frameDuration") == "1001/24000s" && attr(format, "width") == "3840", "Synthetic export retains 4K NTSC 23.976 settings")
        let sequence = try nodes(d, "//sequence")[0]
        try expect(close(seconds(attr(sequence, "duration")), 240 * 1001.0 / 24000), "Exported sequence keeps the exact synthetic frame count")
        try expect(try Data(contentsOf: SyntheticFixtures.inputURL) == original, "Conversion never changes the public source fixture")
    }

    static let componentFixture = """
    <xmeml version="4"><sequence><name>Linked Components</name><rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate><duration>200</duration><media><video><format><samplecharacteristics><width>1920</width><height>1080</height></samplecharacteristics></format><track>
    <clipitem id="v1"><name>Paired Primary</name><file id="f"><name>Camera.mp4</name><pathurl>file://./Camera.mp4</pathurl><rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate><duration>250</duration><timecode><frame>2500</frame></timecode><media><video><samplecharacteristics><width>1920</width><height>1080</height></samplecharacteristics></video><audio><channelcount>2</channelcount></audio></media></file><start>0</start><end>100</end><in>25</in><out>125</out><link><linkclipref>a1</linkclipref><mediatype>audio</mediatype></link></clipitem>
    <clipitem id="v3"><name>Detached Picture</name><file id="f"/><start>100</start><end>150</end><in>150</in><out>200</out><link><linkclipref>a4</linkclipref><mediatype>audio</mediatype></link></clipitem>
    </track><track><clipitem id="v2"><name>Muted Upper</name><file id="f"/><start>25</start><end>75</end><in>150</in><out>200</out><link><linkclipref>a2</linkclipref><mediatype>audio</mediatype></link></clipitem></track></video><audio><track>
    <clipitem id="a1"><name>Paired Primary Sound</name><file id="f"/><start>0</start><end>100</end><in>25</in><out>125</out><link><linkclipref>v1</linkclipref><mediatype>video</mediatype></link><filter><effect><effectid>audiolevels</effectid><parameter><parameterid>level</parameterid><value>0.5</value><keyframe><when>25</when><value>0</value></keyframe><keyframe><when>27</when><value>0.5</value></keyframe><keyframe><when>123</when><value>0.5</value></keyframe><keyframe><when>125</when><value>0</value></keyframe></parameter></effect></filter></clipitem>
    <clipitem id="a3"><name>Unlinked Same Range Sound</name><file id="f"/><start>100</start><end>150</end><in>150</in><out>200</out></clipitem>
    </track><track><clipitem id="a2"><name>Muted Upper Sound</name><file id="f"/><start>25</start><end>75</end><in>150</in><out>200</out><link><linkclipref>v2</linkclipref><mediatype>video</mediatype></link><filter><effect><effectid>audiolevels</effectid><parameter><parameterid>level</parameterid><value>0</value></parameter></effect></filter></clipitem></track><track>
    <clipitem id="a4"><name>J L Sound</name><file id="f"/><start>95</start><end>160</end><in>145</in><out>210</out><link><linkclipref>v3</linkclipref><mediatype>video</mediatype></link></clipitem>
    </track></audio></media></sequence></xmeml>
    """
    static func testLinkedComponentMapping(_ scratch: URL) throws {
        let input = try fixture(scratch, "components", componentFixture)
        let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("component-output"))
        let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
        try expect(result.clipCount == 5, "Two exact linked pairs merge; unmatched picture and both independent audio placements remain")
        try expect(try nodes(d, "//asset-clip").count == 2 && nodes(d, "//clip").count == 1 && nodes(d, "//audio").count == 2, "Merged AV, picture-only and audio-only component structures are distinct")
        try expect(try nodes(d, "//*[@srcEnable]").isEmpty, "Output has no asset-clip component-selection attributes")
        let primary = try nodes(d, "//asset-clip[@name='Paired Primary']")[0]
        try expect(try nodes(d, "//asset-clip[@name='Paired Primary']/adjust-volume").count == 1, "Merged AV item carries its linked audio's gain")
        let keys = try nodes(d, "//asset-clip[@name='Paired Primary']//keyframe")
        try expect(attr(keys[0], "time") == "101s" && attr(keys.last!, "time") == "105s", "Audio automation includes source timecode origin and each source frame exactly once")
        try expect(keys.allSatisfy { seconds(attr($0, "time")) >= seconds(attr(primary, "start")) && seconds(attr($0, "time")) <= seconds(attr(primary, "start")) + seconds(attr(primary, "duration")) }, "Gain envelope falls inside its edited media range")
        try expect(attr(keys[0], "value") == "-96.000000dB" && attr(keys[1], "value") == "-6.020600dB", "Zero and nonzero gains remain finite and exact")
        let upper = try nodes(d, "//asset-clip[@name='Muted Upper']")[0]
        try expect(attr(upper, "lane") == "1" && attr(upper, "enabled") == "1", "Genuine upper-layer picture remains visible when its paired audio is muted")
        let disabledChannels = try nodes(d, "//asset-clip[@name='Muted Upper']/audio-channel-source[@enabled='0']")
        try expect(disabledChannels.count == 1 && attr(disabledChannels[0], "srcCh") == "1,2", "A flat-zero audio gain disables both audio channels without disabling picture")
        let detached = try nodes(d, "//clip[@name='Detached Picture']")[0]
        try expect(detached.elements(forName: "video").count == 1 && detached.elements(forName: "audio").filter { attr($0, "lane").isEmpty || attr($0, "lane") == "0" }.isEmpty, "J/L picture retains an explicit video-only component, with detached audio anchored in a separate lane")
        try expect(try nodes(d, "//audio[@name='J L Sound']").count == 1 && nodes(d, "//audio[@name='Unlinked Same Range Sound']").count == 1, "J/L audio and unlinked matching-range audio are never merged by coincidence")
        let native = try TimelineConverter.convert(inputURL: URL(fileURLWithPath: result.outputPath), mediaRoots: [], outputDirectory: scratch.appendingPathComponent("native-components"))
        try expect(native.clipCount == 5, "Native pass-through counts placements rather than their internal video components")
        let mutedPrimaryXML = componentFixture.replacingOccurrences(of: #"<keyframe>.*?</keyframe>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<value>0.5</value>", with: "<value>0</value>")
        let mutedInput = try fixture(scratch, "muted-primary", mutedPrimaryXML)
        let mutedResult = try TimelineConverter.convert(inputURL: mutedInput, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("muted-primary-output"))
        let mutedDocument = try XMLDocument(contentsOf: URL(fileURLWithPath: mutedResult.outputPath), options: [.nodeLoadExternalEntitiesNever])
        let mutedPrimary = try nodes(mutedDocument, "//asset-clip[@name='Paired Primary']")[0]
        let mutedChildren = (mutedPrimary.children ?? []).compactMap { $0 as? XMLElement }
        let channelsIndex = mutedChildren.firstIndex { $0.name == "audio-channel-source" }!
        let anchorIndices = mutedChildren.indices.filter { mutedChildren[$0].name == "asset-clip" || mutedChildren[$0].name == "audio" }
        try expect(!anchorIndices.isEmpty && anchorIndices.allSatisfy { $0 < channelsIndex }, "Connected video and detached audio precede static-muted primary AV channel adjustments, preserving valid DTD order")
        try expect(mutedResult.clipCount == 5 && attr(mutedPrimary, "enabled") == "1", "Muted AV primary preserves all media placements and its visible picture")
        let variants = [
            componentFixture.replacingOccurrences(of: "<name>Paired Primary Sound</name>", with: "<name>Paired Primary Sound</name><enabled>FALSE</enabled>"),
            componentFixture.replacingOccurrences(of: "<name>Paired Primary Sound</name><file", with: "<name>Paired Primary Sound</name><sourcetrack><trackindex>2</trackindex></sourcetrack><file"),
            componentFixture.replacingOccurrences(of: "<linkclipref>a1</linkclipref><mediatype>audio</mediatype></link>", with: "<linkclipref>a1</linkclipref><mediatype>audio</mediatype></link><link><linkclipref>a3</linkclipref><mediatype>audio</mediatype></link>")
        ]
        for (index, xml) in variants.enumerated() {
            let input = try fixture(scratch, "component-edge\(index)", xml)
            let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("component-edge-output\(index)"))
            try expect(result.clipCount == 6, "Enabled-state, source-channel or multiple-link ambiguity prevents merging variant \(index)")
        }
    }
    static func testRetimedGain(_ scratch: URL) throws {
        let rate25 = "<rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>"
        for reverse in [false, true] {
            let input = try fixture(scratch, "retimed-gain-\(reverse)", """
            <xmeml><sequence><name>Retimed gain</name>\(rate25)<duration>50</duration><media><audio><track><clipitem><name>Retimed sound</name><file id="f"><name>Sound.wav</name><pathurl>file://./Sound.wav</pathurl>\(rate25)<duration>200</duration><media><audio><channelcount>2</channelcount></audio></media></file><start>0</start><end>50</end><in>25</in><out>125</out><filter><effect><effectid>timeremap</effectid><parameter><parameterid>reverse</parameterid><value>\(reverse ? "TRUE" : "FALSE")</value></parameter></effect></filter><filter><effect><effectid>audiolevels</effectid><parameter><parameterid>level</parameterid><value>0.5</value><keyframe><when>25</when><value>0</value></keyframe><keyframe><when>75</when><value>0.5</value></keyframe><keyframe><when>125</when><value>1</value></keyframe></parameter></effect></filter></clipitem></track></audio></media></sequence></xmeml>
            """)
            let result = try TimelineConverter.convert(inputURL: input, mediaRoots: [], outputDirectory: scratch.appendingPathComponent("retimed-gain-output\(reverse)"))
            let d = try XMLDocument(contentsOf: URL(fileURLWithPath: result.outputPath), options: [.nodeLoadExternalEntitiesNever])
            let keys = try nodes(d, "//audio//keyframe")
            try expect(keys.map { attr($0, "time") } == ["0s", "1s", "2s"], "Retimed gain keys map into the adjusted timeline and sort chronologically for reverse=\(reverse)")
            try expect(attr(keys[0], "value") == (reverse ? "0.000000dB" : "-96.000000dB"), "Reversed retiming preserves endpoint gains")
        }
    }

}
struct TestFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
