// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit
import AVKit
import AVFoundation
import Network

// Test launches may use another loopback origin without touching the player's saves.
private let gamePort: UInt16 = ProcessInfo.processInfo.environment["C2_TEST_PORT"].flatMap(UInt16.init) ?? 32197
private let parallelTest = ProcessInfo.processInfo.environment["C2_TEST_PORT"] != nil
private let foregroundWindow = !parallelTest || ProcessInfo.processInfo.environment["C2_TEST_FOREGROUND"] == "1"
private let appPreferences: UserDefaults = parallelTest ? (UserDefaults(suiteName: "de.patrickbanfield.carmageddon2.test.\(gamePort)") ?? .standard) : .standard
private let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["C2_DIAGNOSTICS"] ?? (NSTemporaryDirectory() + "CarmageddonII-WebHost.log"))
private let logLock = NSLock()
func record(_ message: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: Data()) }
    if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
}

final class LocalServer {
    let root: URL
    let dataRoot: URL
    let connectSources: () -> String
    let listener: NWListener
    let queue = DispatchQueue(label: "de.banfield.carmageddon2.http", qos: .userInitiated, attributes: .concurrent)
    var ready: (() -> Void)?
    var failure: ((Error) -> Void)?
    init(root: URL, dataRoot: URL, connectSources: @escaping () -> String) throws {
        self.root = root.standardizedFileURL
        self.dataRoot = dataRoot.standardizedFileURL
        self.connectSources = connectSources
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: gamePort)!)
        p.allowLocalEndpointReuse = true
        listener = try NWListener(using: p)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: record("HTTP ready at 127.0.0.1:\(gamePort)"); DispatchQueue.main.async { self?.ready?() }
            case .failed(let error): record("HTTP failed: \(error)"); DispatchQueue.main.async { self?.failure?(error) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var request = accumulated
            if let data = data { request.append(data) }
            if request.count > 16384 { self.reply(connection, status: "431 Request Header Fields Too Large", body: Data()); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                self.handle(connection, request: text)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: request) }
        }
    }
    private func handle(_ connection: NWConnection, request: String) {
        let first = request.components(separatedBy: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
            reply(connection, status: "405 Method Not Allowed", body: Data()); return
        }
        let raw = String(parts[1]).components(separatedBy: "?").first ?? "/"
        guard let path = raw.removingPercentEncoding, !path.contains("\0"), path.hasPrefix("/") else {
            reply(connection, status: "400 Bad Request", body: Data()); return
        }
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        let isData = relative == "carma2data.js" || relative == "carma2data.manifest.json" || relative.range(of: #"^carma2web\.data\.[0-9]{3}$"#, options: .regularExpression) != nil || relative.hasPrefix("music/") || relative.hasPrefix("video/")
        let base = isData ? dataRoot : root
        let file = base.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else {
            reply(connection, status: "403 Forbidden", body: Data()); return
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            reply(connection, status: "404 Not Found", body: Data()); return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "text/javascript; charset=utf-8"
        case "wasm": mime = "application/wasm"
        case "ogg": mime = "audio/ogg"
        case "mp3": mime = "audio/mpeg"
        case "wav": mime = "audio/wav"
        case "png": mime = "image/png"
        case "json": mime = "application/json"
        default: mime = "application/octet-stream"
        }
        let rangeHeader = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        if let rangeHeader = rangeHeader, let equals = rangeHeader.firstIndex(of: "=") {
            let spec = String(rangeHeader[rangeHeader.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 && !spec.contains(",") {
                var start = Int(bounds[0]) ?? 0
                var end = Int(bounds[1]) ?? (data.count - 1)
                if bounds[0].isEmpty, let suffix = Int(bounds[1]) { start = max(0, data.count - suffix); end = data.count - 1 }
                end = min(end, data.count - 1)
                if start >= 0 && start <= end && start < data.count {
                    reply(connection, status: "206 Partial Content", body: data.subdata(in: start..<(end+1)), mime: mime, head: parts[0] == "HEAD", extra: "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n")
                    return
                }
            }
            reply(connection, status: "416 Range Not Satisfiable", body: Data(), extra: "Content-Range: bytes */\(data.count)\r\n")
            return
        }
        reply(connection, status: "200 OK", body: data, mime: mime, head: parts[0] == "HEAD")
    }
    private func reply(_ connection: NWConnection, status: String, body: Data, mime: String = "text/plain", head: Bool = false, extra: String = "") {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Cross-Origin-Resource-Policy: same-origin\r\nX-Frame-Options: DENY\r\nConnection: close\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; connect-src \(connectSources()); img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:\r\n\r\n"
        var response = Data(headers.utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class NativeMovieView: AVPlayerView {
    var skip: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [UInt16(53), 49, 36, 76].contains(event.keyCode) { skip?() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) { skip?() }
}

final class GameView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return false
    }
}

enum DisplayMode: String {
    case window, fullscreen
}

final class PerformanceHUD: NSView {
    let label = NSTextField(labelWithString: "FPS …")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 5
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 6, dy: 2) }
}

final class LetterboxView: NSView {
    weak var gameView: NSView?
    weak var hud: NSView?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // The optional status strip stays outside the original game's HUD.
        let strip: CGFloat = hud?.isHidden == false ? 24 : 0
        let available = NSRect(x: bounds.minX, y: bounds.minY+strip, width: bounds.width, height: max(0,bounds.height-strip))
        // Multiples of four physical pixels keep the viewport exactly 4:3.
        let backing = window?.backingScaleFactor ?? 1
        let unit = floor(min(available.width / 4, available.height / 3) * backing) / backing
        let size = NSSize(width: max(0, unit * 4), height: max(0, unit * 3))
        let viewport = NSRect(x: available.minX+(available.width-size.width)/2, y: available.minY+(available.height-size.height)/2, width: size.width, height: size.height)
        gameView?.frame = viewport
        hud?.frame = NSRect(x: max(bounds.minX+8,bounds.maxX-360), y: bounds.minY+1, width: min(352,bounds.width-16), height: 22)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var view: GameView!
    var container: LetterboxView!
    var performanceHUD: PerformanceHUD!
    var windowModeItem: NSMenuItem!
    var fullScreenModeItem: NSMenuItem!
    var fpsItem: NSMenuItem!
    var qualityItems: [NSMenuItem] = []
    var pedestrianItem: NSMenuItem!
    var trafficItem: NSMenuItem!
    var smoothingInitialized = Set<String>()
    var lastMotionLogKeys: [String:String] = [:]
    var desiredDisplayMode: DisplayMode = .window
    var fullscreenTransition = false
    var fpsVisible = true
    var latestQuality: [String:Any]?
    let qualityPresets: [(String, Int, Int, Int)] = [
        ("Fluid (1×, MSAA off)", 1, 0, 4),
        ("Standard (2×, MSAA 4×)", 2, 4, 4),
        ("High (3×, MSAA 4×)", 3, 4, 4),
        ("Very High (4×, MSAA 4×)", 4, 4, 4)
    ]
    var server: LocalServer?
    var setup: DataSetupController?
    var gameDataRoot: URL?
    var gameReady = false
    lazy var dataPaths = GameDataPaths.current(testPort: parallelTest ? gamePort : nil)
    lazy var multiplayer = MultiplayerController(preferences: appPreferences, changeHandler: { [weak self] in self?.networkSettingsChanged() })
    var timer: Timer?
    var lastCommand: String = ""
    var flushing = false
    var repliedToTermination = false
    var movieView: NativeMovieView?
    var movieObserver: NSObjectProtocol?
    var movieStatus: NSKeyValueObservation?
    var movieTimeout: DispatchWorkItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        record("Native arm64 WebKit host starting; PID \(ProcessInfo.processInfo.processIdentifier), port \(gamePort), bundle \(Bundle.main.bundlePath)")
        appPreferences.register(defaults: ["ShowFPS": true, "DisplayMode": DisplayMode.window.rawValue, "PedestrianSmoothing": true, "TrafficSmoothing": true])
        fpsVisible = appPreferences.bool(forKey: "ShowFPS")
        desiredDisplayMode = DisplayMode(rawValue: appPreferences.string(forKey: "DisplayMode") ?? "window") ?? .window
        if parallelTest {
            if let address = ProcessInfo.processInfo.environment["C2_TEST_RELAY"], let validated = MultiplayerController.validatedAddress(address) {
                appPreferences.set(validated, forKey: "MultiplayerRelay")
                appPreferences.set(ProcessInfo.processInfo.environment["C2_TEST_ROOM"] ?? "native-smoke", forKey: "MultiplayerRoom")
            }
            desiredDisplayMode = .window
            fpsVisible = true
            appPreferences.set(DisplayMode.window.rawValue, forKey: "DisplayMode")
            appPreferences.set(true, forKey: "ShowFPS")
        }
        createMenus()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if parallelTest { config.preferences.inactiveSchedulingPolicy = .none }
        let controller = WKUserContentController()
        controller.add(self, name: "nativeLog")
        controller.add(self, name: "nativeVideo")
        controller.add(self, name: "nativeFPS")
        controller.add(self, name: "nativeQuality")
        controller.add(self, name: "nativeSmoothing")
        let bridge = """
        (() => {
          const send = s => { try { window.webkit.messageHandlers.nativeLog.postMessage(String(s).slice(0,6000)); } catch(_) {} };
          window.addEventListener('error', e => send('ERROR ' + e.message + ' ' + e.filename + ':' + e.lineno));
          window.addEventListener('unhandledrejection', e => send('REJECTION ' + e.reason));
          ['log','warn','error'].forEach(k => { const orig = console[k]; console[k] = (...a) => { send(k + ' ' + a.join(' ')); orig.apply(console,a); }; });
          const nativeKeyMap = {"Escape":[1,27],"Digit1":[2,49],"Digit2":[3,50],"Digit3":[4,51],"Digit4":[5,52],"Digit5":[6,53],"Digit6":[7,54],"Digit7":[8,55],"Digit8":[9,56],"Digit9":[10,57],"Digit0":[11,48],"Minus":[12,189],"Equal":[13,187],"Backspace":[14,8],"Tab":[15,9],"KeyQ":[16,81],"KeyW":[17,87],"KeyE":[18,69],"KeyR":[19,82],"KeyT":[20,84],"KeyY":[21,89],"KeyU":[22,85],"KeyI":[23,73],"KeyO":[24,79],"KeyP":[25,80],"BracketLeft":[26,219],"BracketRight":[27,221],"Enter":[28,13],"ControlLeft":[29,17],"KeyA":[30,65],"KeyS":[31,83],"KeyD":[32,68],"KeyF":[33,70],"KeyG":[34,71],"KeyH":[35,72],"KeyJ":[36,74],"KeyK":[37,75],"KeyL":[38,76],"Semicolon":[39,186],"Quote":[40,222],"Backquote":[41,192],"ShiftLeft":[42,16],"Backslash":[43,220],"KeyZ":[44,90],"KeyX":[45,88],"KeyC":[46,67],"KeyV":[47,86],"KeyB":[48,66],"KeyN":[49,78],"KeyM":[50,77],"Comma":[51,188],"Period":[52,190],"Slash":[53,191],"ShiftRight":[54,16],"NumpadMultiply":[55,106],"AltLeft":[56,18],"Space":[57,32],"CapsLock":[58,20],"F1":[59,112],"F2":[60,113],"F3":[61,114],"F4":[62,115],"F5":[63,116],"F6":[64,117],"F7":[65,118],"F8":[66,119],"F9":[67,120],"F10":[68,121],"Numpad7":[71,103],"Numpad8":[72,104],"Numpad9":[73,105],"NumpadSubtract":[74,109],"Numpad4":[75,100],"Numpad5":[76,101],"Numpad6":[77,102],"NumpadAdd":[78,107],"Numpad1":[79,97],"Numpad2":[80,98],"Numpad3":[81,99],"Numpad0":[82,96],"NumpadDecimal":[83,110],"F11":[87,122],"F12":[88,123],"NumpadEnter":[156,13],"ControlRight":[157,17],"NumpadDivide":[181,111],"AltRight":[184,18],"Home":[199,36],"ArrowUp":[200,38],"PageUp":[201,33],"ArrowLeft":[203,37],"ArrowRight":[205,39],"End":[207,35],"ArrowDown":[208,40],"PageDown":[209,34],"Insert":[210,45],"Delete":[211,46]};
          const nativeHeld = new Set();
          window.addEventListener('keydown', e => { if(nativeKeyMap[e.code]) nativeHeld.add(e.code); }, true);
          window.addEventListener('keyup', e => { nativeHeld.delete(e.code); }, true);
          window.__releaseGameKeys = () => {
            const M = window.Module;
            if(M && M._emu_js_release_inputs) M._emu_js_release_inputs();
            else if(M && M._emu_js_key) nativeHeld.forEach(code => { const k=nativeKeyMap[code]; M._emu_js_key(k[0],k[1],0); });
            nativeHeld.clear();
            if(M && !M._emu_js_release_inputs && M._emu_js_pointer) M._emu_js_pointer(window.__nativeMouseX||0.5,window.__nativeMouseY||0.5,0);
          };
          window.addEventListener('mousemove',e=>{const c=document.getElementById('canvas');if(e.target===c){const r=c.getBoundingClientRect();window.__nativeMouseX=(e.clientX-r.left)/r.width;window.__nativeMouseY=(e.clientY-r.top)/r.height;}},true);
          window.addEventListener('mouseup', e=>{const M=window.Module;if(e.target!==document.getElementById('canvas')&&M&&M._emu_js_pointer)M._emu_js_pointer(window.__nativeMouseX||0.5,window.__nativeMouseY||0.5,0);},true);
          window.addEventListener('blur', window.__releaseGameKeys);
          document.addEventListener('visibilitychange', ()=>{if(document.hidden)window.__releaseGameKeys();});
          window.__nativeFullscreen = () => send('FULLSCREEN');
          document.addEventListener('dblclick', e => { e.preventDefault(); e.stopImmediatePropagation(); window.__nativeFullscreen(); }, true);
          window.addEventListener('keydown', e => { if (e.altKey && e.code === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); window.__nativeFullscreen(); } }, true);
          window.__nativeFPSVisible = \(fpsVisible ? "true" : "false");
          const frameSamples = [], presentSamples = [];
          let lastFrame = 0;
          window.__resetNativeFPS = () => { frameSamples.length=0;presentSamples.length=0;lastFrame=0; };
          window.addEventListener('blur',window.__resetNativeFPS);
          document.addEventListener('visibilitychange',window.__resetNativeFPS);
          function measureFrame(t) {
            if(document.hidden || (window.Module && Module.__videoPlaying)) {
              window.__resetNativeFPS();
            } else {
              if(lastFrame && t>lastFrame) frameSamples.push([t,t-lastFrame]);
              lastFrame=t;
              while(frameSamples.length && frameSamples[0][0]<t-1000) frameSamples.shift();
            }
            requestAnimationFrame(measureFrame);
          }
          requestAnimationFrame(measureFrame);
          setInterval(()=>{
            if(!window.__nativeFPSVisible || !frameSamples.length || document.hidden || (window.Module && Module.__videoPlaying)) return;
            const a=frameSamples.map(x=>x[1]).sort((a,b)=>a-b);
            const mean=a.reduce((x,y)=>x+y,0)/a.length;
            let fps=window.__stats?window.__stats.fps:null;
            const frames=window.Module && Module.__glide ? Module.__glide.frames : null;
            if(typeof frames==='number') {
              const now=performance.now();
              if(presentSamples.length && frames<presentSamples[presentSamples.length-1][1])presentSamples.length=0;
              presentSamples.push([now,frames]);
              while(presentSamples.length>1 && presentSamples[1][0]<now-1000)presentSamples.shift();
              const first=presentSamples[0],dt=now-first[0];
              if(dt>100)fps=(frames-first[1])*1000/dt;
            }
            const info={fps,frameMs:mean,p95Ms:a[Math.floor((a.length-1)*.95)],maxMs:a[a.length-1]};
            try{window.webkit.messageHandlers.nativeFPS.postMessage(info);}catch(_){}
          },250);
          let lastSmoothing='';
          function motionSnapshot(v) {
            const state={available:!!v.available,enabled:!!v.enabled,pendingRestore:!!v.pendingRestore};
            if(typeof v.requested==='boolean')state.requested=v.requested;
            if(typeof v.active==='boolean')state.active=v.active;
            if(typeof v.safetyDisabled==='boolean')state.safetyDisabled=v.safetyDisabled;
            if(typeof v.safetyReason==='string')state.safetyReason=v.safetyReason.slice(0,120);
            const errors=v.stats && v.stats.restoreErrors;
            if(typeof errors==='number' && Number.isFinite(errors) && errors>=0)state.restoreErrors=errors;
            return state;
          }
          setInterval(()=>{
            const M=window.Module;
            if(!M)return;
            const state={};
            if(typeof M.getPedestrianSmoothing==='function')state.pedestrian=motionSnapshot(M.getPedestrianSmoothing());
            if(typeof M.getTrafficSmoothing==='function')state.traffic=motionSnapshot(M.getTrafficSmoothing());
            // pendingRestore and per-frame statistics never drive logging.
            const key=JSON.stringify(state,(name,value)=>name==='pendingRestore'?undefined:value);
            if(key!==lastSmoothing){lastSmoothing=key;try{window.webkit.messageHandlers.nativeSmoothing.postMessage(state);}catch(_){}}
          },1000);
          let lastQuality='';
          setInterval(()=>{
            const M=window.Module;
            if(!M || typeof M.getGraphicsQuality!=='function') return;
            const q=M.getGraphicsQuality(),text=JSON.stringify(q);
            if(text!==lastQuality){lastQuality=text;try{window.webkit.messageHandlers.nativeQuality.postMessage(q);}catch(_){}}
          },1000);
          setInterval(() => { if (window.__stats) send('STATS ' + JSON.stringify(window.__stats)); }, 5000);
        })();
        """
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: "if(typeof Module!=='undefined'){const oldExit=Module.onEmuExit;Module.onEmuExit=()=>{if(oldExit)oldExit();window.webkit.messageHandlers.nativeLog.postMessage('GAME_EXIT');};}", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller
        view = GameView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.isInspectable = true
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 960,height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Carmageddon II"
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.backgroundColor = .black
        container = LetterboxView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        performanceHUD = PerformanceHUD(frame: NSRect(x: 0,y: 0,width: 202,height: 54))
        container.gameView = view
        container.hud = performanceHUD
        container.addSubview(view)
        container.addSubview(performanceHUD)
        window.contentView = container
        updateHUDVisibility()
        window.delegate = self
        window.collectionBehavior = .fullScreenPrimary
        window.setFrameAutosaveName(parallelTest ? "Carmageddon II Test Window \(gamePort)" : "Carmageddon II 4x3 Window")
        window.center()
        if foregroundWindow { window.makeKeyAndOrderFront(nil) }
        else { window.orderBack(nil) }
        window.makeFirstResponder(view)
        if foregroundWindow { NSApp.activate(ignoringOtherApps: true) }
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        updateDisplayChecks()
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("site"), FileManager.default.fileExists(atPath: root.appendingPathComponent("carma2hy.wasm").path) else {
            fail("The runtime is missing from this app. Please reinstall the complete release."); return
        }
        performanceHUD.isHidden = true
        window.title = "Carmageddon II — Setup"
        let setup = DataSetupController(paths: dataPaths, ready: { [weak self] url in self?.startGame(dataRoot: url) }, importFinished: { [weak self] result in self?.showImportResult(result) })
        self.setup = setup
        setup.attach(to: container)
        if parallelTest, let source = ProcessInfo.processInfo.environment["C2_TEST_IMPORT_SOURCE"], !source.isEmpty {
            setup.importSource(URL(fileURLWithPath: source))
        } else { setup.checkExisting() }
        if let commandPath = ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self = self, let command = try? String(contentsOfFile: commandPath, encoding: .utf8), command != self.lastCommand, !command.isEmpty else { return }
                self.lastCommand = command
                self.view.evaluateJavaScript(command) { result, error in record("EVAL \(String(describing: result)) ERROR \(String(describing: error))") }
            }
        }
    }
    func startGame(dataRoot: URL) {
        guard !gameReady, let runtimeRoot = Bundle.main.resourceURL?.appendingPathComponent("site") else { return }
        gameDataRoot = dataRoot
        setup = nil
        window.title = "Carmageddon II"
        do {
            server = try LocalServer(root: runtimeRoot, dataRoot: dataRoot, connectSources: { [weak network = multiplayer] in network?.contentSecurityPolicyConnectSources ?? "'self'" })
            server?.ready = { [weak self] in
                self?.gameReady = true
                if parallelTest && foregroundWindow { self?.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                self?.loadGamePage()
            }
            server?.failure = { [weak self] error in self?.fail("The local game server could not start on port \(gamePort). Close another Carmageddon II app using this port, then try again.\n\n\(error.localizedDescription)") }
            server?.start()
        } catch { fail(error.localizedDescription) }
        updateHUDVisibility()
        if desiredDisplayMode == .fullscreen { DispatchQueue.main.async { [weak self] in self?.reconcileDisplayMode() } }
    }
    func loadGamePage() {
        let query = ProcessInfo.processInfo.environment["C2_QUERY"] ?? "touch=0&webaudiomusic=1&nativevideo=1"
        guard var url = URLComponents(string: "http://127.0.0.1:\(gamePort)/?\(query)") else { return }
        var items = url.queryItems ?? []
        let networkNames = Set(["wide", "relay", "room", "name"])
        items.removeAll { networkNames.contains($0.name) }
        items.append(URLQueryItem(name: "wide", value: "0"))
        items.append(contentsOf: multiplayer.queryItems())
        url.queryItems = items
        guard let address = url.url else { return }
        view.load(URLRequest(url: address))
    }
    func networkSettingsChanged() {
        guard gameReady else { return }
        finishVideo(reason: "network settings changed")
        view.callAsyncJavaScript("if(typeof Module!=='undefined'&&typeof Module.flushGameStorage==='function'){await Module.flushGameStorage();}", arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success: self?.loadGamePage()
            case .failure(let error):
                let alert = NSAlert(); alert.messageText = "Could Not Save Before Restart"
                alert.informativeText = "Your new network settings are saved, but the game was not restarted because its storage could not be synchronized. Quit normally and reopen the app to use the new settings.\n\n" + error.localizedDescription
                alert.runModal()
            }
        }
    }
    func showImportResult(_ result: DataHelperResult) {
        record("Data import completed: \(result.sourceKind ?? "unknown")")
        guard !result.warnings.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = "Game Data Imported"
        alert.informativeText = result.warnings.joined(separator: "\n\n")
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }
    @objc func revealGameData() {
        let target = gameDataRoot ?? dataPaths.prepared
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); NSWorkspace.shared.open(target) }
        catch { let alert = NSAlert(); alert.messageText = "Could Not Open Game Data"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    @objc func revealImportFolder() {
        do { try FileManager.default.createDirectory(at: dataPaths.importFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(dataPaths.importFolder) }
        catch { let alert = NSAlert(); alert.messageText = "Could Not Open Import Folder"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    func diagnosticSnapshot() {
        guard parallelTest, let path = ProcessInfo.processInfo.environment["C2_TEST_SNAPSHOT"], !path.isEmpty else { return }
        view.takeSnapshot(with: nil) { image, error in
            guard let image = image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { record("SNAPSHOT_ERROR \(String(describing: error))"); return }
            do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); record("SNAPSHOT_SAVED \(path)") }
            catch { record("SNAPSHOT_ERROR \(error)") }
        }
    }
    func createMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Carmageddon II", action: nil, keyEquivalent: ""); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Carmageddon II", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Carmageddon II", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); menu.addItem(viewItem)
        let vm = NSMenu(title: "View"); viewItem.submenu = vm
        vm.autoenablesItems = false
        windowModeItem = vm.addItem(withTitle: "Window (4:3)", action: #selector(chooseWindowMode), keyEquivalent: "")
        windowModeItem.target = self
        fullScreenModeItem = vm.addItem(withTitle: "Fullscreen (4:3)", action: #selector(chooseFullScreenMode), keyEquivalent: "")
        fullScreenModeItem.target = self
        let toggle = vm.addItem(withTitle: "Toggle Fullscreen", action: #selector(fullscreen), keyEquivalent: "f")
        toggle.keyEquivalentModifierMask = [.command,.control]
        toggle.target = self
        toggle.isHidden = true
        toggle.allowsKeyEquivalentWhenHidden = true
        vm.addItem(.separator())
        fpsItem = vm.addItem(withTitle: "Show FPS", action: #selector(stats), keyEquivalent: "")
        fpsItem.target = self
        fpsItem.state = fpsVisible ? .on : .off
        let qualityItem = NSMenuItem(title: "Graphics Quality", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu(title: "Graphics Quality")
        qualityMenu.autoenablesItems = false
        qualityItem.submenu = qualityMenu
        vm.addItem(qualityItem)
        for (i,preset) in qualityPresets.enumerated() {
            let item = qualityMenu.addItem(withTitle: preset.0, action: #selector(chooseQuality(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.isEnabled = false
            qualityItems.append(item)
        }
        vm.addItem(.separator())
        trafficItem = vm.addItem(withTitle: "Smooth Road Traffic", action: #selector(toggleTraffic), keyEquivalent: "")
        trafficItem.target = self; trafficItem.isEnabled = false
        trafficItem.toolTip = "Smoother movement for scripted road traffic."
        pedestrianItem = vm.addItem(withTitle: "Smooth Pedestrians", action: #selector(togglePedestrians), keyEquivalent: "")
        pedestrianItem.target = self; pedestrianItem.isEnabled = false
        pedestrianItem.toolTip = "Smooth character motion; presentation may be delayed slightly."
        vm.addItem(.separator())
        let recover = vm.addItem(withTitle: "Recover Vehicle", action: #selector(recoverCar), keyEquivalent: "r")
        recover.target = self
        let dataItem = NSMenuItem(title: "Game Data", action: nil, keyEquivalent: ""); menu.addItem(dataItem)
        let dataMenu = NSMenu(title: "Game Data"); dataItem.submenu = dataMenu
        dataMenu.addItem(withTitle: "Open GameData Folder", action: #selector(revealGameData), keyEquivalent: "")
        dataMenu.addItem(withTitle: "Open Import Folder", action: #selector(revealImportFolder), keyEquivalent: "")
        let networkItem = NSMenuItem(title: "Multiplayer", action: nil, keyEquivalent: ""); menu.addItem(networkItem)
        networkItem.submenu = multiplayer.makeMenu()
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); menu.addItem(helpItem)
        let help = NSMenu(title: "Help"); helpItem.submenu = help
        help.addItem(withTitle: "Controls", action: #selector(controls), keyEquivalent: "?")
        NSApp.mainMenu = menu
        recordMenuTitles()
    }
    func recordMenuTitles() {
        let titles = NSApp.mainMenu?.items.map { $0.title } ?? []
        if let json = try? JSONSerialization.data(withJSONObject: titles), let text = String(data: json, encoding: .utf8) { record("MENUS " + text) }
    }
    func updateDisplayChecks() {
        windowModeItem.state = desiredDisplayMode == .window ? .on : .off
        fullScreenModeItem.state = desiredDisplayMode == .fullscreen ? .on : .off
        windowModeItem.isEnabled = !fullscreenTransition
        fullScreenModeItem.isEnabled = !fullscreenTransition
    }
    func setDisplayMode(_ mode: DisplayMode) {
        desiredDisplayMode = mode
        appPreferences.set(mode.rawValue, forKey: "DisplayMode")
        updateDisplayChecks()
        reconcileDisplayMode()
    }
    func reconcileDisplayMode() {
        guard window != nil, !fullscreenTransition else { return }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        let wantFullscreen = desiredDisplayMode == .fullscreen
        guard isFullscreen != wantFullscreen else { updateDisplayChecks(); return }
        fullscreenTransition = true
        updateDisplayChecks()
        window.toggleFullScreen(nil)
    }
    @objc func chooseWindowMode() { setDisplayMode(.window) }
    @objc func chooseFullScreenMode() { setDisplayMode(.fullscreen) }
    @objc func fullscreen() { setDisplayMode(desiredDisplayMode == .fullscreen ? .window : .fullscreen) }
    func windowWillEnterFullScreen(_ notification: Notification) {
        if !fullscreenTransition {
            desiredDisplayMode = .fullscreen
            appPreferences.set(desiredDisplayMode.rawValue, forKey: "DisplayMode")
        }
        fullscreenTransition = true
        updateDisplayChecks()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { finishDisplayTransition() }
    func windowWillExitFullScreen(_ notification: Notification) {
        if !fullscreenTransition {
            desiredDisplayMode = .window
            appPreferences.set(desiredDisplayMode.rawValue, forKey: "DisplayMode")
        }
        fullscreenTransition = true
        updateDisplayChecks()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        finishDisplayTransition()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { resetDisplayModeAfterFailure() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { resetDisplayModeAfterFailure() }
    func resetDisplayModeAfterFailure() {
        desiredDisplayMode = window.styleMask.contains(.fullScreen) ? .fullscreen : .window
        appPreferences.set(desiredDisplayMode.rawValue, forKey: "DisplayMode")
        fullscreenTransition = false
        updateDisplayChecks()
    }
    func finishDisplayTransition() {
        fullscreenTransition = false
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        updateDisplayChecks()
        recordGeometry()
        reconcileDisplayMode()
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard frameSize.width.isFinite, frameSize.height.isFinite else { return sender.frame.size }
        guard !fullscreenTransition, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentView?.bounds.size ?? NSSize(width: 960, height: 720)
        let widthDriven = abs(proposed.width-current.width) >= abs(proposed.height-current.height)*4/3
        let units = max(160, widthDriven ? proposed.width/4 : proposed.height/3)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: units*4,height: units*3))).size
    }
    func windowDidResize(_ notification: Notification) { container?.needsLayout = true }
    func updateHUDVisibility() {
        performanceHUD?.isHidden = !fpsVisible || movieView != nil
        fpsItem?.state = fpsVisible ? .on : .off
        container?.needsLayout = true
        container?.layoutSubtreeIfNeeded()
    }
    func receiveFPS(_ info: [String:Any]) {
        guard fpsVisible, let mean = info["frameMs"] as? Double, mean.isFinite else { return }
        let fps = (info["fps"] as? Double).flatMap { $0.isFinite ? $0 : nil }
        let maximum = (info["maxMs"] as? Double) ?? mean
        let fpsText = fps.map { String(format: "%.0f FPS", $0) } ?? "FPS …"
        let meanText = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), mean)
        let maxText = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), maximum)
        performanceHUD.label.stringValue = "\(fpsText) · \(meanText) ms · Max. \(maxText) ms"
    }
    @objc func chooseQuality(_ sender: NSMenuItem) {
        guard qualityPresets.indices.contains(sender.tag) else { return }
        let p = qualityPresets[sender.tag]
        view.evaluateJavaScript("Module.setGraphicsQuality({scale:\(p.1),msaa:\(p.2),anisotropy:\(p.3)})") { [weak self] value,error in
            if let info = value as? [String:Any] { self?.receiveQuality(info) }
            if let error = error { record("Graphics quality error: \(error.localizedDescription)") }
        }
    }
    func receiveQuality(_ info: [String:Any]) {
        latestQuality = info
        let scale = (info["scale"] as? NSNumber)?.intValue
        let msaa = (info["msaa"] as? NSNumber)?.intValue
        let aniso = (info["anisotropy"] as? NSNumber)?.intValue
        for (i,item) in qualityItems.enumerated() {
            let p = qualityPresets[i]
            item.isEnabled = true
            item.state = scale == p.1 && msaa == p.2 && aniso == p.3 ? .on : .off
        }
    }
    @objc func togglePedestrians() {
        guard pedestrianItem.isEnabled else { return }
        let enabled = pedestrianItem.state != .on
        appPreferences.set(enabled, forKey: "PedestrianSmoothing")
        applyPedestrianSmoothing(enabled)
    }
    func applyPedestrianSmoothing(_ enabled: Bool) {
        view.evaluateJavaScript("Module.setPedestrianSmoothing(\(enabled ? "true" : "false"))") { [weak self] value,error in
            if let info = value as? [String:Any] { self?.receiveSmoothing(["pedestrian":info]) }
            if let error = error { record("Pedestrian smoothing error: \(error.localizedDescription)") }
        }
    }
    @objc func toggleTraffic() {
        guard trafficItem.isEnabled else { return }
        let enabled = trafficItem.state != .on
        appPreferences.set(enabled, forKey: "TrafficSmoothing")
        applyTrafficSmoothing(enabled)
    }
    func applyTrafficSmoothing(_ enabled: Bool) {
        view.evaluateJavaScript("Module.setTrafficSmoothing(\(enabled ? "true" : "false"))") { [weak self] value,error in
            if let info = value as? [String:Any] { self?.receiveSmoothing(["traffic":info]) }
            if let error = error { record("Traffic smoothing error: \(error.localizedDescription)") }
        }
    }
    func receiveSmoothing(_ info: [String:Any]) {
        if let raw = info["pedestrian"] as? [String:Any] {
            receiveMotionState("pedestrian", raw: raw, item: pedestrianItem, preferenceKey: "PedestrianSmoothing",
                healthyTooltip: "Smoother pedestrian movement.",
                apply: applyPedestrianSmoothing)
        }
        if let raw = info["traffic"] as? [String:Any] {
            receiveMotionState("traffic", raw: raw, item: trafficItem, preferenceKey: "TrafficSmoothing",
                healthyTooltip: "Smoother movement for scripted road traffic.",
                apply: applyTrafficSmoothing)
        }
    }
    private func receiveMotionState(_ feature: String, raw: [String:Any], item: NSMenuItem,
                                    preferenceKey: String, healthyTooltip: String, apply: (Bool) -> Void) {
        let preference = appPreferences.bool(forKey: preferenceKey)
        let safetyOff = (raw["safetyDisabled"] as? Bool) == true
        let requested = (raw["requested"] as? Bool) ?? (raw["enabled"] as? Bool) ?? false
        item.isEnabled = (raw["available"] as? Bool) == true
        item.state = requested && !safetyOff ? .on : .off
        item.toolTip = safetyOff ? safetyTooltip(feature, reason: raw["safetyReason"] as? String, canRetry: item.isEnabled) : healthyTooltip
        recordMotionState(feature, raw: raw, preference: preference)
        if item.isEnabled && !smoothingInitialized.contains(feature) {
            smoothingInitialized.insert(feature)
            // A real safeguard is never bypassed by startup preferences.
            // A manual menu action may retry if the runtime still reports available.
            if !safetyOff {
                item.state = preference ? .on : .off
                apply(preference)
            }
        }
    }
    private func safetyTooltip(_ feature: String, reason: String?, canRetry: Bool) -> String {
        let detail = reason == "actor_identity_changed"
            ? (feature == "pedestrian" ? "Smoothing was disabled after the character identity changed." : "Smoothing was disabled after the vehicle identity changed.")
            : "Smoothing was disabled by a restore protection check."
        return detail + (canRetry ? " You may switch it on again." : "")
    }
    private func recordMotionState(_ feature: String, raw: [String:Any], preference: Bool) {
        var data: [String:Any] = ["preference":preference]
        for key in ["available","enabled","requested","active","safetyDisabled","safetyReason"] { data[key] = raw[key] ?? NSNull() }
        // enabled was a requested-state alias in 1.2; never infer active or safety.
        if raw["requested"] == nil { data["requested"] = raw["enabled"] ?? NSNull(); data["requestedSource"] = "enabled_alias" }
        let stats = raw["stats"] as? [String:Any]
        data["restoreErrors"] = raw["restoreErrors"] ?? stats?["restoreErrors"] ?? NSNull()
        guard let stable = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let key = String(data: stable, encoding: .utf8), lastMotionLogKeys[feature] != key else { return }
        lastMotionLogKeys[feature] = key
        data["feature"] = feature
        data["event"] = (raw["safetyDisabled"] as? Bool) == true ? "safety_disabled" : "state"
        data["pendingRestore"] = raw["pendingRestore"] ?? NSNull()
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let text = String(data: json, encoding: .utf8) { record("MOTION_STATE " + text) }
    }
    func recordGeometry() {
        guard let container = container, let view = view else { return }
        let data: [String:Any] = ["windowVisible":window.isVisible,"windowMiniaturized":window.isMiniaturized,"windowOnActiveSpace":window.isOnActiveSpace,"appActive":NSApp.isActive,"viewHidden":view.isHidden,"windowOccluded":!window.occlusionState.contains(.visible),"containerWidth":container.bounds.width,"containerHeight":container.bounds.height,"viewportWidth":view.frame.width,"viewportHeight":view.frame.height,"viewportX":view.frame.minX,"viewportY":view.frame.minY,"fullscreen":window.styleMask.contains(.fullScreen),"desiredMode":desiredDisplayMode.rawValue,"windowChecked":windowModeItem.state == .on,"fullscreenChecked":fullScreenModeItem.state == .on,"trafficSmoothing":trafficItem.state == .on,"trafficAvailable":trafficItem.isEnabled,"pedestrianSmoothing":pedestrianItem.state == .on,"pedestrianAvailable":pedestrianItem.isEnabled,"showFPS":fpsVisible,"hudHidden":performanceHUD.isHidden,"hudText":performanceHUD.label.stringValue,"movie":movieView != nil]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),let text = String(data:json,encoding:.utf8) { record("GEOMETRY " + text) }
    }
    @objc func recoverCar() { guard gameReady else { return }; view.evaluateJavaScript("if(Module._emu_js_key){Module._emu_js_key(0xd2,0x2d,1);setTimeout(()=>Module._emu_js_key(0xd2,0x2d,0),120)}") }
    @objc func stats() {
        fpsVisible.toggle()
        appPreferences.set(fpsVisible, forKey: "ShowFPS")
        updateHUDVisibility()
        view.evaluateJavaScript("window.__nativeFPSVisible=\(fpsVisible ? "true" : "false");document.getElementById('hud').classList.add('off')")
    }
    @objc func controls() {
        let a = NSAlert(); a.messageText = "Controls"
        a.informativeText = "Arrow keys: drive and steer\nSpace: handbrake\nBackspace: repair\nC: change camera\nTab: map\nEnter / Escape: select / back\nCmd + R: recover vehicle (Insert)\nView: window or fullscreen in the original 4:3 aspect ratio\nDouble-click or Ctrl + Cmd + F: toggle fullscreen\n\nClick the game window if the keyboard does not respond. Career saves are stored locally in this app’s persistent WebKit storage. Network games use the original game’s Network Game menu after configuring a relay in the Multiplayer menu."
        a.runModal(); window.makeFirstResponder(view)
    }
    @objc func about() {
        let a = NSAlert(); a.messageText = "Carmageddon II for Apple silicon"
        a.informativeText = "Native Apple-silicon app host using WebKit. The original PC game runs through the Carmageddon II Web runtime (x86 → WebAssembly, Glide → WebGL 2).\n\nOriginal game © Stainless Software / SCi. Web runtime: Carter54git, GPLv3. Original game files are not included; import your own licensed copy."
        a.runModal()
    }
    func fail(_ text: String) { let a = NSAlert(); a.alertStyle = .critical; a.messageText = "Carmageddon II"; a.informativeText = text; a.runModal(); NSApp.terminate(nil) }
    func windowDidResignKey(_ notification: Notification) {
        view?.evaluateJavaScript("if(window.__releaseGameKeys)window.__releaseGameKeys();if(window.__resetNativeFPS)window.__resetNativeFPS();")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if flushing { return .terminateNow }
        guard let view = view else { return .terminateNow }
        flushing = true
        let finish = { [weak self] in
            guard let self = self, !self.repliedToTermination else { return }
            self.repliedToTermination = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        view.callAsyncJavaScript("if(typeof Module!=='undefined'&&typeof Module.flushGameStorage==='function'){await Module.flushGameStorage();}else{await new Promise(resolve=>{try{if(typeof FS==='undefined'){resolve();return;}if(Module.__syncTimer)clearTimeout(Module.__syncTimer);FS.syncfs(false,e=>resolve());}catch(e){resolve();}})}", arguments: [:], in: nil, in: .page) { result in
            record("Save flush completed: \(result)")
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        server?.listener.cancel()
        multiplayer.stop()
        record("Host stopped")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.host == "127.0.0.1" && url.port == Int(gamePort) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { smoothingInitialized.removeAll(); lastMotionLogKeys.removeAll(); record("Page loaded"); window.makeFirstResponder(view); view.evaluateJavaScript("document.getElementById('canvas').focus()") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record("Navigation error \(error)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { record("WebKit content process terminated"); fail("The WebKit game process stopped. You can reopen the app. Diagnostic log: \(logURL.path)") }
    func playVideo(_ name: String) {
        guard ["mix_intr", "toprank"].contains(name), movieView == nil,
              let url = gameDataRoot?.appendingPathComponent("video/" + name + ".mp4"),
              FileManager.default.fileExists(atPath: url.path) else {
            view.evaluateJavaScript("if(window.__finishNativeVideo)window.__finishNativeVideo();")
            record("Native video skipped: missing or unrecognized \(name)")
            return
        }
        record("Native video starting: \(name)")
        view.evaluateJavaScript("if(window.__resetNativeFPS)window.__resetNativeFPS();")
        let overlay = NativeMovieView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.controlsStyle = .none
        overlay.videoGravity = .resizeAspect
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.skip = { [weak self] in self?.finishVideo(reason: "skip") }
        let player = AVPlayer(url: url)
        overlay.player = player
        movieView = overlay
        updateHUDVisibility()
        overlay.frame = view.bounds
        view.addSubview(overlay)
        window.makeFirstResponder(overlay)
        if let item = player.currentItem {
            movieObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.finishVideo(reason: "ended") }
            movieStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { DispatchQueue.main.async { self?.finishVideo(reason: "error \(item.error?.localizedDescription ?? "unknown")") } }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            if self?.movieView?.player?.currentItem?.status != .readyToPlay { self?.finishVideo(reason: "load timeout") }
        }
        movieTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        player.play()
    }
    func finishVideo(reason: String) {
        guard let movie = movieView else { return }
        record("Native video finished: \(reason)")
        movieTimeout?.cancel(); movieTimeout = nil
        movieStatus?.invalidate(); movieStatus = nil
        if let observer = movieObserver { NotificationCenter.default.removeObserver(observer); movieObserver = nil }
        movie.player?.pause(); movie.player = nil
        movie.removeFromSuperview(); movieView = nil
        updateHUDVisibility()
        window.makeFirstResponder(view)
        view.evaluateJavaScript("if(window.__finishNativeVideo)window.__finishNativeVideo();if(window.__resetNativeFPS)window.__resetNativeFPS();document.getElementById('canvas').focus();")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeFPS", let payload = message.body as? [String:Any] { receiveFPS(payload); return }
        if message.name == "nativeQuality", let payload = message.body as? [String:Any] { receiveQuality(payload); return }
        if message.name == "nativeSmoothing", let payload = message.body as? [String:Any] { receiveSmoothing(payload); return }
        if message.name == "nativeVideo", let payload = message.body as? [String:Any], let name = payload["name"] as? String { playVideo(name); return }
        if let text = message.body as? String {
            if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_MENUS" { recordMenuTitles() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_GEOMETRY" { recordGeometry() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_FPS_TOGGLE" { stats() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_WINDOW" { chooseWindowMode() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_FULLSCREEN" { chooseFullScreenMode() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_TRAFFIC_TOGGLE" { toggleTraffic() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_PEDESTRIAN_TOGGLE" { togglePedestrians() }
            else if ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_SNAPSHOT" { diagnosticSnapshot() }
            else if parallelTest && ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_SKIP_VIDEO" { finishVideo(reason: "test skip") }
            else if parallelTest && ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_ACTIVATE" { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); recordGeometry() }
            else if parallelTest && ProcessInfo.processInfo.environment["C2_COMMAND_FILE"] != nil && text == "DIAGNOSTIC_QUIT" { NSApp.terminate(nil) }
            else if text == "FULLSCREEN" { fullscreen() }
            else if text == "GAME_EXIT" { record("Game exited normally"); NSApp.terminate(nil) }
            else { record(text) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(foregroundWindow ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
