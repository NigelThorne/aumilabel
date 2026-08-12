# AumiLabel macOS CLI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provide an installable macOS command-line app that calibrates and prints arbitrary text in a selected system font to the paired AumiLabel printer.

**Architecture:** Keep the confirmed RFCOMM and AumiLabel raster protocol in Swift. Replace hard-coded Hello rendering with an AppKit text rasterizer that accepts text, font, size, rotation, and label dimensions. The CLI validates all arguments before connecting and emits concise structured status on stdout.

**Tech Stack:** Swift Package Manager, AppKit, IOBluetooth, XCTest.

---

### Task 1: Define CLI input and validation

**Files:**
- Modify: `Sources/AumiLabelProbe/AumiLabelProbe.swift`
- Test: `Tests/AumiLabelProbeTests/ProtocolTests.swift`

**Step 1:** Write failing tests for valid text-print arguments, missing text, unknown command, and unsupported font.

**Step 2:** Run `swift test` and confirm the new tests fail.

**Step 3:** Implement a command parser:
- `status [--address ADDRESS]`
- `calibrate [--address ADDRESS]`
- `print --text TEXT [--font FONT] [--size POINTS] [--address ADDRESS]`
- `fonts [--filter TEXT]`

Defaults: known AL-26C4 address, Snell Roundhand, rotated portrait text, confirmed 96×207 canvas.

**Step 4:** Run `swift test` and confirm pass.

### Task 2: Generalize text rasterization

**Files:**
- Modify: `Sources/AumiLabelProbe/AumiLabelProbe.swift`
- Test: `Tests/AumiLabelProbeTests/ProtocolTests.swift`

**Step 1:** Write failing tests proving arbitrary text creates the confirmed 96×207 receipt-mode frame and spans the expected label axis.

**Step 2:** Run `swift test` and confirm fail.

**Step 3:** Implement real AppKit font rendering with scale-to-fit, optional font face, black/white thresholding, and clockwise rotation.

**Step 4:** Run `swift test` and confirm pass.

### Task 3: Make output and installation ergonomic

**Files:**
- Create: `README.md`
- Modify: `Sources/AumiLabelProbe/AumiLabelProbe.swift`

**Step 1:** Add concise help and structured stdout result fields: `status`, `printer`, `job`, `response`.

**Step 2:** Document build/install to `~/.local/bin/aumilabel`, all commands, current supported scope, and calibration requirement after loading labels.

**Step 3:** Run `swift test` and `swift build -c release`.

### Task 4: Hardware verification

**Files:** none

**Step 1:** Run `swift run AumiLabelProbe status`.

**Step 2:** Run `swift run AumiLabelProbe print --text "Hello" --font SnellRoundhand`.

**Step 3:** Confirm printer returns `LABELOK` and user verifies the printed label.
