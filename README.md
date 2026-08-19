# aumilabel

A macOS command-line printer driver for 15 × 30 mm AumiLabel thermal labels. It connects directly to the printer's Bluetooth Classic RFCOMM service; the vendor app is not needed.

> Tested with the [Anko Mini Label Thermal Printer](https://www.kmart.com.au/product/mini-label-thermal-printer-43559312/). This is an unofficial reverse-engineered driver.

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

Target a printer by its advertised name (the easiest option), by Bluetooth address, or by a saved environment variable:

```bash
aumilabel print --device AL-1234 --text "Hello"
aumilabel scan
export AUMILABEL_ADDRESS="25-00-02-00-12-34" # replace with your printer's address
```

`--address` takes precedence over `--device`, which takes precedence over `AUMILABEL_ADDRESS`. Put a printer in pairing mode before using `--device`; the CLI scans for its exact advertised name.

Set a default text font with `AUMILABEL_FONT`; an explicit `--font` always overrides it:

```bash
export AUMILABEL_FONT="SignPainter-HouseScript"
aumilabel print --device AL-1234 --text "Hello"
```

Load a new roll or fix alignment:

```bash
aumilabel calibrate --device AL-1234
```

Print text using any installed macOS font:

```bash
aumilabel print --device AL-1234 --text "Hello" --font SnellRoundhand
aumilabel print --device AL-1234 --text "Nigel loves you" --text "Cath" --font SignPainter-HouseScript
aumilabel print --device AL-1234 --text "Hello" --font SnellRoundhand --invert
```

Long text automatically shrinks to fit. Repeating `--text` produces multiple lines; the first is above the next. GitHub emoji shortcodes are supported (for example `:heart:`, `:tada:`, `:+1:`, `:fire:`, `:octocat:`); the mapping is bundled, so printing does not require an internet connection.

Print a QR code:

```bash
aumilabel print --device AL-1234 --qr "https://example.com"
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
