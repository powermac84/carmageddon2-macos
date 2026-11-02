// SPDX-License-Identifier: GPL-3.0-or-later
// Native, local-only importer. Never executes a game installer or selected JS.
import Foundation
import CryptoKit

struct ImportFailure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
struct GameFile: Codable { let filename: String; let start: Int64; let end: Int64 }
struct DataPart: Codable { let name: String; let size: Int64; let sha256: String }
struct ImportManifest: Codable {
    let schemaVersion: Int
    let format: String
    let totalSize: Int64
    let engineSha256: String
    let sourceKind: String
    let files: [GameFile]
    let parts: [DataPart]
    let musicTracks: [String]
    let movies: [String]
    let warnings: [String]
}

let fm = FileManager.default
let partSize: Int64 = 20 * 1024 * 1024
let maximumSize: Int64 = 1536 * 1024 * 1024
let knownEngines: Set<String> = [
    "9b896c2cbb170c01b3e9f904ce5e1808db29fe5b51184a5d55a6d19b1799b58d",
    "698c2b11865578b6ea2a77324fbc1840080841a8ae4041e9ca14ca5ff027bd6c"
]
let required = ["carma2_hw.exe", "3dfx_win.bdd", "data/common/", "data/cars/", "data/races/", "data/intrface/", "data/sound/"]
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let helperFolder = executable.deletingLastPathComponent()
let defaultTemplate = helperFolder.deletingLastPathComponent().appendingPathComponent("Resources/Import/data-loader.js.template")

func message(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func jsonText<T: Encodable>(_ object: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(object), as: UTF8.self)
}
func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func size(_ url: URL) throws -> Int64 { (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
func children(_ url: URL) -> [URL] { (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [] }
func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
func resolvedPath(_ url: URL) -> URL {
    // URL.resolvingSymlinksInPath() alone does not resolve existing parent links
    // when the final destination does not exist yet.
    var ancestor = url.standardizedFileURL, missing: [String] = []
    while !fm.fileExists(atPath: ancestor.path) {
        let parent = ancestor.deletingLastPathComponent()
        if parent == ancestor { break }
        missing.insert(ancestor.lastPathComponent, at: 0); ancestor = parent
    }
    var result = ancestor.resolvingSymlinksInPath()
    for component in missing { result.appendPathComponent(component) }
    return result.standardizedFileURL
}
func inside(_ child: URL, _ root: URL) -> Bool {
    let p = resolvedPath(child).path, r = resolvedPath(root).path
    return p == r || p.hasPrefix(r + "/")
}
func find(_ root: URL, _ relative: String) throws -> URL {
    var result = root
    for component in relative.split(separator: "/") {
        let matches = children(result).filter { $0.lastPathComponent.lowercased() == component.lowercased() }
        guard matches.count == 1 else { throw ImportFailure("Missing or ambiguous game item: \(relative)") }
        result = matches[0]
        guard inside(result, root) else { throw ImportFailure("Game data contains a link outside the selected folder.") }
    }
    return result
}
func validFilename(_ filename: String) -> Bool {
    guard filename.hasPrefix("/carma2/"), !filename.contains("\\"), !filename.contains("\0") else { return false }
    let components = filename.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
func checkFiles(_ files: [GameFile], total: Int64) throws {
    guard total > 0 && total <= maximumSize, !files.isEmpty && files.count <= 50000 else { throw ImportFailure("Invalid or oversized game-data package.") }
    var offset: Int64 = 0, paths = Set<String>()
    for file in files {
        guard validFilename(file.filename), file.start == offset, file.end >= file.start, file.end <= total,
              paths.insert(file.filename.lowercased()).inserted else { throw ImportFailure("Invalid file path, duplicate name, or file range in the data package.") }
        offset = file.end
    }
    guard offset == total else { throw ImportFailure("The game-data package has incomplete file ranges.") }
    let pathsArray = Array(paths)
    for item in required {
        guard pathsArray.contains(where: { item.hasSuffix("/") ? $0.hasPrefix("/carma2/" + item) : $0 == "/carma2/" + item }) else {
            throw ImportFailure("Required game data is missing: \(item). Import a supported installed PC/GOG copy.")
        }
    }
}
func readRange(_ folder: URL, start: Int64, end: Int64) throws -> Data {
    guard start >= 0, end >= start, end - start <= 32 * 1024 * 1024 else { throw ImportFailure("Invalid engine file range.") }
    var result = Data(), offset = start
    while offset < end {
        let number = offset / partSize, local = offset % partSize
        let part = folder.appendingPathComponent(String(format: "carma2web.data.%03lld", number))
        guard inside(part, folder) else { throw ImportFailure("Invalid data-part link.") }
        let handle = try FileHandle(forReadingFrom: part); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(local))
        let needed = Int(min(partSize - local, end - offset))
        let bytes = try handle.read(upToCount: needed) ?? Data()
        guard bytes.count == needed else { throw ImportFailure("Incomplete game-data part: \(part.lastPathComponent)") }
        result.append(bytes); offset += Int64(bytes.count)
    }
    return result
}
func engineHash(_ folder: URL, files: [GameFile]) throws -> String {
    guard let entry = files.first(where: { $0.filename.lowercased() == "/carma2/carma2_hw.exe" }) else { throw ImportFailure("The compatible Windows engine is missing. Classic Mac-only PowerPC data cannot boot this runtime.") }
    let bytes = try readRange(folder, start: entry.start, end: entry.end)
    guard bytes.count >= 64, bytes[0] == 0x4d, bytes[1] == 0x5a else { throw ImportFailure("The selected game engine is not a Windows executable.") }
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard knownEngines.contains(hash) else { throw ImportFailure("Unsupported CARMA2_HW.EXE (SHA-256 \(hash)). Use the supported GOG 2.1.0.28 installation; no game executable is downloaded or supplied by this app.") }
    return hash
}
func validated(_ folder: URL, template: URL = defaultTemplate) throws -> ImportManifest {
    let url = folder.appendingPathComponent("carma2data.manifest.json")
    guard try size(url) < 16 * 1024 * 1024, inside(url, folder) else { throw ImportFailure("Invalid game-data manifest.") }
    let manifest = try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
    guard manifest.schemaVersion == 1, manifest.format == "carma2web.parts.v1" else { throw ImportFailure("Unsupported game-data manifest version.") }
    try checkFiles(manifest.files, total: manifest.totalSize)
    guard manifest.parts.count == Int((manifest.totalSize + partSize - 1) / partSize), knownEngines.contains(manifest.engineSha256) else { throw ImportFailure("Incomplete or unsupported game-data package.") }
    for (i, part) in manifest.parts.enumerated() {
        let expectedName = String(format: "carma2web.data.%03d", i)
        let expectedSize = min(partSize, manifest.totalSize - Int64(i) * partSize)
        let path = folder.appendingPathComponent(part.name)
        guard part.name == expectedName, inside(path, folder), part.size == expectedSize,
              try size(path) == part.size, try digest(path) == part.sha256 else { throw ImportFailure("Missing or damaged game-data part: \(expectedName)") }
    }
    guard try engineHash(folder, files: manifest.files) == manifest.engineSha256 else { throw ImportFailure("Engine verification failed.") }
    let loaderURL = folder.appendingPathComponent("carma2data.js")
    guard inside(loaderURL, folder), (try loaderURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ImportFailure("External or symbolic data-loader links are not accepted.") }
    let actualLoader = try String(contentsOf: loaderURL, encoding: .utf8)
    guard actualLoader == (try loaderText(manifest: manifest, template: template)) else { throw ImportFailure("The generated data loader has changed. Re-import the original files to recreate it safely.") }
    guard Set(manifest.musicTracks).count == manifest.musicTracks.count, Set(manifest.movies).count == manifest.movies.count else { throw ImportFailure("Duplicate media entries in the manifest.") }
    let trackPattern = try NSRegularExpression(pattern: "^Track(?:0[2-9]|[1-9][0-9])\\.(ogg|mp3|wav)$")
    for name in manifest.musicTracks {
        guard trackPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { throw ImportFailure("Invalid music filename in the manifest.") }
        try validateMedia(folder.appendingPathComponent("music/" + name), root: folder)
    }
    for name in manifest.movies {
        guard ["mix_intr.mp4", "toprank.mp4"].contains(name) else { throw ImportFailure("Invalid movie filename in the manifest.") }
        try validateMedia(folder.appendingPathComponent("video/" + name), root: folder)
    }
    return manifest
}
func validateMedia(_ url: URL, root: URL) throws {
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard inside(url, root), properties.isRegularFile == true, properties.isSymbolicLink != true, try size(url) > 0 else { throw ImportFailure("Missing or externally linked media: \(url.lastPathComponent)") }
}

func process(_ program: URL, _ arguments: [String]) throws {
    guard fm.isExecutableFile(atPath: program.path) else { throw ImportFailure("Required native helper is missing: \(program.lastPathComponent). Reinstall the complete release package.") }
    let p = Process(); p.executableURL = program; p.arguments = arguments
    // Helpers write progress to stderr; never mix tool output into the JSON result.
    p.standardOutput = FileHandle.standardError; p.standardError = FileHandle.standardError
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw ImportFailure("\(program.lastPathComponent) could not process the selected files. Choose a supported installed game folder instead.") }
}

func locate(_ source: URL) throws -> (URL, Bool) {
    let predefined = [source, source.appendingPathComponent("Contents/Resources/site"), source.appendingPathComponent("GameData"), source.appendingPathComponent("app")]
    var queue = predefined.map { ($0, 0) }, visited = Set<String>()
    while !queue.isEmpty && visited.count < 15000 {
        let (folder, depth) = queue.removeFirst()
        guard isDirectory(folder), inside(folder, source), visited.insert(folder.path).inserted else { continue }
        let names = Set(children(folder).map { $0.lastPathComponent.lowercased() })
        if names.contains("carma2data.js"), names.contains("carma2web.data.000") { return (folder, true) }
        if names.contains("carma2_hw.exe") && names.contains("data") { return (folder, false) }
        if depth < 7 {
            for child in children(folder) where isDirectory(child) && !["node_modules", ".git", "savegame"].contains(child.lastPathComponent.lowercased()) { queue.append((child, depth + 1)) }
        }
    }
    throw ImportFailure("No supported Carmageddon II PC/GOG installation was found. Select the folder containing CARMA2_HW.EXE and DATA, a compatible existing Mac wrapper, or a GOG setup EXE. Original Classic Mac-only PowerPC media is not supported by this engine.")
}

func legacyMetadata(_ folder: URL) throws -> ([GameFile], Int64) {
    let loaderURL = folder.appendingPathComponent("carma2data.js")
    guard inside(loaderURL, folder), try size(loaderURL) < 16 * 1024 * 1024 else { throw ImportFailure("Invalid legacy data loader.") }
    let text = try String(contentsOf: loaderURL, encoding: .utf8)
    guard let marker = text.range(of: "loadPackage(", options: .backwards), let first = text[marker.upperBound...].firstIndex(of: "{") else { throw ImportFailure("The existing wrapper has an unsupported data loader.") }
    var depth = 0, quoted = false, escaped = false, closing: String.Index?
    for i in text[first...].indices {
        let c = text[i]
        if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }; continue }
        if c == "\"" { quoted = true } else if c == "{" || c == "[" { depth += 1 } else if c == "}" || c == "]" { depth -= 1; if depth == 0 { closing = i; break } }
    }
    guard let last = closing, let object = try JSONSerialization.jsonObject(with: Data(text[first...last].utf8)) as? [String: Any],
          let raw = object["files"], let total = (object["remote_package_size"] as? NSNumber)?.int64Value else { throw ImportFailure("Invalid legacy package metadata.") }
    let files = try JSONDecoder().decode([GameFile].self, from: JSONSerialization.data(withJSONObject: raw))
    try checkFiles(files, total: total); return (files, total)
}

func loaderText(manifest: ImportManifest, template: URL) throws -> String {
    var directories = Set<String>()
    for file in manifest.files {
        var path = (file.filename as NSString).deletingLastPathComponent
        while path != "/" && !path.isEmpty { directories.insert(path); path = (path as NSString).deletingLastPathComponent }
    }
    let paths = try directories.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }.map { path -> String in
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        return "        Module['FS_createPath'](\(try jsonText(parent)), \(try jsonText(name)), true, true);"
    }.joined(separator: "\n")
    let parts = manifest.parts.enumerated().map { [Int64($0.offset) * partSize, $0.element.size] }
    let metadata: [String: Any] = ["files": try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.files)), "remote_package_size": manifest.totalSize]
    var loader = try String(contentsOf: template, encoding: .utf8)
    guard loader.contains("__METADATA_JSON__") else { throw ImportFailure("Invalid bundled loader template.") }
    loader = loader.replacingOccurrences(of: "__PARTS_JSON__", with: try jsonText(parts)).replacingOccurrences(of: "__PATHS_JS__", with: paths).replacingOccurrences(of: "__METADATA_JSON__", with: String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self))
    return loader
}
func generateLoader(_ folder: URL, manifest: ImportManifest, template: URL) throws {
    try loaderText(manifest: manifest, template: template).write(to: folder.appendingPathComponent("carma2data.js"), atomically: true, encoding: .utf8)
    try Data(jsonText(manifest).utf8).write(to: folder.appendingPathComponent("carma2data.manifest.json"), options: .atomic)
}

func rawFiles(_ folder: URL) throws -> [(String, URL)] {
    var files: [(String, URL)] = [], names = Set<String>()
    let topExtensions: Set<String> = ["exe", "dll", "bdd", "txt", "ini", "fli", "pal"]
    for top in children(folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        if isDirectory(top) {
            guard top.lastPathComponent.lowercased() == "data" else { continue }
            guard let walker = fm.enumerator(at: top, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard inside(url, folder) else { throw ImportFailure("Game folder contains a link outside its root.") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw ImportFailure("Symbolic links are not accepted inside game data.") }
                if values.isRegularFile == true {
                    let relative = String(url.path.dropFirst(folder.path.count + 1))
                    if relative.split(separator: "/").contains(where: { ["savegame", "savegames", ".git", "__macosx"].contains($0.lowercased()) }) { continue }
                    files.append((relative, url))
                }
            }
        } else if topExtensions.contains(top.pathExtension.lowercased()) {
            guard inside(top, folder) else { throw ImportFailure("External links are not accepted.") }
            files.append((top.lastPathComponent.lowercased() == "carma2_hw.exe" ? "carma2_HW.exe" : top.lastPathComponent, top))
        }
    }
    for (name, _) in files { guard names.insert(name.lowercased()).inserted else { throw ImportFailure("Ambiguous case-insensitive game filename: \(name)") } }
    return files.sorted { $0.0 < $1.0 }
}

func pack(_ source: URL, into stage: URL) throws -> ([GameFile], Int64) {
    let files = try rawFiles(source)
    var metadata: [GameFile] = [], offset: Int64 = 0, number = 0, currentSize: Int64 = 0
    var output: FileHandle?
    defer { try? output?.close() }
    for (relative, url) in files {
        let length = try size(url)
        guard length >= 0 && length <= maximumSize - offset else { throw ImportFailure("The selected data exceeds the supported package size.") }
        metadata.append(GameFile(filename: "/carma2/" + relative, start: offset, end: offset + length))
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            var consumed = 0
            while consumed < chunk.count {
                if output == nil {
                    let part = stage.appendingPathComponent(String(format: "carma2web.data.%03d", number))
                    guard fm.createFile(atPath: part.path, contents: nil) else { throw ImportFailure("Could not create data package.") }
                    output = try FileHandle(forWritingTo: part)
                }
                let count = min(chunk.count - consumed, Int(partSize - currentSize))
                try output!.write(contentsOf: chunk.subdata(in: consumed..<(consumed + count)))
                consumed += count; offset += Int64(count); currentSize += Int64(count)
                if currentSize == partSize { try output!.close(); output = nil; currentSize = 0; number += 1 }
            }
        }
    }
    try output?.close(); output = nil
    try checkFiles(metadata, total: offset)
    return (metadata, offset)
}

func importMedia(_ source: URL, into stage: URL, packed: Bool) throws -> ([String], [String], [String]) {
    var music: [String] = [], movies: [String] = [], warnings: [String] = []
    if let musicRoot = try? find(source, "music") {
        let pattern = try NSRegularExpression(pattern: "^track0*([0-9]+)\\.(ogg|mp3|wav)$", options: [.caseInsensitive])
        for url in children(musicRoot).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !isDirectory(url), inside(url, source), let match = pattern.firstMatch(in: url.lastPathComponent, range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)),
                  let range = Range(match.range(at: 1), in: url.lastPathComponent), let number = Int(url.lastPathComponent[range]), number >= 2 && number <= 99 else { continue }
            try validateMedia(url, root: source)
            let name = String(format: "Track%02d.%@", number, url.pathExtension.lowercased())
            let folder = stage.appendingPathComponent("music"); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: folder.appendingPathComponent(name)); music.append(name)
        }
    }
    if music.isEmpty { warnings.append("No CD music tracks were found. Gameplay sound effects remain available; you can import a copy that includes the audio tracks later.") }
    for name in ["mix_intr", "toprank"] {
        let destination = stage.appendingPathComponent("video/\(name).mp4")
        if packed, let original = try? find(source, "video/\(name).mp4") {
            try validateMedia(original, root: source)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: original, to: destination); movies.append(name + ".mp4")
        } else if !packed, let original = try? find(source, "DATA/CUTSCENE/\(name).smk") {
            try validateMedia(original, root: source)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            message("Converting the original \(name) movie locally…")
            do {
                try process(helperFolder.appendingPathComponent("ffmpeg"), ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", original.path, "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "2000k", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "44100", "-b:a", "128k", "-movflags", "+faststart", destination.path])
                movies.append(name + ".mp4")
            } catch { try? fm.removeItem(at: destination); warnings.append("The \(name) movie could not be converted; it will be skipped. \(error)") }
        }
    }
    if movies.count < 2 { warnings.append("One or more original movies are unavailable and will be skipped. Import a complete copy, including DATA/CUTSCENE, to enable them.") }
    return (music, movies, warnings)
}

func performImport(source: URL, destination: URL, template: URL) throws -> ImportManifest {
    guard fm.fileExists(atPath: source.path) else { throw ImportFailure("The selected source does not exist.") }
    guard !inside(destination, source), !inside(source, destination) else { throw ImportFailure("Source and prepared-data folders must be separate and must not contain each other. Choose the original installation or the sibling Import folder.") }
    let parent = destination.deletingLastPathComponent(); try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let lock = parent.appendingPathComponent(".c2-import-lock")
    do { try fm.createDirectory(at: lock, withIntermediateDirectories: false) } catch { throw ImportFailure("Another import is running. If a previous import was interrupted, remove .c2-import-lock from the data folder and retry.") }
    defer { try? fm.removeItem(at: lock) }
    let stage = parent.appendingPathComponent(".c2-import-" + UUID().uuidString)
    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: stage) }
    var selected = source, mounted: URL?
    let extraction = stage.appendingPathComponent("extracted")
    defer { if let mount = mounted { try? process(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path]) } }
    if !isDirectory(source) {
        switch source.pathExtension.lowercased() {
        case "exe":
            try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
            message("Extracting the GOG installer without running Windows software…")
            try process(helperFolder.appendingPathComponent("innoextract"), ["--silent", "--extract", "--output-dir", extraction.path, source.path]); selected = extraction
        case "dmg", "iso", "cdr":
            let mount = stage.appendingPathComponent("mounted"); try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try process(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, source.path]); mounted = mount; selected = mount
        default: throw ImportFailure("Choose an installed game folder, a compatible Mac app, a GOG setup EXE, or a readable disk image.")
        }
    }
    let (game, isPacked) = try locate(selected)
    message("Preparing local game data…")
    let prepared = stage.appendingPathComponent("prepared"); try fm.createDirectory(at: prepared, withIntermediateDirectories: false)
    let files: [GameFile], total: Int64
    if isPacked {
        (files, total) = try legacyMetadata(game)
        // Verify the engine before accepting data or importing selected wrapper code.
        _ = try engineHash(game, files: files)
        for i in 0..<Int((total + partSize - 1) / partSize) {
            let name = String(format: "carma2web.data.%03d", i), original = game.appendingPathComponent(name)
            guard inside(original, game), try size(original) == min(partSize, total - Int64(i) * partSize) else { throw ImportFailure("Incomplete legacy package: \(name)") }
            try fm.copyItem(at: original, to: prepared.appendingPathComponent(name))
        }
    } else {
        let engine = try find(game, "CARMA2_HW.EXE")
        guard knownEngines.contains(try digest(engine)) else { throw ImportFailure("This Windows executable is not a supported build. Use the supported GOG 2.1.0.28 game installation.") }
        (files, total) = try pack(game, into: prepared)
    }
    let hash = try engineHash(prepared, files: files)
    var parts: [DataPart] = []
    for i in 0..<Int((total + partSize - 1) / partSize) {
        let name = String(format: "carma2web.data.%03d", i), part = prepared.appendingPathComponent(name)
        parts.append(DataPart(name: name, size: try size(part), sha256: try digest(part)))
    }
    let (music, movies, warnings) = try importMedia(game, into: prepared, packed: isPacked)
    let kind = source.pathExtension.lowercased() == "exe" ? "gog-installer" : isPacked ? "existing-mac-wrapper" : "installed-pc-game"
    let manifest = ImportManifest(schemaVersion: 1, format: "carma2web.parts.v1", totalSize: total, engineSha256: hash, sourceKind: kind, files: files, parts: parts, musicTracks: music, movies: movies, warnings: warnings)
    try generateLoader(prepared, manifest: manifest, template: template)
    _ = try validated(prepared, template: template)
    let previous = parent.appendingPathComponent("GameData.previous-" + UUID().uuidString)
    let existed = fm.fileExists(atPath: destination.path)
    if existed { try fm.moveItem(at: destination, to: previous) }
    do { try fm.moveItem(at: prepared, to: destination) }
    catch { if existed { try? fm.moveItem(at: previous, to: destination) }; throw error }
    // Previous prepared data is retained as a reversible backup, never deleted.
    return manifest
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let action = args.first, ["import", "validate"].contains(action) else { throw ImportFailure("Usage: c2-data import --source PATH --destination PATH [--loader-template PATH], or c2-data validate --source PATH") }
    func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
    guard let input = option("--source") else { throw ImportFailure("--source is required.") }
    let source = URL(fileURLWithPath: input).standardizedFileURL
    let manifest: ImportManifest
    let template = option("--loader-template").map { URL(fileURLWithPath: $0) } ?? defaultTemplate
    if action == "validate" { manifest = try validated(source, template: template) }
    else {
        guard let output = option("--destination") else { throw ImportFailure("--destination is required.") }
        manifest = try performImport(source: source, destination: URL(fileURLWithPath: output).standardizedFileURL, template: template)
    }
    let result: [String: Any] = ["success": true, "message": "Game data is ready.", "sourceKind": manifest.sourceKind, "engineSha256": manifest.engineSha256, "files": manifest.files.count, "warnings": manifest.warnings, "musicTracks": manifest.musicTracks.count, "movies": manifest.movies.count]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])); print("")
} catch {
    let result: [String: Any] = ["success": false, "error": String(describing: error)]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { FileHandle.standardOutput.write(data); print("") }
    exit(1)
}
