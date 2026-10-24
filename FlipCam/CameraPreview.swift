import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraEngine
    var onFocus: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = camera.videoSession
        context.coordinator.camera = camera
        context.coordinator.onFocus = onFocus
        camera.attachPreview(view.previewLayer)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubled(_:)))
        tap.numberOfTapsRequired = 1
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== camera.videoSession {
            uiView.previewLayer.session = camera.videoSession
        }
        context.coordinator.camera = camera
        context.coordinator.onFocus = onFocus
        camera.attachPreview(uiView.previewLayer)
    }

    final class Coordinator: NSObject {
        var camera: CameraEngine?
        var onFocus: ((CGPoint) -> Void)?

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            camera?.handlePinch(gesture)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView, let camera else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            camera.focus(at: devicePoint)
            onFocus?(point)
        }

        @objc func doubled(_ gesture: UITapGestureRecognizer) {
            camera?.resetZoom()
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Preview layer missing")
        }
        return layer
    }
}
