# VoiceLev -- Installer PowerShell (Windows 10/11)
#
# Instala o VoiceLev (assistente de voz + chat da Lev/Onn) na maquina atual.
# Nao requer admin -- tudo eh per-user.
#
# Uso (PowerShell normal, do Iniciar):
#
#   irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
#
# Ou (versao especifica):
#
#   $env:VOICELEV_VERSION = "v0.10.2"
#   irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
#
# O que faz (instalacao INVISIVEL por default — nada no Desktop / Start Menu):
#   1. Baixa VoiceLev.exe (self-contained, ~171 MB) do GitHub Releases
#      pra %LOCALAPPDATA%\Programs\VoiceLev\VoiceLev.exe
#   2. Cria config em %APPDATA%\VoiceLev\config.json com URL do backend +
#      token compartilhado fase-1a
#   3. Registra entrada em HKCU\Software\Microsoft\Windows\CurrentVersion\Run
#      pro app iniciar minimizado a cada login (tray icon + hotkeys globais)
#   4. Inicia o app imediatamente
#
# O app nao abre janela ao iniciar -- so registra hotkeys globais:
#   * Shift+Alt+D -- ditar (transcreve audio do mic e cola onde o cursor esta)
#   * Shift+Alt+A -- abrir o chat do assistente
#
# Atalho no Desktop nao eh criado por default (-WithDesktopShortcut pra opt-in).
# Pra desinstalar: ver README do repo voicelev-releases.

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$NoAutoStart,
    [switch]$WithDesktopShortcut,   # OPT-IN: por default nao cria atalho (instalacao invisivel)
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # acelera Invoke-WebRequest sem progress bar UI

# ---- 1. Resolucao de versao ----
# Sem flag: pega o env var, depois o latest release tag do GitHub.
if (-not $Version) {
    if ($env:VOICELEV_VERSION) {
        $Version = $env:VOICELEV_VERSION
    } else {
        Write-Host "Verificando ultima versao no GitHub..." -ForegroundColor Cyan
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
    throw "LOCALAPPDATA nao existe: $env:LOCALAPPDATA"
}
# Mata instancia anterior pra liberar o arquivo pra sobrescrever.
Get-Process -Name 'VoiceLev' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Encerrando instancia anterior do VoiceLev (PID $($_.Id))..." -ForegroundColor Yellow
    $_ | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# ---- 4. Cria diretorios ----
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# ---- 5. Download do binario ----
Write-Host "Baixando $DownloadUrl..." -ForegroundColor Cyan
Write-Host "  (~171 MB single-file self-contained -- inclui o .NET 10 runtime)" -ForegroundColor DarkGray
$tmp = "$ExePath.download"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tmp -UseBasicParsing
} catch {
    Write-Host "Download falhou. Verifique conexao e que a versao existe:" -ForegroundColor Red
    Write-Host "  $DownloadUrl" -ForegroundColor Red
    throw
}
$bytes = (Get-Item $tmp).Length
if ($bytes -lt 10MB) {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    throw "Arquivo baixado eh pequeno demais ($bytes bytes) -- provavelmente HTML de erro do GitHub. Confira a versao."
}
Move-Item -LiteralPath $tmp -Destination $ExePath -Force

# Remove Mark-of-the-Web pra SmartScreen nao bloquear o launch.
Unblock-File -LiteralPath $ExePath -ErrorAction SilentlyContinue

# ---- 6. Config (URL + token compartilhado fase-1a) ----
# Token compartilhado da fase 1a. Bloqueia abuso casual de quem topa com o
# endpoint publico, nao eh segredo forte. Per-user token vem na fase 1d.
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

# ---- 7. Auto-start (HKCU Run -- sem admin) ----
if (-not $NoAutoStart) {
    $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty -Path $RunKey -Name 'VoiceLev' -Value "`"$ExePath`"" -PropertyType String -Force | Out-Null
    Write-Host "Auto-start registrado: HKCU\...\Run\VoiceLev" -ForegroundColor DarkGray
}

# ---- 8. Desktop shortcut (OPT-IN, default off) ----
# Lev quer instalacao invisivel pro usuario: nada no Desktop, nada no Start
# Menu. O app sobe minimizado via HKCU\...\Run e fica so na tray. Pra criar
# o atalho manualmente, passe -WithDesktopShortcut.
$DesktopDir = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir 'VoiceLev.lnk'
if ($WithDesktopShortcut) {
    $WScript = New-Object -ComObject WScript.Shell
    $Shortcut = $WScript.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $ExePath
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Description = "VoiceLev $Version -- Assistente de voz da Lev"
    $Shortcut.Save()
    Write-Host "Shortcut: $ShortcutPath" -ForegroundColor DarkGray
} else {
    # Re-instalacao limpa: se existia atalho de uma instalacao anterior
    # (releases <= v0.10.2 criavam por default), apaga agora pra cumprir a
    # politica "zero footprint visivel".
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue
        Write-Host "Atalho antigo removido: $ShortcutPath" -ForegroundColor DarkGray
    }
}

# ---- 9. Inicia agora ----
if (-not $NoLaunch) {
    Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
}

Write-Host ""
Write-Host "OK -- VoiceLev $Version instalado." -ForegroundColor Green
Write-Host ""
Write-Host "Hotkeys globais:" -ForegroundColor Cyan
Write-Host "  Shift+Alt+D  -- Ditado (transcreve audio do mic e cola onde o cursor esta)" -ForegroundColor White
Write-Host "  Shift+Alt+A  -- Abrir chat do assistente" -ForegroundColor White
Write-Host ""
Write-Host "Tray icon no canto inferior direito permite abrir Settings, Assistente, ou sair." -ForegroundColor White
Write-Host ""
Write-Host "O app SOBE MINIMIZADO no proximo login do Windows (HKCU\...\Run)." -ForegroundColor DarkGray
