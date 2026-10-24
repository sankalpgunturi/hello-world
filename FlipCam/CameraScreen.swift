import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var showPlayer = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            chrome
            if camera.phase != .ready {
                gate
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { camera.start() }
        .onCameraCaptureEvent(defaultSoundDisabled: true) { event in
            guard event.phase == .ended, !showPlayer else { return }
            camera.toggleRecording()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.isRecording)
        .sensoryFeedback(.selection, trigger: camera.position)
        .sheet(isPresented: $showPlayer) {
            if let url = camera.latestURL {
                ClipPlayerSheet(url: url)
            }
        }
        .task(id: camera.statusNote?.id) {
            guard camera.statusNote != nil else { return }
            try? await Task.sleep(for: .seconds(2.6))
            camera.statusNote = nil
        }
    }

    private var preview: some View {
        CameraPreview(camera: camera) { point in
            focusPoint = point
            focusToken += 1
        }
        .ignoresSafeArea()
        .overlay {
            ZStack {
                if camera.phase == .ready, let focusPoint {
                    FocusReticle(point: focusPoint, token: focusToken)
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement()
        .accessibilityLabel("Camera preview")
        .accessibilityValue(camera.zoomLabel)
        .accessibilityAdjustableAction { direction in
            camera.multiplyZoom(by: direction == .increment ? 1.2 : 1 / 1.2)
        }
    }

    private var chrome: some View {
        VStack(spacing: 16) {
            topBar
            if let note = camera.statusNote {
                Text(note.text)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
            Spacer().allowsHitTesting(false)
            zoomReadout
            zoomChips
            controls
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .opacity(camera.systemControlsVisible ? 0 : 1)
        .allowsHitTesting(!camera.systemControlsVisible && camera.phase == .ready)
        .animation(.easeInOut(duration: 0.2), value: camera.systemControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: camera.statusNote?.id)
    }

    private var topBar: some View {
        HStack {
            recordingClock
            Spacer()
            torchButton
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private var recordingClock: some View {
        if camera.isRecording, let start = camera.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 0.2)) { context in
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(reduceMotion || pulse ? 1 : 0.35)
                    Text(clock(from: start, to: context.date))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            .onAppear {
                guard !reduceMotion else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { pulse = false }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        } else {
            Color.clear.frame(width: 72, height: 36)
        }
    }

    private var torchButton: some View {
        Button(action: camera.toggleTorch) {
            Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(camera.torchOn ? .yellow : .white)
        .disabled(!camera.torchAvailable)
        .opacity(camera.torchAvailable ? 1 : 0)
        .accessibilityLabel(camera.torchOn ? "Turn torch off" : "Turn torch on")
    }

    private var zoomReadout: some View {
        Text(camera.zoomLabel)
            .font(.system(size: camera.isAdjustingZoom ? 44 : 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, camera.isAdjustingZoom ? 22 : 12)
            .padding(.vertical, camera.isAdjustingZoom ? 8 : 6)
            .glassEffect(.regular, in: .capsule)
            .animation(.spring(duration: 0.28), value: camera.isAdjustingZoom)
    }

    private var zoomChips: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(camera.zoomProfile.presets, id: \.self) { preset in
                    ZoomChip(
                        title: ZoomFormatting.chip(preset),
                        selected: camera.zoomProfile.nearestPreset(to: camera.zoomDisplay) == preset
                    ) {
                        camera.selectZoom(preset)
                    }
                }
            }
        }
    }

    private var controls: some View {
        ZStack {
            HStack {
                clipButton
                Spacer()
                flipButton
            }
            recordButton
        }
        .frame(height: 84)
    }

    private var clipButton: some View {
        Button {
            showPlayer = true
        } label: {
            Group {
                if let thumbnail = camera.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.glass)
        .disabled(camera.latestURL == nil)
        .opacity(camera.latestURL == nil ? 0.45 : 1)
        .accessibilityLabel("Play last recording")
    }

    private var flipButton: some View {
        Button(action: camera.flip) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .frame(width: 52, height: 52)
                .symbolEffect(.rotate, value: camera.position)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(camera.isSwitchingCamera || camera.isFinishing)
        .accessibilityLabel("Flip camera")
    }

    private var recordButton: some View {
        Button(action: camera.toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                if camera.isFinishing {
                    ProgressView()
                        .tint(.white)
                } else if camera.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.canRecord && !camera.isRecording)
        .animation(.spring(duration: 0.28), value: camera.isRecording)
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var gate: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            switch camera.phase {
            case .starting:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            case .unauthorized:
                messageCard(
                    title: "Camera access is off",
                    body: "FlipCam needs the camera and microphone to record. You can turn both on in Settings.",
                    actionTitle: "Open Settings"
                ) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            case .failed(let message):
                messageCard(title: "Camera didn't start", body: message, actionTitle: nil, action: nil)
            case .ready:
                EmptyView()
            }
        }
    }

    private func messageCard(title: String, body: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.title)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 24)
    }

    private func clock(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ZoomChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                chip.buttonStyle(.glassProminent)
            } else {
                chip.buttonStyle(.glass)
            }
        }
    }

    private var chip: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 36)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
        }
        .accessibilityLabel("\(title) times zoom")
    }
}

private struct FocusReticle: View {
    let point: CGPoint
    let token: Int
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(shown ? 1 : 1.4)
            .opacity(shown ? 1 : 0)
            .position(point)
            .onAppear(perform: play)
            .onChange(of: token) { _, _ in play() }
    }

    private func play() {
        shown = false
        withAnimation(.spring(duration: 0.22)) { shown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            withAnimation(.easeOut(duration: 0.25)) { shown = false }
        }
    }
}

private struct ClipPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Last clip")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: url)
                    }
                }
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear { player.pause() }
    }
}
