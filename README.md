# aumilabel

A macOS command-line printer driver for 15 × 30 mm AumiLabel thermal labels. It connects directly to the printer's Bluetooth Classic RFCOMM service; the vendor app is not needed.

> Tested with `AL-26C4`. This is an unofficial reverse-engineered driver.

## Install

Requirements: macOS with Xcode Command Line Tools / Swift.

```bash
git clone https://github.com/NigelThorne/aumilabel.git
cd aumilabel
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/AumiLabelProbe ~/.local/bin/aumilabel
```

Ensure `~/.local/bin` is on your `PATH`.

## Use

Load a new roll or fix alignment:

```bash
aumilabel calibrate
```

Print text using any installed macOS font:

```bash
aumilabel print --text "Hello" --font SnellRoundhand
aumilabel print --text "Nigel loves you" --text "Cath" --font SignPainter-HouseScript
aumilabel print --text "Hello" --font SnellRoundhand --invert
```

Long text automatically shrinks to fit. Repeating `--text` produces multiple lines; the first is above the next.

Print a QR code:

```bash
aumilabel print --qr "https://example.com"
```

Other commands:

```bash
aumilabel status
aumilabel fonts --filter script
aumilabel connect       # retain the Bluetooth connection; Ctrl-C to disconnect
aumilabel print-black   # current canvas diagnostic
aumilabel print-overscan # hardware limit diagnostic
```

## Protocol notes

The printer accepts Bluetooth Classic Serial Port Profile (RFCOMM channel 2). Labels use the vendor's 96 × 207 dot receipt-mode raster framing and `LABELAT1` completion command. `calibrate` sends the vendor `LABELV1` sequence.

## Development

```bash
swift test
swift build -c release
```
