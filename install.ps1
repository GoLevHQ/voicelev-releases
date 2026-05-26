# VoiceLev — Installer PowerShell (Windows 10/11)
#
# Instala o VoiceLev (assistente de voz + chat da Lev/Onn) na máquina atual.
# Não requer admin — tudo é per-user.
#
# Uso (PowerShell normal, do Iniciar):
#
#   irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
#
# Ou (uso silencioso, sem prompt):
#
#   $env:VOICELEV_VERSION = "v0.10.2"  # opcional, default = latest
#   irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
#
# O que faz:
#   1. Baixa VoiceLev.exe (self-contained, ~171 MB) do GitHub Releases
#      pra %LOCALAPPDATA%\Programs\VoiceLev\VoiceLev.exe
#   2. Cria config em %APPDATA%\VoiceLev\config.json com URL do backend +
#      token compartilhado fase-1a
#   3. Registra entrada em HKCU\Software\Microsoft\Windows\CurrentVersion\Run
#      pro app iniciar minimizado a cada login (tray icon + hotkeys globais)
#   4. Cria atalho no Desktop pra abertura manual
#   5. Inicia o app imediatamente
#
# O app não abre janela ao iniciar — só registra hotkeys e fica na tray:
#   • Shift+Alt+D — ditar (transcreve áudio do mic e cola onde o cursor está)
#   • Shift+Alt+A — abrir o chat do assistente
#
# Pra desinstalar: remover %LOCALAPPDATA%\Programs\VoiceLev\,
# %APPDATA%\VoiceLev\, HKCU\...\Run\VoiceLev e o shortcut no Desktop.

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$NoAutoStart,
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # acelera Invoke-WebRequest sem o overhead da progress bar UI

# ---- 1. Resolução de versão ----
# Sem flag: pega o env var, depois o latest release tag do GitHub.
if (-not $Version) {
    if ($env:VOICELEV_VERSION) {
        $Version = $env:VOICELEV_VERSION
    } else {
        Write-Host "Verificando última versão no GitHub..." -ForegroundColor Cyan
        try {
            $latest = Invoke-RestMethod -Uri 'https://api.github.com/repos/GoLevHQ/voicelev-releases/releases/latest' -ErrorAction Stop
            $Version = $latest.tag_name
        } catch {
            Write-Host "Falha ao consultar GitHub. Defina `$env:VOICELEV_VERSION manualmente." -ForegroundColor Red
            throw
        }
    }
}
if (-not $Version.StartsWith('v')) { $Version = "v$Version" }
Write-Host "VoiceLev $Version" -ForegroundColor Green

# ---- 2. Paths ----
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\VoiceLev"
$ConfigDir  = Join-Path $env:APPDATA "VoiceLev"
$ExePath    = Join-Path $InstallDir "VoiceLev.exe"
$ConfigPath = Join-Path $ConfigDir "config.json"
$DownloadUrl = "https://github.com/GoLevHQ/voicelev-releases/releases/download/$Version/VoiceLev.exe"

# ---- 3. Pre-flight ----
if (-not (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
    throw "LOCALAPPDATA não existe: $env:LOCALAPPDATA"
}
# Mata instância anterior pra liberar o arquivo pra sobrescrever.
Get-Process -Name 'VoiceLev' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Encerrando instância anterior do VoiceLev (PID $($_.Id))..." -ForegroundColor Yellow
    $_ | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# ---- 4. Cria diretórios ----
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# ---- 5. Download do binário ----
Write-Host "Baixando $DownloadUrl..." -ForegroundColor Cyan
Write-Host "  (~171 MB single-file self-contained — inclui o .NET 10 runtime)" -ForegroundColor DarkGray
$tmp = "$ExePath.download"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tmp -UseBasicParsing
} catch {
    Write-Host "Download falhou. Verifique conexão e que a versão existe:" -ForegroundColor Red
    Write-Host "  $DownloadUrl" -ForegroundColor Red
    throw
}
if ((Get-Item $tmp).Length -lt 10MB) {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    throw "Arquivo baixado é pequeno demais ($((Get-Item $tmp).Length) bytes) — provavelmente HTML de erro do GitHub. Confira a versão."
}
Move-Item -LiteralPath $tmp -Destination $ExePath -Force

# Remove Mark-of-the-Web pra SmartScreen não bloquear o launch.
Unblock-File -LiteralPath $ExePath -ErrorAction SilentlyContinue

# ---- 6. Config (URL + token compartilhado fase-1a) ----
# Token compartilhado da fase 1a. Bloqueia abuso casual de quem topa com o
# endpoint público, não é segredo forte. Per-user token vem na fase 1d.
$Config = @{
    voicelev = @{
        api = @{
            BaseUrl   = 'https://www.golev.com.br/api/voicelev'
            AuthToken = 'voicelev_phase1a_6d5231e535dbd85954edd747002c2379'
        }
        ProfileSlug      = 'mecanico'
        Hotkey           = 'Shift+Alt+D'
        AssistantHotkey  = 'Shift+Alt+A'
    }
}
$Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Config: $ConfigPath" -ForegroundColor DarkGray

# ---- 7. Auto-start (HKCU Run — sem admin) ----
if (-not $NoAutoStart) {
    $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty -Path $RunKey -Name 'VoiceLev' -Value "`"$ExePath`"" -PropertyType String -Force | Out-Null
    Write-Host "Auto-start registrado: HKCU\...\Run\VoiceLev" -ForegroundColor DarkGray
}

# ---- 8. Desktop shortcut ----
if (-not $NoDesktopShortcut) {
    $DesktopDir = [Environment]::GetFolderPath('Desktop')
    $ShortcutPath = Join-Path $DesktopDir 'VoiceLev.lnk'
    $WScript = New-Object -ComObject WScript.Shell
    $Shortcut = $WScript.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $ExePath
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Description = "VoiceLev $Version — Assistente de voz da Lev"
    $Shortcut.Save()
    Write-Host "Shortcut: $ShortcutPath" -ForegroundColor DarkGray
}

# ---- 9. Inicia agora ----
if (-not $NoLaunch) {
    Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
}

Write-Host ""
Write-Host "✓ VoiceLev $Version instalado." -ForegroundColor Green
Write-Host ""
Write-Host "Hotkeys globais:" -ForegroundColor Cyan
Write-Host "  Shift+Alt+D  — Ditado (transcreve audio do mic e cola onde o cursor está)" -ForegroundColor White
Write-Host "  Shift+Alt+A  — Abrir chat do assistente" -ForegroundColor White
Write-Host ""
Write-Host "Tray icon no canto inferior direito permite abrir Settings, Assistente, ou sair." -ForegroundColor White
Write-Host ""
Write-Host "O app SOBE MINIMIZADO no próximo login do Windows (HKCU\...\Run)." -ForegroundColor DarkGray
