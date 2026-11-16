# Removes AgentBar for Windows. The accounts AgentBar keeps (%USERPROFILE%\.agentbar) stay: they hold the
# sign-ins of the accounts not in use. Delete that folder yourself to forget them.
$dir = Join-Path $env:LOCALAPPDATA 'Programs\AgentBar'
$node = Join-Path $dir 'node.exe'; $main = Join-Path $dir 'app\main.mjs'
if (Test-Path $main) { & $node --disable-warning=ExperimentalWarning $main --quit | Out-Null; Start-Sleep -Milliseconds 800 }
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name AgentBar -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentBar' -Recurse -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'AgentBar.lnk') -ErrorAction SilentlyContinue
Set-Location $env:TEMP
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'AgentBar is removed.'
