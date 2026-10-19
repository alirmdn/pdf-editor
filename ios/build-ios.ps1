# Runs ios/build-ios.sh inside WSL with full output, like The Auditor's run-wsl.ps1.
# Usage: build-ios.ps1 [dev|build|ipa|engine|xcode]     Log: ios\build-ios.log
param([string]$Mode = "dev")
$log = Join-Path $PSScriptRoot "build-ios.log"
"[$(Get-Date -Format HH:mm:ss)] mode=$Mode" | Out-File $log -Encoding utf8
$wslDir = (wsl -e wslpath -a "$PSScriptRoot").Trim()
$flag = if ($Mode -eq "dev") { "" } else { "--$Mode" }
wsl -u root -e bash -lc "command -v rsync >/dev/null || apt-get install -y -qq rsync >/dev/null 2>&1; echo tools ok" 2>&1 | Tee-Object -FilePath $log -Append
wsl -e bash -lc ". ~/.local/share/swiftly/env.sh 2>/dev/null; bash '$wslDir/build-ios.sh' $flag" 2>&1 | Tee-Object -FilePath $log -Append
"[$(Get-Date -Format HH:mm:ss)] FINISHED" | Out-File $log -Append -Encoding utf8
