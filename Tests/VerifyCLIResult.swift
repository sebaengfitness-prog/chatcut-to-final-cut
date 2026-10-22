import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw NSError(domain: "CLIIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

let resultURL = URL(fileURLWithPath: CommandLine.arguments[1])
let result = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as! [String: Any]
try require(result["clipCount"] as? Int == 12, "CLI must preserve twelve independent synthetic placements")
try require((result["missingMedia"] as? [Any])?.isEmpty == true, "CLI must resolve every temporary source file")
try require((result["warnings"] as? [String])?.contains(where: { $0.contains("Recovered 5 text overlays") }) == true,
            "CLI must recover the matching snapshot's five text overlays")
let outputPath = result["outputPath"] as! String
let reportPath = result["reportPath"] as! String
let scratch = resultURL.deletingLastPathComponent().standardizedFileURL.path + "/"
try require(URL(fileURLWithPath: outputPath).standardizedFileURL.path.hasPrefix(scratch), "CLI output must stay inside the temporary destination")
try require(URL(fileURLWithPath: reportPath).standardizedFileURL.path.hasPrefix(scratch), "CLI report must stay inside the temporary destination")
let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: reportPath))) as! [String: Any]
try require(NSDictionary(dictionary: result).isEqual(to: report), "Printed JSON must describe the report actually saved on disk")
let document = try XMLDocument(contentsOf: URL(fileURLWithPath: outputPath), options: [.nodeLoadExternalEntitiesNever])
try require(try document.nodes(forXPath: "//asset-clip").count == 10, "CLI output must contain ten combined camera AV edits")
try require(try document.nodes(forXPath: "//audio").count == 2, "CLI output must contain only two independent sound effects")
try require(try document.nodes(forXPath: "//title").count == 5, "CLI output must contain all five editable titles")
try require(try document.nodes(forXPath: "//keyframe").count == 24, "CLI output must preserve all 24 gain keyframes")
print("PASS: built app --help and --convert produced verified XML and matching JSON report.")
