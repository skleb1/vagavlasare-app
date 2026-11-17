import UIKit
import WebKit
import AVFoundation
import UserNotifications

/// Visar vågläsarens webbsida (Resources/index.html) och kopplar den till iPhone-kameran.
/// Webbsidan sköter avläsning, sparning och tabell – exakt samma kod som webbversionen.
/// Appen sköter kameran (låst exponering, fokus, färgbalans, zoom, ficklampa), kopiering och delning.
final class ViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private let camera = Camera()
    private let previewView = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.067, green: 0.078, blue: 0.094, alpha: 1)

        let cfg = WKWebViewConfiguration()
        // Sidan laddas från en egen adress (app://local) så att sparade vikter (localStorage) ligger kvar mellan gångerna
        cfg.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: "app")
        cfg.userContentController.add(WeakMessageHandler(self), name: "cam")
        // Sparade vikter och inställningar från appen läggs in innan sidan startar (reserv om webbläsarlagringen töms)
        cfg.userContentController.addUserScript(WKUserScript(source: "window.__nativeStore=\(Self.savedStoreJSON());",
                                                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear            // genomskinlig så att kamerabilden bakom syns
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never   // sidan sköter själv marginaler kring kameran/notchen
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        // Kamerans egen förhandsbild ligger bakom den genomskinliga webbsidan (mjuk bild, 30–60 bilder/s)
        previewView.backgroundColor = .black
        previewView.isUserInteractionEnabled = false
        previewView.clipsToBounds = true
        previewView.layer.cornerRadius = 10
        previewView.isHidden = true
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        previewLayer.videoGravity = .resizeAspectFill   // samma beskärning som sidans kameraruta
        previewView.layer.addSublayer(previewLayer)
        view.addSubview(previewView)
        view.addSubview(webView)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "app://local/index.html")!))
        // Backup när man lämnar appen (hemskärm, annan app, låst skärm)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__onBackground&&window.__onBackground()", completionHandler: nil)
        }

        camera.onFrame = { [weak self] b64, w, h in
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("window.__nativeFrame&&window.__nativeFrame('\(b64)',\(w),\(h))", completionHandler: nil)
            }
        }
        camera.onCaps = { [weak self] json in
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("window.__nativeCaps&&window.__nativeCaps(\(json))", completionHandler: nil)
            }
        }
        camera.onInfo = { [weak self] text in
            let safe = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("window.__nativeInfo&&window.__nativeInfo('\(safe)')", completionHandler: nil)
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // Sidan har laddats: berätta när appens signering går ut (gratis Apple-ID = 7 dagar)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let exp = Self.provisionExpiry() {
            let ms = Int(exp.timeIntervalSince1970 * 1000)
            webView.evaluateJavaScript("window.__nativeApp&&window.__nativeApp({expires:\(ms)})", completionHandler: nil)
        }
    }

    /// Läser utgångsdatumet ur embedded.mobileprovision (finns när appen är installerad med Sideloadly)
    static func provisionExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    // MARK: Påminnelser (lokala notiser – kräver inget betalt utvecklarkonto)
    private func remind(_ m: [String: Any]) {
        let center = UNUserNotificationCenter.current()
        let week = m["week"] as? [String: Any] ?? [:]
        let wantWeek = bool(week["on"]), wantResign = bool(m["resign"]), wantExcel = bool(m["excel"])
        let schedule = {
            center.removePendingNotificationRequests(withIdentifiers: ["vecka", "omsignera", "omsignera2", "excel"])
            if wantWeek {
                var dc = DateComponents()
                dc.weekday = Int(self.num(week["weekday"], 6)); dc.hour = Int(self.num(week["hour"], 8)); dc.minute = Int(self.num(week["minute"], 0))
                let n = Int(self.num(week["n"], 160))
                self.add(center, "vecka", "Dags att väga", "\(n) dosor och \(n) lock den här veckan.", UNCalendarNotificationTrigger(dateMatching: dc, repeats: true))
            }
            if wantResign, let exp = Self.provisionExpiry() {
                let dayBefore = exp.addingTimeInterval(-24 * 3600)
                var dc = Calendar.current.dateComponents([.year, .month, .day], from: dayBefore); dc.hour = 18; dc.minute = 0
                if let when = Calendar.current.date(from: dc), when > Date() {
                    self.add(center, "omsignera", "Installera om i morgon", "Appen slutar starta i morgon. Kör Sideloadly igen – vikterna ligger kvar.", UNCalendarNotificationTrigger(dateMatching: dc, repeats: false))
                }
                let morning = exp.addingTimeInterval(-3 * 3600)
                if morning > Date() {
                    self.add(center, "omsignera2", "Appen slutar starta snart", "Installera om med Sideloadly idag.", UNTimeIntervalNotificationTrigger(timeInterval: morning.timeIntervalSinceNow, repeats: false))
                }
            }
            if wantExcel {
                self.add(center, "excel", "Glöm inte Excel", "Vikterna från vägningen är inte exporterade än.", UNTimeIntervalNotificationTrigger(timeInterval: 2 * 3600, repeats: false))
            }
        }
        if !(wantWeek || wantResign || wantExcel) { schedule(); return }
        center.getNotificationSettings { st in
            if st.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                    if ok { schedule() } else { self.tellDenied() }
                }
            } else if st.authorizationStatus == .denied {
                if self.bool(m["ask"]) { self.tellDenied() }
            } else { schedule() }
        }
    }

    private func add(_ c: UNUserNotificationCenter, _ id: String, _ title: String, _ body: String, _ trigger: UNNotificationTrigger) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func tellDenied() {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript("window.__nativeApp&&window.__nativeApp({denied:true})", completionHandler: nil)
        }
    }

    private func haptic(_ kind: String) {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(kind == "error" ? .error : kind == "success" ? .success : .warning)
    }

    private static let storePrefix = "vagavlasare.store."
    private static func savedStoreJSON() -> String {
        var dict: [String: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(storePrefix) {
            if let s = value as? String { dict[String(key.dropFirst(storePrefix.count))] = s }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // Meddelanden från webbsidan: camMsg({cmd: ...})
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return }
        switch cmd {
        case "start":     camera.start()
        case "stop":      camera.stop()
        case "frameDone": camera.frameDone()
        case "config":    camera.apply(config: m)
        case "zoom":      camera.setZoom(num(m["value"]))
        case "bias":      camera.setBias(num(m["value"]))
        case "expLock":   camera.setExposureLocked(bool(m["value"]))
        case "lens":      camera.setLens(num(m["value"]))
        case "focLock":   camera.setFocusLocked(bool(m["value"]), lens: num(m["lens"], 0.5))
        case "torch":     camera.setTorch(bool(m["value"]))
        case "wb":        camera.setWhiteBalanceLocked(bool(m["value"]))
        case "poi":       camera.focusAndExpose(x: num(m["x"], 0.5), y: num(m["y"], 0.5))
        case "store":
            if let k = m["key"] as? String, let v = m["value"] as? String { UserDefaults.standard.set(v, forKey: Self.storePrefix + k) }
        case "preview":   placePreview(m)
        case "remind":    remind(m)
        case "haptic":    haptic((m["kind"] as? String) ?? "warning")
        case "copy":      UIPasteboard.general.string = (m["text"] as? String) ?? ""
        case "share":     share(name: (m["name"] as? String) ?? "fil", base64: (m["b64"] as? String) ?? "")
        default: break
        }
    }

    /// Lägger kamerabilden exakt där webbsidans kameraruta är (sidans koordinater = skärmpunkter)
    private func placePreview(_ m: [String: Any]) {
        let show = bool(m["show"])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if show {
            let r = CGRect(x: num(m["x"]), y: num(m["y"]), width: num(m["w"]), height: num(m["h"]))
            previewView.frame = r.offsetBy(dx: webView.frame.minX, dy: webView.frame.minY)
            previewLayer.frame = previewView.bounds
            if let c = previewLayer.connection {
                if #available(iOS 17.0, *) {
                    if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                } else if c.isVideoOrientationSupported {
                    c.videoOrientation = .portrait
                }
            }
        }
        previewView.isHidden = !show
        CATransaction.commit()
    }

    private func num(_ v: Any?, _ fallback: Double = 0) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        return fallback
    }
    private func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    /// Visar iPhones delningsmeny (Spara i Filer, Mail, Excel …) för en fil från webbsidan
    private func share(name: String, base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do { try data.write(to: url, options: .atomic) } catch { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(vc, animated: true)
    }
}

/// Undviker att webbvyn håller kvar vykontrollern i minnet
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Levererar filer från appens Resources-mapp under adressen app://local/…
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = String(path.dropFirst())
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let fileURL = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: "vagavlasare", code: 404))
            return
        }
        let mime: String
        switch ext.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js":   mime = "text/javascript; charset=utf-8"
        case "css":  mime = "text/css; charset=utf-8"
        case "png":  mime = "image/png"
        default:     mime = "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
