# Keychain Cam

A tiny macOS companion for the cheap **"G6" 1080p keychain cameras** sold on [AliExpress](https://www.aliexpress.com/item/1005010428506117.html) (the ones with a 0.96" screen, a flash and a USB‑C port, built around the **HX‑Tech HX330X** chip).

- **Keychain Cam.app**: a live view of the camera over USB with **photos**, **video with sound** and **time‑lapse**.
- **[Web version](https://finns.page/keychain-cam/)**: live view, photos and video in the browser, with nothing to install and offline support (Mac, Windows, Chromebook, Android; source in [`web/`](web/)).
- **[Sound Lab](https://finns.page/keychain-cam/sound/)**: record a clip from the camera mic, loop it and try noise filters (RNNoise and GTCRN AI denoisers, gate, EQ) live; the camera page then uses your settings.
- **Auto‑import**: plug the camera in as a drive and new photos and videos land on your Desktop, sorted by day. The camera's `.avi` videos also get an **`.mp4` copy** that plays in Photos, QuickTime and on phones.

There are no dependencies: everything is plain Swift and AVFoundation, built on your Mac by the install script.

## Install

You need macOS 14 or later and Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/Frothacker/keychain-cam.git
cd keychain-cam
./install.sh
```

This builds `~/Applications/Keychain Cam.app` and installs the auto‑importer. Run it again to update, or run `./uninstall.sh` to remove everything (your photos are kept).

The first time you use each part, macOS asks for permission. Click **Allow**:

| Prompt | From | Why |
|---|---|---|
| Camera, Microphone | Keychain Cam | live view, recording |
| Removable volumes, Desktop | Keychain Cam Importer | read the SD card, copy files to the Desktop |

## Using it

When you plug the camera in by USB, it shows a menu: **Memory**, **PC Camera** or **Photo**.

### PC Camera → Keychain Cam.app

| Action | Button | Key |
|---|---|---|
| Take a photo (1920×1080 JPEG) | Take Photo | Space |
| Start/stop video (H.264 + AAC `.mov`) | Record | R |
| Start/stop time‑lapse (one frame every 1 s to 1 min, played back at 30 fps as `.mp4`) | Start Time‑lapse | T |

Everything is saved to `~/Desktop/Keychain Camera/Webcam/`. The **Sound** menu picks the camera's microphone or your Mac's, and the meter next to it shows the live level. With **Boost quiet sound** on (the default), each recording's sound is raised to a normal level after you stop. It also gets a ~90 Hz high‑pass, a gentle noise gate that turns down the hiss between words, and a soft limiter. Recordings that are already loud are left alone. The camera works as a normal webcam in any other app too (FaceTime, Zoom, OBS…), where it shows up as **"HD video"**.

### Memory → auto‑import

New files are copied to `~/Desktop/Keychain Camera/<date>/<time>_<name>` a couple of seconds after the card mounts. You get a notification and the folder opens. Files are never deleted from the card, and nothing is copied twice. AVI videos are converted with [`importer/avi2mp4.swift`](importer/avi2mp4.swift) (motion‑JPEG + PCM or IMA‑ADPCM → H.264 + AAC), which applies the same sound boost. You can also use it on its own:

```bash
swiftc -O importer/avi2mp4.swift -o avi2mp4
./avi2mp4 VID00001.avi VID00001.mp4             # add --no-boost to keep the original sound level
```

Logs are written to `~/Library/Logs/Keychain Cam/`.

## Tips

- **Set the camera's clock** before you travel, because the import folders use the camera's date.
- **The camera turns itself off**: look for an *Auto Off* / power‑save option in its menu.
- **Battery**: the camera has a charge controller, so leaving it plugged in won't overcharge it. Still, don't leave it on USB for days at a time (lithium cells age faster when they're kept full and warm), and stop using it if it gets hot or swells.
- **The camera mic is very quiet** (speech around −45 dBFS, and its USB volume control does nothing). Boost quiet sound fixes the level, but it's still a tiny mic, so pick **Mac mic** when sound matters. It also tends to cut out: half a second of sound, then pure digital silence. The app watches for this, and if it happens before you press Record it switches **Sound** to **Mac mic** and tells you. During a recording it warns you instead. Replugging the camera sometimes brings the mic back.
- **macOS asks for camera/mic access again after every rebuild**: the build is ad‑hoc signed, so each build looks like a new app to macOS.

## The hardware

| | |
|---|---|
| SoC | HX‑Tech **HX330X** (photo EXIF: `HX-Tech` / `HX330X-V001.001`) |
| USB | `349c:3301`, composite device: UVC video ("HD video"), UAC mic ("HD audio"), mass storage |
| Video over USB | 640×480 to 1920×1080, 30 fps (or 5 fps) |
| On the card | `PHOTO/IMG*.jpg` (2560×1440), `VIDEO/*.avi`, `AUDIO/` |

## Hacking the firmware (not done yet)

Sprite_tm reverse‑engineered a sibling chip, the **HX3302B** in a kids' camera, and found:

- the CPU is a **little‑endian OpenRISC 1000** (OR1K), which is why automatic tools couldn't identify it
- the firmware sits **unencrypted** on a small SPI flash chip, and the camera runs modified firmware **without checking any checksum**

So you could dump the flash with a CH341A programmer and a SOIC‑8 clip (keep that backup!), load it into Ghidra with a little‑endian OR1K processor, and patch it. Ideas: skip straight into recording, disable auto‑off, change the boot screen.

Further reading:
- Sprite_tm, *Reverse engineering and hacking a cheapo kid cam* ([spritesmods.com](https://spritesmods.com/?art=kid_cam))
- [Hackaday: The Surprising Hackability Of A Knock‑Off Chinese Toy Camera](https://hackaday.com/2026/02/03/the-surprising-hackability-of-a-knock-off-chinese-toy-camera)
- [Habr (Russian translation)](https://habr.com/ru/articles/990774)

## Layout

```
app/        Keychain Cam.app (Swift/AppKit/AVFoundation) + build script + icon
importer/   auto-import script and the avi2mp4 converter
web/        the browser version (one HTML file + offline service worker)
tools/      audiocheck: prints a movie's tracks and audio level
install.sh / uninstall.sh
```

## License

MIT
