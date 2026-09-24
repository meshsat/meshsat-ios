// The QR scanner the Hub and encryption cards open (Android: the ZXing ScanContract). One
// AVCaptureSession with a metadata output for QR codes; the first code read is handed back and
// the sheet closes. iOS asks for the camera permission by itself on the first use.
import AVFoundation
import SwiftUI

public struct QRScannerSheet: View {
    let prompt: String
    let onScan: (String?) -> Void

    public init(prompt: String, onScan: @escaping (String?) -> Void) {
        self.prompt = prompt
        self.onScan = onScan
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView(onCode: { onScan($0) }).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(prompt).msText(.bodyMedium, color: MSColors.offWhite)
                MSTextButton("Cancel", color: MSColors.offWhite) { onScan(nil) }
            }
            .padding(24)
        }
        .background(Color.black)
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection)
        {
            guard !done, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            done = true
            onCode(code)
        }
    }

    final class ScannerController: UIViewController {
        var coordinator: Coordinator?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
            let output = AVCaptureMetadataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        }
    }
}
