# IR Camera Viewer PRO

A single-file **PowerShell + WinForms** app that unlocks the laptop's built-in
**infrared (Windows Hello) camera** and turns two overlooked integrated sensors —
the **ambient light sensor** and the **microphone array** — into live, on-screen
instruments, including a small **acoustic direction "radar."**

No install, no dependencies to build: one `.ps1` file and a `.cmd` launcher.
Recording is the only optional extra (uses `ffmpeg`).

> Why this exists: apps like OBS / VLC **cannot** show the IR camera (it appears
> black with no formats) because the IR sensor is exposed only through **Windows
> Media Foundation**, not DirectShow. This app reads it the correct way.

---

## Demo

https://github.com/user-attachments/assets/dbcc659a-96e0-45d4-b18e-e61c05ed409d

*Full-quality clip: [`IR_Sound_Light_Tool.mp4`](https://github.com/aphongdo/windows-ir-camera-viewer/raw/main/IR_Sound_Light_Tool.mp4) (committed in the repo).*

The demo shows, in order:

| # | What you see | Why it's interesting |
|---|--------------|----------------------|
| 1 | A **person appears in near-total darkness** on the IR feed | The IR illuminator + sensor see without visible light |
| 2 | **Veins on the forearm become visible** | Near-IR (~850–940 nm) penetrates a few mm of skin; blood absorbs NIR more than surrounding tissue, so veins show as dark lines. A normal webcam has an IR-cut filter and **cannot** show this (same principle as medical vein-finders) |
| 3 | Shining a **phone flashlight at the light sensor** makes the **lux value jump** | Live read of the ambient light sensor |
| 4 | **Rubbing two hands together** on the left, then the right | The **radar needle swings LEFT/RIGHT** to follow the sound and the **dB meter rises** with the rubbing |

---

## Features

- **Infrared camera viewer** (Media Foundation) — works where DirectShow/OBS can't.
- **De-flicker** — the IR emitter strobes for Windows Hello; the app drops the dark
  frames so you get a steady image instead of flashing.
- **Auto-brighten** + **Brightness / Contrast / Gamma** sliders + **digital zoom** +
  **mirror** + **fullscreen**.
- **Snapshot** (PNG) and **video recording** (MP4 via ffmpeg) — saved to the Desktop.
- **Light meter** — live ambient light in **lux**.
- **Sound meter** — live level (**dB**) + a **radar gauge** estimating the
  **LEFT / RIGHT** direction of a sound, using the microphone array.

---

## Requirements

### Tested machine

| | |
|---|---|
| Laptop | **Lenovo ThinkBook 16 G7+ AKP** (type 21TJ) |
| CPU | AMD Ryzen AI 7 H 350 w/ Radeon 860M (8 cores / 16 threads) |
| GPU | AMD Radeon 860M |
| RAM | 32 GB |
| OS | Windows 11 Home, build 26200 |
| IR camera | Chicony **Integrated IR Camera** (`VID_04F2&PID_B829`), driver *Realtek DMFT – IR* — **640×360 @30fps, 8-bit grayscale (L8)** |
| Light sensor | Ambient Light Sensor via **AMD Sensor Fusion Hub** |
| Microphone | **Realtek Microphone Array** (2 channels, 48 kHz) |

### What your machine needs (compatibility)

The app is generic, but each feature depends on hardware you actually have:

- **Windows 10 or 11** with **Windows PowerShell 5.1** (built in — no install).
- **IR camera viewing:** an integrated **IR / Windows Hello camera** that Windows
  exposes through Media Foundation (`SourceKind = Infrared`). Most Windows-Hello
  laptops qualify. Resolution/format are whatever your sensor offers.
- **Light meter (optional):** an **ambient light sensor** (WinRT `LightSensor`).
- **Sound meter + direction (optional):** a **2-channel microphone array**.
  The direction estimate is calibrated per-machine and only resolves a LEFT/RIGHT
  axis (see *How it works*).
- **Recording (optional):** **ffmpeg** on PATH — `winget install Gyan.FFmpeg`.

> If a given sensor is missing, that button simply reports it and the rest still works.

---

## Install & Run

```text
1. Download IR-Camera-Viewer.ps1 and IR-Camera-Viewer.cmd (keep them together).
2. Double-click IR-Camera-Viewer.cmd
   (it runs: powershell -STA -ExecutionPolicy Bypass -File IR-Camera-Viewer.ps1)
```

- If the IR view is black **and** it says *"We need to reboot"* (`0xC00D7167`):
  restart Windows (this happens after an IR-camera driver change).
- Do **not** replace the IR camera driver with a generic "USB camera" driver — it
  breaks the Realtek DMFT / Windows Hello path this app relies on.

---

## Controls

| Key | Action | | Key | Action |
|-----|--------|---|-----|--------|
| `P` | Snapshot (PNG) | | `M` | Mirror |
| `R` | Record / stop (MP4) | | `F` | Anti-flicker on/off |
| `F11` | Fullscreen | | `S` | Auto-brighten on/off |
| `+` / `-` | Zoom in / out | | `H` | Show/hide bottom bar |
| `Esc` | Exit | | | |

Everything is also on the top **menu bar** (Functions / Image / Sensors / Help).
Sensors are opt-in via the **Light** and **Sound** buttons on the top bar; turning
**Sound** off releases the microphone.

---

## Usage

### View & adjust the image
- The IR feed appears automatically. If it looks dark, keep **Auto-brighten** (`S`)
  on, or drag the **Bright / Contrast / Gamma** sliders on the bottom bar.
- **Anti-flicker** (`F`, on by default) hides the IR emitter's strobing so the image
  is steady instead of flashing.
- **Mirror** (`M`) flips left/right, **Zoom** (`+` / `-`) is a digital centre zoom up
  to 5x, **Fullscreen** is `F11` (`Esc` to leave).

### Take a photo
- Click **Snap** (or press `P`). Saved to the Desktop as
  `IR_snapshot_<date>_<time>.png` — exactly what's on screen (after
  brightness/contrast/gamma, zoom and mirror).

### Record a video
- Click **REC** (or press `R`) to start — the button turns red and reads **STOP**.
- Click again (or `R`) to stop. Saved to the Desktop as `IR_rec_<date>_<time>.mp4`
  (H.264, ~15 fps, grayscale — the de-flickered, adjusted image). Needs **ffmpeg**.

### Read the sensors (top bar)
- **Light** -> live lux; shine a phone flashlight at the sensor to watch it jump.
- **Sound** -> opens the mic (RAW) and shows the **dB level** plus the **radar
  needle**. Make broadband sound (music, clapping, rubbing hands) on the left/right
  to see the needle swing. **Sensors -> Recenter direction** re-zeros the needle when
  the room is quiet.

---

## How it works (technical)

1. **IR = Media Foundation only.** The IR sensor reports as `(none)` to DirectShow,
   so OBS/VLC/ffmpeg-dshow see black with no formats. The app uses WinRT
   `MediaFrameReader` with `SourceKind = Infrared`.
2. **De-flicker.** The IR illuminator strobes on alternate frames (active
   illumination for face recognition). The app measures per-frame brightness and
   drops the dark frames, so the effective rate is ~half but the image is steady.
3. **Image pipeline (C#, compiled at runtime for speed):** per-frame auto-contrast
   stretch + a 256-entry brightness/contrast/gamma lookup table.
4. **Recording:** processed BGRA frames are piped to `ffmpeg` (`rawvideo → libx264`).
5. **Microphone (WASAPI via COM interop):** targets the **"Microphone Array"**
   endpoint *by name* (the default capture device is often the empty 3.5 mm jack).
   It opens in **RAW mode** (`AUDCLNT_STREAMOPTIONS_RAW`) to bypass Realtek's
   noise-suppression/AEC — otherwise quiet ambient sound is gated to exact zero and
   the two channels become identical.
6. **Sound direction (studied carefully):**
   - **Level difference is not usable** here — the array has a large fixed L/R gain
     imbalance and almost no directional level signal.
   - Direction = **TDOA** (cross-correlation time-delay between the two channels),
     auto-centered, mapped `dir = (center − lag) / 3.5`.
   - **Use broadband sound** (music, claps, rubbing hands, voice). A **pure tone
     does not work**: its cross-correlation is periodic (aliased), and the array's
     per-frequency phase response even flips the apparent direction between
     frequencies. Broadband averages those phase errors out to the true geometric
     delay. Measured ground truth (music): **LEFT → lag +4, RIGHT → lag −3.**
   - Two closely-spaced mics ⇒ **LEFT/RIGHT axis only**, angle approximate —
     not a full 360° radar.

---

## Limitations

- IR resolution is fixed by the sensor (here **640×360 grayscale**) — it cannot be
  increased in software.
- IR needs some infrared light; the built-in emitter is short-range (~0.5–1 m).
  Daylight or an external 850 nm illuminator helps.
- Sound direction is LEFT/RIGHT only and works best with broadband sound.
- A "proper" angle upgrade would need FFT-based **GCC-PHAT** with a per-frequency
  phase-offset calibration curve.

## Output files

`Desktop\IR_snapshot_YYYYMMDD_HHMMSS.png` and `Desktop\IR_rec_YYYYMMDD_HHMMSS.mp4`.

## Privacy

The app accesses your **camera** and (when you enable Sound) your **microphone**,
locally only — nothing is uploaded. Snapshots/recordings stay on your Desktop.

## Author

**Julian** — [dohoanghuan@gmail.com](mailto:dohoanghuan@gmail.com)

Issues, questions, and pull requests are welcome.

## License

MIT © 2026 Julian — see [`LICENSE`](LICENSE). Provided as-is; hardware IDs and
calibration numbers above are specific to the tested laptop and may differ on yours.
