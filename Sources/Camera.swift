import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// Bakre kameran med full kontroll: låst exponering, ljusstyrka, låst fokus, färgbalans, zoom och ficklampa.
/// Bilderna skickas till webbsidan som JPEG (högst ~20 per sekund, nästa skickas först när sidan ritat förra).
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((String, Int, Int) -> Void)?
    var onCaps: ((String) -> Void)?
    var onInfo: ((String) -> Void)?

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "vagavlasare.camera.session")
    private let videoQueue = DispatchQueue(label: "vagavlasare.camera.video")
    private let ciContext = CIContext()
    private var isSetUp = false

    private let lock = NSLock()
    private var waiting = false
    private var lastSent: CFAbsoluteTime = 0
    private let maxFps: Double = 25
    private let maxSide: CGFloat = 1280

    // MARK: Start och stopp

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.onInfo?("Appen har inte tillgång till kameran. Slå på det under Inställningar → Vågläsare.")
                return
            }
            self.sessionQueue.async {
                if !self.isSetUp { self.setUpSession() }
                if !self.session.isRunning { self.session.startRunning() }
                self.reportCaps()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.setTorchNow(false)
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Webbsidan har ritat förra bilden – nästa får skickas
    func frameDone() {
        lock.lock(); waiting = false; lock.unlock()
    }

    private func setUpSession() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: d),
              session.canAddInput(input) else {
            session.commitConfiguration()
            onInfo?("Hittar ingen kamera")
            return
        }
        session.addInput(input)
        device = d

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        // Stående bild
        if let c = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            } else if c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()

        // Kameran ska inte själv ändra fokus/exponering när motivet ändras (handen i bild)
        configureDevice { d in d.isSubjectAreaChangeMonitoringEnabled = false }
        isSetUp = true
    }

    private func reportCaps() {
        guard let d = device else { return }
        let caps: [String: Any] = [
            "minZoom": Double(d.minAvailableVideoZoomFactor),
            "maxZoom": Double(min(d.maxAvailableVideoZoomFactor, 10)),
            "minBias": Double(d.minExposureTargetBias),
            "maxBias": Double(d.maxExposureTargetBias),
            "hasTorch": d.hasTorch,
            "lensPosition": Double(d.lensPosition)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: caps),
           let json = String(data: data, encoding: .utf8) {
            onCaps?(json)
        }
    }

    // MARK: Inställningar

    private func configureDevice(_ change: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                change(d)
                d.unlockForConfiguration()
            } catch {}
        }
    }

    /// Alla sparade inställningar på en gång (när kameran startar)
    func apply(config m: [String: Any]) {
        func num(_ k: String, _ f: Double) -> Double { (m[k] as? NSNumber)?.doubleValue ?? f }
        func flag(_ k: String) -> Bool { (m[k] as? NSNumber)?.boolValue ?? (m[k] as? Bool) ?? false }
        sessionQueue.async {
            // vänta tills kameran är igång
            if !self.isSetUp { self.sessionQueue.asyncAfter(deadline: .now() + 0.3) { self.apply(config: m) }; return }
            self.setZoom(num("zoom", 1))
            self.setBias(num("bias", 0))
            self.setFocusLocked(flag("focLock"), lens: num("lens", 0.5))
            self.setExposureLocked(flag("expLock"))
            self.setWhiteBalanceLocked(flag("wbLock"))
            self.setTorch(flag("torch"))
        }
    }

    func setZoom(_ z: Double) {
        configureDevice { d in
            let maxZ = Double(min(d.maxAvailableVideoZoomFactor, 10))
            let minZ = Double(d.minAvailableVideoZoomFactor)
            d.videoZoomFactor = CGFloat(max(minZ, min(z, maxZ)))
        }
    }

    /// Ljusstyrka (exponeringskompensation, EV)
    func setBias(_ b: Double) {
        configureDevice { d in
            let v = Float(max(Double(d.minExposureTargetBias), min(b, Double(d.maxExposureTargetBias))))
            d.setExposureTargetBias(v, completionHandler: nil)
        }
    }

    func setExposureLocked(_ on: Bool) {
        configureDevice { d in
            if on {
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
            } else if d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Fast fokus: 0 = nära, 1 = långt bort
    func setLens(_ p: Double) {
        configureDevice { d in
            if d.isFocusModeSupported(.locked) {
                d.setFocusModeLocked(lensPosition: Float(max(0, min(1, p))), completionHandler: nil)
            }
        }
    }

    func setFocusLocked(_ on: Bool, lens: Double) {
        if on {
            setLens(lens)
        } else {
            configureDevice { d in
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { self.setTorchNow(on) }
    }

    private func setTorchNow(_ on: Bool) {
        guard let d = device, d.hasTorch else { return }
        do {
            try d.lockForConfiguration()
            if on, d.isTorchModeSupported(.on) {
                try? d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else if d.isTorchModeSupported(.off) {
                d.torchMode = .off
            }
            d.unlockForConfiguration()
        } catch {}
    }

    func setWhiteBalanceLocked(_ on: Bool) {
        configureDevice { d in
            let mode: AVCaptureDevice.WhiteBalanceMode = on ? .locked : .continuousAutoWhiteBalance
            if d.isWhiteBalanceModeSupported(mode) { d.whiteBalanceMode = mode }
        }
    }

    /// Fokusera och exponera på en punkt i bilden (0–1, stående bild) och lås sedan båda
    func focusAndExpose(x: Double, y: Double) {
        // Kamerans koordinater är liggande: stående (x, y) motsvarar (y, 1 − x)
        let p = CGPoint(x: max(0, min(1, y)), y: max(0, min(1, 1 - x)))
        configureDevice { d in
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = p
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = p
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
        }
        sessionQueue.asyncAfter(deadline: .now() + 1.5) {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                d.unlockForConfiguration()
            } catch {}
            self.onInfo?("Skärpa och ljus är inställda och låsta")
            self.reportCaps()
        }
    }

    // MARK: Bilder

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // Om sidan inte svarat på en sekund (t.ex. laddats om) skickas nästa ändå
        let stuck = waiting && now - lastSent > 1.0
        let skip = (waiting && !stuck) || now - lastSent < 1.0 / maxFps
        if !skip { waiting = true; lastSent = now }
        lock.unlock()
        if skip { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { frameDone(); return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let longSide = max(image.extent.width, image.extent.height)
        let scale = min(1.0, maxSide / longSide)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())

        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.82]) else {
            frameDone(); return
        }
        onFrame?(jpeg.base64EncodedString(), w, h)
    }
}
