# FYP_22311136

JPEG/PDF/PNG file carving app with CPU and Metal GPU scanning modes.

## Platform support

**macOS only.**

This project uses SwiftUI + Metal and is intended to run on macOS.

## Requirements

- macOS
- Xcode (with Command Line Tools)
- Metal Toolchain component installed (if prompted by Xcode)

## How to run

1. Open `FYP_22311136.xcodeproj` in Xcode.
2. Select scheme: `FYP_22311136`.
3. Build and Run on **My Mac**.

## How to use

1. Click **Select** and choose the source image/file to scan.
2. Choose scanning mode:
	- **GPU** (Metal, faster on supported hardware)
	- **CPU** (baseline mode)
3. Select file types to scan (JPEG / PNG / PDF).
4. Click **Start Carving**.
5. Use **Reveal** to open saved carved files in Finder.

## Notes

- Output files are saved under `~/Documents/CarvedJPEGs/<source-name>/`.
- If GPU mode is unavailable on your machine, use CPU mode.