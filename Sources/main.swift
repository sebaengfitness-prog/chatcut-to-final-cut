import AppKit
import SwiftUI
import UniformTypeIdentifiers

let productName = "ChatCut to Final Cut"
let home = FileManager.default.homeDirectoryForCurrentUser
let defaultOutput = home.appendingPathComponent("Movies/ChatCut to Final Cut", isDirectory: true)
let inbox = defaultOutput.appendingPathComponent("Inbox", isDirectory: true)

func cli() -> Never {
    let args = Array(CommandLine.arguments.dropFirst())
    func values(_ flag: String) -> [String] {
        args.indices.compactMap { index in args[index] == flag && index + 1 < args.count ? args[index + 1] : nil }
    }
    if args.contains("--help") {
        print("""
        ChatCut to Final Cut
        --convert /path/export.xml [--media-root /path/originals] [--output-dir /path/exports] [--warnings /path/export.warnings.json]
        Repeat --media-root to search more folders. Prints the conversion result as JSON.
        GUI: open this app, choose a ChatCut XML, then Convert. --show-result /path/report.json opens an existing handoff.
        """); exit(0)
    }
    do {
        guard let path = values("--convert").first else { throw NSError(domain: productName, code: 1, userInfo: [NSLocalizedDescriptionKey: "Use --convert with an XML file path."]) }
        let result = try ExportService.convert(inputURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                         mediaRoots: values("--media-root").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                         outputDirectory: values("--output-dir").first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultOutput,
                         warningURL: values("--warnings").first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(result), as: UTF8.self)); exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
}

final class HandoffModel: ObservableObject {
    @Published var input: URL?
    @Published var mediaRoots: [URL] = []
    @Published var output = defaultOutput
    @Published var result: ConversionResult?
    @Published var busy = false
    @Published var dropping = false
    @Published var status = "Choose the XML from your edited ChatCut timeline."
    @Published var error: String?
    @Published var watch = false { didSet { configureWatcher() } }
    private var timer: Timer?
    private var observed: [String: String] = [:]
    private var handled = Set<String>()

    init() {
        if let paths = UserDefaults.standard.stringArray(forKey: "mediaRoots") { mediaRoots = paths.map { URL(fileURLWithPath: $0) } }
        if let path = UserDefaults.standard.string(forKey: "outputDirectory") { output = URL(fileURLWithPath: path) }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }
    func chooseInput() {
        let panel = NSOpenPanel(); panel.title = "Choose ChatCut XML"; panel.allowedContentTypes = [.xml, UTType(filenameExtension: "fcpxml") ?? .xml]
        if panel.runModal() == .OK, let url = panel.url { receive(url) }
    }
    func receive(_ url: URL) {
        guard ["xml", "fcpxml"].contains(url.pathExtension.lowercased()) else { error = "Choose an XML or FCPXML file. Unzip a ChatCut archive first."; return }
        input = url; result = nil; error = nil; status = "Ready to translate \(url.lastPathComponent)."
    }
    func handleDrop(_ provider: NSItemProvider) -> Bool {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { self.receive(url) }
        }
        return true
    }
    func chooseMedia() {
        let panel = NSOpenPanel(); panel.title = "Locate original camera media"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !mediaRoots.contains(url) { mediaRoots.append(url) }
            UserDefaults.standard.set(mediaRoots.map(\.path), forKey: "mediaRoots")
        }
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.title = "Choose output folder"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { output = url; UserDefaults.standard.set(url.path, forKey: "outputDirectory") }
    }
    func convert() {
        guard !busy, let url = input else { return }
        busy = true; result = nil; error = nil; status = "Translating timeline and resolving media…"
        let roots = mediaRoots; let destination = output
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let converted = try ExportService.convert(inputURL: url, mediaRoots: roots, outputDirectory: destination)
                DispatchQueue.main.async { self.result = converted; self.busy = false; self.status = "Created an editable Final Cut timeline." }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.busy = false; self.error = message; self.status = "Conversion needs attention." }
            }
        }
    }
    func loadReport(_ url: URL) {
        do {
            let loaded = try JSONDecoder().decode(ConversionResult.self, from: Data(contentsOf: url))
            result = loaded; input = URL(fileURLWithPath: loaded.inputPath); output = URL(fileURLWithPath: loaded.outputPath).deletingLastPathComponent()
            if let xml = try? XMLDocument(contentsOf: URL(fileURLWithPath: loaded.outputPath), options: [.nodeLoadExternalEntitiesNever]),
               let sources = try? xml.nodes(forXPath: "//asset/media-rep/@src") {
                for source in sources {
                    guard let value = source.stringValue, let file = URL(string: value), file.isFileURL,
                          FileManager.default.isReadableFile(atPath: file.path) else { continue }
                    let parent = file.deletingLastPathComponent()
                    if !mediaRoots.contains(parent) { mediaRoots.append(parent) }
                }
                UserDefaults.standard.set(mediaRoots.map(\.path), forKey: "mediaRoots")
            }
            status = "Export prepared. Review the handoff below."
        }
        catch { self.error = error.localizedDescription }
    }
    func sendToFinalCut() {
        guard let result else { return }
        guard FileManager.default.fileExists(atPath: result.outputPath) else { error = "The FCPXML file has moved. Convert again or locate the output."; return }
        guard let fcp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") else { error = "Final Cut Pro is not installed."; return }
        NSWorkspace.shared.open([URL(fileURLWithPath: result.outputPath)], withApplicationAt: fcp, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            DispatchQueue.main.async { if let err { self.error = err.localizedDescription } else { self.status = "Sent to Final Cut Pro. Choose the destination library there." } }
        }
    }
    func configureWatcher() {
        timer?.invalidate(); timer = nil; observed.removeAll()
        if watch { timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scanInbox() } }
    }
    func scanInbox() {
        guard !busy, let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for file in files.sorted(by: { $0.path < $1.path }) where ["xml", "fcpxml"].contains(file.pathExtension.lowercased()) {
            guard let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = attrs.fileSize, size > 0 else { continue }
            let signature = "\(size):\(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let key = file.path + signature
            guard !handled.contains(key) else { continue }
            if observed[file.path] == signature { handled.insert(key); receive(file); convert(); return }
            observed[file.path] = signature
        }
    }
}

let teal = Color(red: 0.35, green: 0.91, blue: 0.79)
struct HandoffView: View {
    @ObservedObject var model: HandoffModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.right.square.fill").font(.system(size: 40)).foregroundStyle(teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ChatCut → Final Cut").font(.system(size: 27, weight: .semibold))
                    Text("Keep your cuts. Finish with your original media.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("LOCAL HANDOFF").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.1).padding(9).background(teal.opacity(0.12), in: Capsule()).foregroundStyle(teal)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("1  Edited timeline", systemImage: "timeline.selection").font(.headline)
                    Spacer(); Button("Choose XML…") { model.chooseInput() }.keyboardShortcut("o")
                }
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.system(size: 27)).foregroundStyle(teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.input?.lastPathComponent ?? "Drop a ChatCut XML here").font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(model.input?.deletingLastPathComponent().path ?? "Export NLE XML for Premiere Pro from ChatCut.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(model.input?.path ?? "")
                    }
                    Spacer()
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(model.dropping ? teal.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(teal.opacity(model.dropping ? 0.9 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [5])))
                    .onDrop(of: [.fileURL], isTargeted: $model.dropping) { providers in
                        guard let provider = providers.first else { return false }
                        return model.handleDrop(provider)
                    }
                Divider()
                HStack { Label("2  Original media", systemImage: "folder").font(.headline); Spacer(); Button("Add folder…") { model.chooseMedia() } }
                if model.mediaRoots.isEmpty { Text("Add the folder containing your camera originals or the media from a ChatCut archive.").font(.system(size: 12)).foregroundStyle(.secondary) }
                else {
                    ForEach(model.mediaRoots, id: \.path) { url in
                        HStack { Text(url.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(url.path); Spacer(); Button { model.mediaRoots.removeAll { $0 == url }; UserDefaults.standard.set(model.mediaRoots.map(\.path), forKey: "mediaRoots") } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Remove \(url.lastPathComponent)") }
                    }
                }
            }.padding(20).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            HStack { Text("Save to").foregroundStyle(.secondary); Text(model.output.path).lineLimit(1).help(model.output.path); Spacer(); Button("Change…") { model.chooseOutput() } }.font(.system(size: 11))
            HStack(spacing: 12) {
                Button { model.convert() } label: { HStack { if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.2.circlepath") }; Text(model.busy ? "Converting…" : "Convert to Final Cut").fontWeight(.semibold) }.padding(.horizontal, 18).padding(.vertical, 9) }
                    .buttonStyle(.borderedProminent).tint(teal).foregroundStyle(.black).disabled(model.input == nil || model.busy).keyboardShortcut(.return, modifiers: .command)
                Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let result = model.result {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Image(systemName: result.missingMedia.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(result.missingMedia.isEmpty ? teal : .orange); Text(result.projectName).font(.headline); Spacer(); Text("\(result.clipCount) clips").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            if !result.missingMedia.isEmpty { Text("\(result.missingMedia.count) media files need relinking").fontWeight(.semibold).foregroundStyle(.orange); ForEach(result.missingMedia, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) } }
                            ForEach(result.warnings, id: \.self) { warning in Label(warning, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            if result.warnings.isEmpty && result.missingMedia.isEmpty { Text("Media resolved. Timeline ready for import.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 150)
                    HStack {
                        Button("Open in Final Cut Pro") { model.sendToFinalCut() }.buttonStyle(.borderedProminent).tint(teal).foregroundStyle(.black)
                        Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.outputPath)]) }
                        Button("Handoff report") { NSWorkspace.shared.open(URL(fileURLWithPath: result.reportPath)) }
                    }
                }.padding(18).background(teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Toggle("Watch export inbox", isOn: $model.watch).toggleStyle(.switch).controlSize(.small)
                Button("Show inbox") { NSWorkspace.shared.open(inbox) }.buttonStyle(.link)
                Spacer()
                Button("Open ChatCut") { NSWorkspace.shared.open(URL(string: "https://app.chatcut.io")!) }.buttonStyle(.link)
            }.font(.system(size: 11))
            Text("Captions, motion graphics and effects may need separate exports. Review the handoff report before finishing.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 720, minHeight: 690).preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = HandoffModel()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let menu = NSMenu(); menu.addItem(withTitle: "About \(productName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); menu.addItem(.separator()); menu.addItem(withTitle: "Quit \(productName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = menu
        let editRoot = NSMenuItem(); appMenu.addItem(editRoot); let edit = NSMenu(title: "Edit"); edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editRoot.submenu = edit; NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = productName; window.minSize = NSSize(width: 750, height: 780); window.center(); window.contentView = NSHostingView(rootView: HandoffView(model: model)); window.makeKeyAndOrderFront(nil)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--show-result"), index + 1 < args.count { model.loadReport(URL(fileURLWithPath: args[index+1])) }
        else if let path = args.dropFirst().first, !path.hasPrefix("-") { model.receive(URL(fileURLWithPath: path)) }
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { if let path = filenames.first { model.receive(URL(fileURLWithPath: path)); window?.makeKeyAndOrderFront(nil) }; sender.reply(toOpenOrPrint: .success) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--convert") || CommandLine.arguments.contains("--help") { cli() }
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
