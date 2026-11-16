# Installs or updates AgentBar for Windows for this user (no administrator rights):
#   irm https://raw.githubusercontent.com/chenjingdev/agent-bar/main/windows/install.ps1 | iex
# It puts the signed official node.exe and AgentBar's scripts in %LOCALAPPDATA%\Programs\AgentBar, adds a
# Start menu entry, opens AgentBar at Windows sign-in (first install only) and starts it.
# $env:AGENTBAR_ZIP names a local AgentBar-windows-x64.zip to install instead of the published one.
& {
  $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
  $repo = 'chenjingdev/agent-bar'
  $dir = Join-Path $env:LOCALAPPDATA 'Programs\AgentBar'
  $work = Join-Path $env:TEMP ("agentbar-install-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $zip = $env:AGENTBAR_ZIP
    if (-not $zip) {
      $version = (Invoke-RestMethod "https://raw.githubusercontent.com/$repo/main/windows/VERSION").Trim()
      $zip = Join-Path $work 'AgentBar.zip'
      Write-Host "AgentBar $version ..."
      Invoke-WebRequest "https://github.com/$repo/releases/download/windows-v$version/AgentBar-windows-x64.zip" -OutFile $zip -UseBasicParsing
    }
    Expand-Archive -Path $zip -DestinationPath $work
    $new = Join-Path $work 'AgentBar'
    # The only program in it is Node.js as its makers signed it.
    $signature = Get-AuthenticodeSignature (Join-Path $new 'node.exe')
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=OpenJS Foundation') { throw 'node.exe is not the signed official Node.js.' }

    $first = -not (Test-Path $dir)
    $node = Join-Path $dir 'node.exe'; $main = Join-Path $dir 'app\main.mjs'
    if (Test-Path $main) { & $node --disable-warning=ExperimentalWarning $main --quit | Out-Null; Start-Sleep -Milliseconds 800 }
    if (-not $first) { Remove-Item $dir -Recurse -Force }
    Copy-Item $new $dir -Recurse

    $arguments = "--headless `"$node`" --disable-warning=ExperimentalWarning `"$main`""
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'AgentBar.lnk'))
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $shortcut.Arguments = "$arguments --show"
    $shortcut.IconLocation = Join-Path $dir 'AgentBar.ico'
    $shortcut.Description = 'AgentBar'
    $shortcut.Save()
    if ($first) { Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name AgentBar -Value "conhost.exe $arguments" }
    $entry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentBar'
    New-Item $entry -Force | Out-Null
    Set-ItemProperty $entry -Name DisplayName -Value 'AgentBar'
    Set-ItemProperty $entry -Name DisplayVersion -Value (Get-Content (Join-Path $dir 'VERSION') -Raw).Trim()
    Set-ItemProperty $entry -Name Publisher -Value 'chenjingdev'
    Set-ItemProperty $entry -Name DisplayIcon -Value (Join-Path $dir 'AgentBar.ico')
    Set-ItemProperty $entry -Name InstallLocation -Value $dir
    Set-ItemProperty $entry -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'uninstall.ps1')`""
    Set-ItemProperty $entry -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty $entry -Name NoRepair -Value 1 -Type DWord

    Start-Process (Join-Path $env:SystemRoot 'System32\conhost.exe') -ArgumentList "$arguments --show"
    Write-Host "AgentBar $((Get-Content (Join-Path $dir 'VERSION') -Raw).Trim()) is installed. Its icon is in the notification area (under ^ at first)."
  } finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
