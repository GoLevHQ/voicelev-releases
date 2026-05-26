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
# O que faz (instalacao INVISIVEL por default -- nada no Desktop / Start Menu):
#   1. Baixa VoiceLev.exe (self-contained, ~171 MB) do GitHub Releases
#      pra %LOCALAPPDATA%\Programs\VoiceLev\VoiceLev.exe
#   2. Cria config em %APPDATA%\VoiceLev\config.json com URL do backend +
#      token compartilhado fase-1a
#   3. Registra entrada em HKCU\Software\Microsoft\Windows\CurrentVersion\Run
#      pro app iniciar minimizado a cada login (tray icon + hotkeys globais)
#   4. Registra Tarefa Agendada do Windows que re-roda este script daily as 4h
#      + a cada login -- propaga novas releases AUTOMATICAMENTE em ate 24h
#   5. Inicia o app imediatamente
#
# Idempotente: re-rodar este script eh seguro. Se a versao local ja for a
# desejada, early-exit em ~5s (sem download). Se nao, mata o exe atual,
# baixa+troca, reinicia.
#
# O app nao abre janela ao iniciar -- so registra hotkeys globais:
#   * Shift+Alt+D -- ditar (transcreve audio do mic e cola onde o cursor esta)
#   * Shift+Alt+A -- abrir o chat do assistente
#
# Atalho no Desktop nao eh criado por default (-WithDesktopShortcut pra opt-in).
# Auto-update pode ser desabilitado com -NoAutoUpdate (raramente desejado).
# Pra desinstalar: ver README do repo voicelev-releases.

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$NoAutoStart,
    [switch]$NoAutoUpdate,           # NOVO: pula registro do task de auto-update
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

# ---- 3.5 Re-aplica writes baratos (idempotentes) ANTES do early-exit ----
# Por que aqui: upgrade de installer antigo (sem auto-update task) pra novo
# precisa registrar a task mesmo quando a versao do exe ja eh a final.
# Sem isso, maquinas com exe atual NUNCA pegariam o auto-update.
# Todos esses writes sao idempotentes (sobrescrevem com Force).

# 3.5.a -- Auto-start (HKCU Run -- sem admin)
if (-not $NoAutoStart) {
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'VoiceLev' -Value "`"$ExePath`"" -PropertyType String -Force | Out-Null
}

# 3.5.b -- Auto-update via Task Scheduler (default: ON)
# Registra tarefa agendada que roda este mesmo install.ps1:
#   - Daily 4h (com 0-30min de delay aleatorio pra nao bater todas no GH ao mesmo tempo)
#   - A cada login do usuario (cobre maquinas que ficam off a noite)
# Roda como o proprio usuario (Interactive logon, RunLevel Limited).
if (-not $NoAutoUpdate) {
    $TaskName = 'VoiceLev Auto Update'
    $Cmd = "irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex"
    $Action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$Cmd`""
    $TriggerDaily = New-ScheduledTaskTrigger -Daily -At 4am
    $TriggerDaily.RandomDelay = 'PT30M'
    # -AtLogOn sem -User dispara em qualquer login do user em sessao interativa
    # (PS 5.1 em contas locais nao resolve DOMAIN\user direito; default funciona).
    $TriggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    try {
        # Sem -Principal: o task herda do usuario que esta registrando agora
        # (o mesmo usuario que vai depois disparar -- entao corre como ele
        # mesmo em sessao interativa, com acesso ao HKCU dele).
        Register-ScheduledTask -TaskName $TaskName `
            -Action $Action `
            -Trigger @($TriggerDaily, $TriggerLogon) `
            -Settings $Settings `
            -Force | Out-Null
    } catch {
        Write-Host "Aviso: falha ao registrar task de auto-update ($($_.Exception.Message))." -ForegroundColor Yellow
    }
}

# 3.5.c -- Cleanup de shortcut orfao quando -WithDesktopShortcut nao foi passado
if (-not $WithDesktopShortcut) {
    $LegacyShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VoiceLev.lnk'
    if (Test-Path -LiteralPath $LegacyShortcut) {
        Remove-Item -LiteralPath $LegacyShortcut -Force -ErrorAction SilentlyContinue
    }
}

# 3.5.d -- Config (URL + token compartilhado fase-1a)
# IMPORTANTE: Microsoft.Extensions.Configuration no C# busca SECTIONS
# top-level (configuration.GetSection("VoiceLevApi")). NAO eh nested em
# "voicelev.api". Manter "VoiceLevApi" e "VoiceLev" no MESMO NIVEL.
#
# Bug historico (releases <= v0.10.2): config escrita como
# voicelev.api.AuthToken nao era lida pelo C# -> AuthToken=string.Empty ->
# request sem Authorization header -> HTTP 401 nas maquinas com fresh install.
#
# Token compartilhado da fase 1a. Bloqueia abuso casual de quem topa com o
# endpoint publico, nao eh segredo forte. Per-user token vem na fase 1d.
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$Config = [ordered]@{
    VoiceLevApi = [ordered]@{
        BaseUrl   = 'https://www.golev.com.br/api/voicelev'
        AuthToken = 'voicelev_phase1a_6d5231e535dbd85954edd747002c2379'
    }
    VoiceLev = [ordered]@{
        ProfileSlug      = 'mecanico'
        Hotkey           = 'Shift+Alt+D'
        AssistantHotkey  = 'Shift+Alt+A'
    }
}
$Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

# ---- 3.6 Early-exit se ja esta na versao desejada ----
# Apos os writes baratos. 99% das execucoes do task vao parar aqui em ~5s.
# Comparacao: ProductVersion do exe local vs $Version. ProductVersion vem
# como "0.10.2+gitsha"; comparamos so o prefixo SemVer.
if (Test-Path -LiteralPath $ExePath) {
    try {
        $localFull = (Get-Item -LiteralPath $ExePath).VersionInfo.ProductVersion
        $localSemver = if ($localFull) { $localFull.Split('+')[0].Trim() } else { '' }
        $targetSemver = $Version.TrimStart('v')
        if ($localSemver -eq $targetSemver) {
            Write-Host "VoiceLev $Version ja instalado (auto-update + auto-start re-confirmados)." -ForegroundColor Green
            exit 0
        }
        Write-Host "Atualizando de v$localSemver para $Version..." -ForegroundColor Cyan
    } catch {
        Write-Host "Nao foi possivel ler a versao local; prosseguindo com install full." -ForegroundColor Yellow
    }
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

# Config foi escrita em 3.5.d antes do early-exit (writes idempotentes).

# Auto-start, Task Scheduler e shortcut cleanup ja foram aplicados em 3.5.

# ---- 7. Inicia agora ----
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
