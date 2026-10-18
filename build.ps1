<#
  One-click build of PDF Editor on this PC (double-click "Build PDF Editor.bat").

  Produces installers\PDF-Editor-<version>-windows-x64.msi (and a portable zip) from the source
  in this folder. The first run takes 20-40 minutes; later runs only rebuild what changed.

  Needs, once: Rust with the MSVC toolchain (rustup.rs), the Visual Studio C++ build tools with the
  Windows SDK, Git, and the .NET SDK (for the WiX installer tool). The script checks each and says
  what is missing. Build files go to %LOCALAPPDATA%\pdf-editor-build, outside OneDrive, so they
  are not synced.
#>
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root

function Need([string] $Command, [string] $Hint) {
  if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "$Command was not found. $Hint" }
}
Need cargo  'Install Rust from https://rustup.rs (choose the MSVC toolchain), then run this again.'
Need git    'Install Git from https://git-scm.com, then run this again.'
Need dotnet 'Install the .NET SDK from https://dotnet.microsoft.com/download, then run this again.'

$Build = Join-Path $env:LOCALAPPDATA 'pdf-editor-build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null
$env:CARGO_TARGET_DIR = Join-Path $Build 'target'
$env:DIST = Join-Path $Build 'dist'
$env:CARGO_INCREMENTAL = '0'

# The fonts the Arabic and Japanese text editing embed (pinned, as in the GitHub workflow).
$Fonts = Join-Path $Build 'craft-fonts'
$FontsRef = '3d9ab3a132ed0eff457e424226a435a901da30d3'
if (-not (Test-Path (Join-Path $Fonts '.git'))) {
  Write-Output '==> Downloading craft-fonts'
  git clone --filter=blob:none https://github.com/storytold/craft-fonts.git $Fonts
  if ($LASTEXITCODE -ne 0) { throw 'git clone of craft-fonts failed' }
}
git -C $Fonts fetch --quiet origin $FontsRef 2>$null
git -C $Fonts checkout --quiet $FontsRef
if ($LASTEXITCODE -ne 0) { throw 'could not check out the pinned craft-fonts commit' }
$env:CRAFT_FONTS_DIR = $Fonts
$env:CRAFT_FONTS_REQUIRED = '1'

# WiX v5 for the MSI.
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
  Write-Output '==> Installing WiX'
  dotnet tool install --global wix --version 5.0.2
  $env:PATH += ";$env:USERPROFILE\.dotnet\tools"
}
wix extension add -g 'WixToolset.UI.wixext/5.0.2' 'WixToolset.Util.wixext/5.0.2' | Out-Null

rustup target add x86_64-pc-windows-msvc | Out-Null

Write-Output '==> Building PDF Editor (this takes a while the first time)'
& (Join-Path $Root 'packaging\windows\package.ps1') -Arch x64

$Out = Join-Path $Root 'installers'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Copy-Item (Join-Path $env:DIST '*') $Out -Force
Write-Output ''
Write-Output "Done. The installer is in $Out"
Get-ChildItem $Out -Filter 'PDF-Editor-*' | ForEach-Object { Write-Output "  $($_.Name)" }
