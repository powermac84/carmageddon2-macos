// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

/// User-owned files live outside the signed app bundle. Test sessions always use
/// isolated paths unless an explicit C2_DATA_ROOT was supplied by the test runner.
struct GameDataPaths {
    let prepared: URL
    var importFolder: URL { prepared.deletingLastPathComponent().appendingPathComponent("Import", isDirectory: true) }
    static func current(testPort: UInt16?) -> GameDataPaths {
        let env = ProcessInfo.processInfo.environment
        if let path = env["C2_DATA_ROOT"], !path.isEmpty {
            return GameDataPaths(prepared: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }
        if let port = testPort {
            return GameDataPaths(prepared: FileManager.default.temporaryDirectory.appendingPathComponent("CarmageddonII-Tests/\(port)/GameData", isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return GameDataPaths(prepared: support.appendingPathComponent("Carmageddon II/GameData", isDirectory: true))
    }
}

struct DataHelperResult {
    let success: Bool
    let message: String
    let warnings: [String]
    let sourceKind: String?
}

final class GameDataHelper {
    let executable: URL
    private let queue = DispatchQueue(label: "carmageddon2.data-import", qos: .userInitiated)
    init(bundle: Bundle = .main) { executable = bundle.bundleURL.appendingPathComponent("Contents/Helpers/c2-data") }
    func validate(_ source: URL, completion: @escaping (DataHelperResult) -> Void) {
        run(["validate", "--source", source.path], completion: completion)
    }
    func importData(from source: URL, to destination: URL, completion: @escaping (DataHelperResult) -> Void) {
        run(["import", "--source", source.path, "--destination", destination.path], completion: completion)
    }
    private func run(_ arguments: [String], completion: @escaping (DataHelperResult) -> Void) {
        queue.async {
            let result: DataHelperResult
            if !FileManager.default.isExecutableFile(atPath: self.executable.path) {
                result = DataHelperResult(success: false, message: "The data importer is missing from this app. Please reinstall the complete release.", warnings: [], sourceKind: nil)
            } else {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = self.executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    // Drain both pipes concurrently so a verbose extractor cannot
                    // block behind a full stderr pipe while stdout is being read.
                    let errorDrain = DispatchGroup()
                    let errorLock = NSLock()
                    var errorBytes = Data()
                    errorDrain.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let bytes = errors.fileHandleForReading.readDataToEndOfFile()
                        errorLock.lock(); errorBytes = bytes; errorLock.unlock()
                        errorDrain.leave()
                    }
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    errorDrain.wait()
                    if let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                        let ok = process.terminationStatus == 0 && (json["success"] as? Bool) == true
                        let message = (json[ok ? "message" : "error"] as? String) ?? (json["message"] as? String) ?? (ok ? "Game data is ready." : "The selected files could not be imported.")
                        result = DataHelperResult(success: ok, message: message, warnings: json["warnings"] as? [String] ?? [], sourceKind: json["sourceKind"] as? String)
                    } else {
                        errorLock.lock(); let detail = String(data: errorBytes.suffix(2400), encoding: .utf8) ?? ""; errorLock.unlock()
                        result = DataHelperResult(success: false, message: detail.isEmpty ? "The data importer returned an unreadable result. Please reinstall the app or choose another source." : detail, warnings: [], sourceKind: nil)
                    }
                } catch {
                    result = DataHelperResult(success: false, message: "The data importer could not start: \(error.localizedDescription)", warnings: [], sourceKind: nil)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class DataDropView: NSVisualEffectView {
    var importURL: ((URL) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1 else { return false }
        importURL?(urls[0]); return true
    }
}

/// Native first-run setup; runtime loading begins only after c2-data validates
/// the manifest, parts, required files and executable version successfully.
final class DataSetupController: NSObject {
    let paths: GameDataPaths
    let helper: GameDataHelper
    private let overlay = DataDropView(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "Checking your local game data…")
    private let spinner = NSProgressIndicator()
    private var buttons: [NSButton] = []
    private var busy = false
    private var validated = false
    private let ready: (URL) -> Void
    private let importFinished: (DataHelperResult) -> Void
    init(paths: GameDataPaths, ready: @escaping (URL) -> Void, importFinished: @escaping (DataHelperResult) -> Void) {
        self.paths = paths; self.helper = GameDataHelper(); self.ready = ready; self.importFinished = importFinished
        super.init()
        buildView()
        overlay.importURL = { [weak self] url in self?.importSource(url) }
    }
    func attach(to parent: NSView) {
        overlay.frame = parent.bounds
        overlay.autoresizingMask = [.width, .height]
        parent.addSubview(overlay)
    }
    func checkExisting() {
        guard !busy else { return }
        setBusy(true, message: "Checking your local game data…")
        helper.validate(paths.prepared) { [weak self] result in
            guard let self = self else { return }
            if result.success { self.finish(result) }
            else { self.setBusy(false, message: "Choose your game files to get started. The app does not include original Carmageddon II data.") }
        }
    }
    func importSource(_ source: URL) {
        guard !busy else { return }
        setBusy(true, message: "Importing your game data… This may take a few minutes. Your source files will not be changed.")
        helper.importData(from: source, to: paths.prepared) { [weak self] result in
            guard let self = self else { return }
            guard result.success else { self.setBusy(false, message: result.message); return }
            // Do not start the game from a success string alone: validate the
            // installed result independently, including all referenced parts.
            self.helper.validate(self.paths.prepared) { [weak self] validation in
                guard let self = self else { return }
                if validation.success { self.finish(DataHelperResult(success: true, message: result.message, warnings: result.warnings, sourceKind: result.sourceKind), notify: true) }
                else { self.setBusy(false, message: validation.message) }
            }
        }
    }
    private func finish(_ result: DataHelperResult, notify: Bool = false) {
        guard !validated else { return }
        validated = true
        setBusy(false, message: "Game data is ready.")
        overlay.removeFromSuperview()
        if notify { importFinished(result) }
        ready(paths.prepared)
    }
    private func setBusy(_ value: Bool, message: String) {
        busy = value; status.stringValue = message
        for button in buttons { button.isEnabled = !value }
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func buildView() {
        let title = NSTextField(labelWithString: "Carmageddon II on Apple silicon")
        title.font = .systemFont(ofSize: 27, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Bring your own game")
        subtitle.font = .systemFont(ofSize: 18, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Import a Carmageddon II installation folder, supported GOG PC installer, or existing local Mac wrapper. You can also drop a source folder or installer onto this window.")
        description.font = .systemFont(ofSize: 13)
        let compatibility = NSTextField(wrappingLabelWithString: "Supported Mac sources include PC installations in Wine, CrossOver or Highball, and the earlier local Mac wrapper. Original Classic Mac-only PowerPC media cannot start this runtime.")
        compatibility.font = .systemFont(ofSize: 12)
        compatibility.textColor = .secondaryLabelColor
        let folder = button("Choose Installation Folder…", action: #selector(chooseFolder))
        let installer = button("Choose GOG Installer…", action: #selector(chooseInstaller))
        let importRow = NSStackView(views: [folder, installer]); importRow.orientation = .horizontal; importRow.spacing = 12
        let manual = NSTextField(wrappingLabelWithString: "Prefer to copy files yourself? Put your original installation files in the Import folder, then choose Check Import Folder. Prepared game-data packages can be placed in the GameData folder.")
        manual.font = .systemFont(ofSize: 12)
        let open = button("Open Import Folder", action: #selector(openImportFolder))
        let rescan = button("Check Import Folder", action: #selector(checkImportFolder))
        let manualRow = NSStackView(views: [open, rescan]); manualRow.orientation = .horizontal; manualRow.spacing = 12
        let path = NSTextField(wrappingLabelWithString: paths.importFolder.path)
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.isSelectable = true
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 7
        status.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let progress = NSStackView(views: [spinner, status]); progress.orientation = .horizontal; progress.spacing = 10; progress.alignment = .centerY
        let stack = NSStackView(views: [title, subtitle, description, compatibility, importRow, manual, manualRow, path, progress])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: overlay.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        overlay.addSubview(scroll)
        document.addSubview(stack)
        let preferredHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 40), preferredHeight,
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor), stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor, multiplier: 0.82), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 660)
        ])
        for label in [description, compatibility, manual, path, status] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded; buttons.append(value); return value
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose your Carmageddon II installation"
        panel.prompt = "Import"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { importSource(url) }
    }
    @objc private func chooseInstaller() {
        let panel = NSOpenPanel(); panel.title = "Choose your GOG Carmageddon II PC installer"
        panel.prompt = "Import"; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .executable]
        if panel.runModal() == .OK, let url = panel.url { importSource(url) }
    }
    @objc func openImportFolder() {
        do { try FileManager.default.createDirectory(at: paths.importFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(paths.importFolder) }
        catch { status.stringValue = "The Import folder could not be opened: \(error.localizedDescription)" }
    }
    @objc private func checkImportFolder() {
        guard !busy else { return }
        setBusy(true, message: "Checking the GameData and Import folders…")
        helper.validate(paths.prepared) { [weak self] validation in
            guard let self = self else { return }
            if validation.success { self.finish(validation); return }
            self.setBusy(false, message: "Checking the files you copied…")
            self.importSource(self.paths.importFolder)
        }
    }
}
