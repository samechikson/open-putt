import SwiftUI
import AVFoundation

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer showing the live camera
/// feed for a given capture session.
struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// A static, purely cosmetic gate guide drawn over the preview. The real gate
/// geometry is decided later on the backend, so this is only an aiming aid.
struct GateOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Vertical center line.
                Rectangle()
                    .fill(Color.green.opacity(0.7))
                    .frame(width: 2, height: h)
                    .position(x: w / 2, y: h / 2)

                // Gate marker near the lower third.
                HStack(spacing: w * 0.16) {
                    Capsule().fill(Color.green).frame(width: 4, height: 28)
                    Capsule().fill(Color.green).frame(width: 4, height: 28)
                }
                .position(x: w / 2, y: h * 0.66)
            }
            .allowsHitTesting(false)
        }
    }
}
