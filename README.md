<p align="center">
  <img src="docs/images/icon.png" width="128" alt="LowerX icon">
</p>

<h1 align="center">LowerX</h1>

<p align="center">
  <b>English</b> · <a href="README.pt-BR.md">Português</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  Unofficial macOS companion for the <b>HyperX Cloud Stinger 2 Wireless</b>.<br>
  NGENUITY only exists for Windows; LowerX does the same job on the Mac.
</p>

<p align="center">
  <img src="docs/images/audio.png" width="820" alt="LowerX main window, Audio tab">
</p>

## Features

- **Battery, charging and headset status**, with the percentage in the menu bar.
- **Microphone**: shows in real time whether it is muted (boom raised).
- **Sidetone**: on/off plus two levels, **Padrão** (Standard, −25 dB, factory) and **Otimizado** (Optimized, −12 dB).
- **Auto power-off**: never, 10, 20 or 30 minutes.
- **10-band equalizer** (works on any headphones or speakers) with NGENUITY's official presets (Bass Boost, Bass Cut, Treble Boost, Treble Cut, Voice Chat, Gaming, Balanced) and a custom mode: drag the points on the graph.
- **Spatial** (any headphones): stereo music and video sound like speakers in front of you (Apple's HRTF).
- **7.1 output**: a virtual 8-channel sound output. Games and movies in 7.1 get each channel placed in 3D on the headset.
- **Discord certification**: Discord recognizes the headset, as it does with NGENUITY on Windows.
- **Other HyperX devices**: recognizes 56 models (159 USB IDs) and shows a photo of each. They have no controls yet.

The interface is currently in Portuguese (pt-BR). [Translations are welcome!](#contributing)

<p align="center">
  <img src="docs/images/headset.png" width="560" alt="Headset tab">
  <img src="docs/images/panel.png" width="250" alt="Menu bar panel">
</p>

## Supported devices

| Device | Status |
|---|---|
| HyperX Cloud Stinger 2 Wireless | ✅ Full support |
| Any headphones or speakers | 🎧 Equalizer and spatial (7.1 output is still Stinger 2 only) |
| 55 other HyperX models (headsets, keyboards, mice, microphones, mouse pads) | 🔍 Detected with name and photo, no controls yet. [Contributions welcome!](#contributing) |

## Requirements

- macOS 14.2 or later.
- HyperX Cloud Stinger 2 Wireless (USB receiver `03F0:0D93`).
- Xcode (or the Command Line Tools) to build.

## Build and install

```sh
./build-app.sh          # builds and installs /Applications/LowerX.app
```

The app is ad-hoc signed. The first time the equalizer or spatial is used, macOS asks for the **system audio recording** permission. The **7.1 output** is installed by the app itself (it asks for the administrator password).

For the 7.1 output to play after a restart, turn on **Abrir no login** (Open at login) in Settings.

<p align="center">
  <img src="docs/images/settings.png" width="560" alt="Settings">
</p>

## How it works

### Headset protocol

The protocol was reconstructed from `NGenuity2Helper.exe` (part of the NGENUITY 2.38 installer) and verified on the device. Everything goes through 20-byte HID reports on the vendor collection `0xFF90`/`0x0303`, formatted as `06 FF BB <cmd> <value>`:

| cmd | function | response |
|---|---|---|
| `01` | status | `r[4]` = 1 or 4: headset on; 3: off |
| `02` | battery | `r[7]` = % |
| `03` | charging | 1 charging · 2 full · 3 error |
| `05` | microphone | 1 = muted |
| `06` / `21` | read / set sidetone on | |
| `07` / `22` | read / set auto power-off (min) | |
| `0B` / `23` | read / set sidetone level (signed dB) | |
| `20` | spontaneous microphone boom event | 1 = muted |

Write commands echo `cmd value 01` to every connected program. The sidetone level only takes effect when sidetone is switched on, so the app turns it off and on again when the level changes.

> ⚠️ The sidetone level is a signed dB gain: positive values amplify a lot (`0x20` = +32 dB is deafening). The app only sends the two tested levels.

### Equalizer and spatial

On Windows, EQ and spatial are DTS Headphone:X, a system audio effect; none of it runs on the headset. On the Mac:

1. A Core Audio **process tap** (macOS 14.2+) captures the audio apps send to the headset and mutes the original.
2. A private aggregate device joins the tap and the headset; its IOProc processes and plays the result.
3. Chain: source → spatial (`AUSpatialMixer`, HRTF) → EQ (10 biquads per channel, anti-clipping pre-gain) → headset.

If the app quits, the tap goes away and sound returns to normal.

In spatial mode, whatever is identical in both channels goes to a single center virtual speaker. Playing the same signal on two virtual speakers creates notches in the spectrum (−15 dB at 2 kHz) and makes everything sound muffled.

### 7.1 output

`Driver/LowerX71.c` is a custom AudioServerPlugIn driver: an 8-channel output (L R C LFE Ls Rs Rls Rrs) that only provides the clock and discards the audio. The app captures that output with the same tap and places each channel: fronts at ±30°, center at 0°, sides at ±90° and rears at ±150°. When an app sends only stereo to it, the spatial setting decides how it plays.

### Discord

The app calls Discord's local RPC (`127.0.0.1:6463–6472`) with `SET_CERTIFIED_DEVICES` and HyperX's `client_id`, using the headset's Core Audio UID, just like NGENUITY.

## Project layout

```
Sources/LowerX/
  StingerProtocol.swift   headset commands and responses
  HIDTransport.swift      IOHIDManager
  HeadsetModel.swift      state and command queue (120 ms between sends)
  SystemAudioEQ.swift     tap + aggregate device + effects chain
  SpatialRenderer.swift   upmix and AUSpatialMixer
  Equalizer.swift         presets and filters
  AudioEffects.swift      when to run the pipeline, 7.1 output, permissions
  DiscordCertifier.swift  Discord certification
  USBDeviceWatcher.swift  other HyperX devices (IOKit, no input monitoring permission)
  DeviceCatalog.swift     generated from tools/
  MainWindow.swift, LowerXApp.swift, Theme.swift, EqualizerGraph.swift   UI
Driver/                   virtual 7.1 output
tools/                    scripts to regenerate the catalog, images and icon
```

### Tools

| script | generates |
|---|---|
| `tools/extract_catalog.py` + `tools/gen_catalog_swift.py` | `DeviceCatalog.swift`, from `NGenuity2Helper.exe` decompiled with `ilspycmd` |
| `tools/prepare_device_images.py` | `Assets/Devices`, one image per model, from `Assets/Devices` in the NGENUITY package |
| `tools/make_icon.swift` | `Assets/AppIcon.icns` |

## Contributing

Improvements are very welcome, and so are pull requests! 🙌

Some ideas:

- **Other HyperX devices.** The protocols are in NGENUITY: decompile `NGenuity2Helper.exe` with `ilspycmd`; each device's classes live in `NGenuity2.Devices.*`. If you own the device, implement it, test it and send a PR. Start with reads (battery, status) before write commands.
- **7.1 output on other headphones**: it works on the Stinger 2; testing on other headphones is welcome.
- **UI translations**: the interface is currently in Portuguese.
- **Bugs and suggestions**: open an issue.

When sending a PR, describe what you tested and on which device and macOS version. Please don't include installer files or decompiled NGENUITY code.

> ⚠️ Be careful when testing write commands: gains may be in dB (sidetone at +32 dB was deafening). Start with low values and the headset away from your ears.

## Credits

- Product images: **HyperX**, from each product's press materials.
- [Saira](https://github.com/Omnibus-Type/Saira) font, SIL Open Font License (`Assets/Fonts/OFL.txt`).
- HyperX, NGENUITY and Cloud Stinger are trademarks of HP Inc. LowerX is an independent project, not affiliated with HyperX or HP.
