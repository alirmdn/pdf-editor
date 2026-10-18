# PDF Editor

<img src="assets/app-icon/pdfcraft-small.svg" alt="PDF Editor icon: a red document with a pencil" width="96">

A fast, private PDF editor for Windows: read, edit text and images, organize pages, fill and sign,
comment, protect and export, with Arabic and English text editing. Everything runs on your
computer: no account, no telemetry, no cloud processing.

PDF Editor is a modified version of [PdfCraft](https://github.com/storytold/pdfcraft) 0.9.0
(MIT OR Apache-2.0). It is not affiliated with or endorsed by the PdfCraft or ArtCraft teams.
See [NOTICE](NOTICE), [ATTRIBUTION.md](ATTRIBUTION.md) and the licence files.

## What is different from PdfCraft

- PDF Editor name and red document-and-pencil icon; upstream branding and community links removed.
- A dark, modern theme by default with a red accent, and a redesigned home page.
- Updates are checked against [aliramadann/pdf-editor-support](https://github.com/aliramadann/pdf-editor-support/releases).

## Build (Windows)

Install Rust (MSVC toolchain) and the Visual Studio C++ build tools, then:

```powershell
git clone https://github.com/storytold/craft-fonts ../craft-fonts
$env:CRAFT_FONTS_DIR = (Resolve-Path ../craft-fonts).Path
cargo build --release -p pdfcraft
```

The app is `target/release/pdfcraft.exe`. Installers are built by the `release` GitHub workflow.

Support and privacy: https://aliramadann.github.io/pdf-editor-support/
