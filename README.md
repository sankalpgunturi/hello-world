# FlipCam

A personal camera for an iPhone 17 Pro. Record one clip, flip between the back and front cameras while it is rolling, and zoom the whole time.

## Install it for free

You need a Mac with Xcode 26 or newer from the Mac App Store. A paid Apple Developer account is not required. Expo is not used.

1. Open `FlipCam.xcodeproj`.
2. In Xcode, open Settings → Accounts and sign in with the Apple ID already on your iPhone. Xcode calls this a Personal Team.
3. Select the FlipCam target, open Signing & Capabilities, and choose that Personal Team.
4. Connect the iPhone, unlock it, and tap Trust.
5. On the iPhone, turn on Settings → Privacy & Security → Developer Mode and restart.
6. Choose your iPhone as the run destination and press Run.
7. The first launch asks you to trust the developer under Settings → General → VPN & Device Management, then allow the camera and microphone.

The free install expires after 7 days. Plug the phone back into the Mac and press Run again when it does.

## Use it

- Pinch the picture to zoom, including while recording. Lens buttons are 0.5×, 1×, 2×, 4×, and 8×. Zoom stops at 15×, same as the system video camera.
- Light-press Camera Control to use the system zoom slider. Click Camera Control, or the volume buttons, to start and stop.
- Tap the flip button to switch cameras. The recording stays one file. The picture cuts briefly. The microphone keeps going.
- Double-tap the picture to return to 1×. Tap once to focus.
- The torch is on the back camera only.
- Stop the recording and it saves to Photos. The thumbnail replays the last clip and can share it.

Clips are 1080p HEVC at 30 fps so both cameras can share one file. The front preview is mirrored while you film. The saved video is not, matching the iPhone camera, so text reads correctly.
