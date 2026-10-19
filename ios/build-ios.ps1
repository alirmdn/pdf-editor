# Runs ios/build-ios.sh inside WSL with full output, like The Auditor's run-wsl.ps1.
# Usage: build-ios.ps1 [dev|build|ipa|engine|xcode]     Log: ios\build-ios.log
param([string]$Mode = "dev")
$log = Join-Path $PSScriptRoot "build-ios.log"
"[$(Get-Date -Format HH:mm:ss)] mode=$Mode" | Out-File $log -Encoding utf8
$wslDir = (wsl -e wslpath -a "$PSScriptRoot").Trim()
$flag = if ($Mode -eq "dev") { "" } else { "--$Mode" }
# rsync, and a C toolchain: Rust's build scripts are linked with the host's cc.
wsl -u root -e bash -lc "if ! command -v cc >/dev/null || ! command -v rsync >/dev/null; then echo 'Installing build tools (build-essential, rsync)...'; apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential rsync >/dev/null 2>&1; fi; command -v cc >/dev/null && echo tools ok || echo 'could not install build-essential'" 2>&1 | Tee-Object -FilePath $log -Append
wsl -e bash -lc ". ~/.local/share/swiftly/env.sh 2>/dev/null; bash '$wslDir/build-ios.sh' $flag" 2>&1 | Tee-Object -FilePath $log -Append
"[$(Get-Date -Format HH:mm:ss)] FINISHED" | Out-File $log -Append -Encoding utf8
