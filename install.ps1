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
#   * Ctrl Ctrl (2x rapido, ate' 400ms) -- comeca a gravar
#   * Ctrl 1x       -- para a gravacao, processa e cola
#   * Esc           -- cancela gravacao em curso (descarta audio, nao cola)
#   * Shift+Alt+D   -- atalho LEGADO ainda ativo em paralelo (toggle)
#
# Modo Assistente (Shift+Alt+A) foi desabilitado em v0.10.4 pra focar feedback
# no ditado puro. Pra reativar, flip AssistantEnabled=true no config.json.
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

# ---- 2.5 Telemetria (v0.11.0+) ----
# Endpoints /api/voicelev/telemetry/* recebem dados pra dashboard interno.
# Tudo fire-and-forget: erro em telemetria NUNCA quebra o install. Cliente
# Windows (VoiceLev.exe) calcula o mesmo fingerprint e envia heartbeats.
$TelemetryBase = 'https://www.golev.com.br/api/voicelev/telemetry'
$TelemetryToken = 'voicelev_phase1a_6d5231e535dbd85954edd747002c2379'

# Fingerprint estavel: SHA256(MachineGuid + '|' + SID-do-usuario-windows).
# - MachineGuid (HKLM\SOFTWARE\Microsoft\Cryptography) e' setado uma vez no
#   primeiro boot do Windows e persiste por toda a vida do SO (mesmo apos
#   reinstall do VoiceLev). Muda apenas em sysprep / reinstall do Windows.
# - SID do user separa contas diferentes na mesma maquina (se 2 funcionarios
#   compartilham PC, cada um e' uma "maquina logica" no dashboard).
# - Output: 64-char lowercase hex (consumido pelo regex no endpoint).
function Get-VoiceLevFingerprint {
    try {
        $machineGuid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    } catch {
        # Fallback inesperado: usa hostname (menos estavel mas funciona). Log
        # so' aparece se o usuario rodar com -Verbose; nao vamos quebrar.
        Write-Verbose "MachineGuid indisponivel ($($_.Exception.Message)). Usando hostname como fallback."
        $machineGuid = $env:COMPUTERNAME
    }
    try {
        $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    } catch {
        Write-Verbose "SID indisponivel ($($_.Exception.Message)). Usando username."
        $sid = $env:USERNAME
    }
    $raw = "$machineGuid|$sid"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

# POST async pra endpoint de telemetria. Sempre fire-and-forget: try/catch
# engole TUDO. Retorna $true se 2xx, $false se erro. Timeout curto pra nao
# travar o installer se a rede estiver lenta.
function Send-VoiceLevTelemetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,                 # ex: 'register-device' (sem barra)

        [Parameter(Mandatory=$true)]
        [hashtable]$Body,

        [int]$TimeoutSec = 8
    )
    $url = "$TelemetryBase/$Path"
    $bodyJson = $Body | ConvertTo-Json -Depth 5 -Compress
    try {
        $resp = Invoke-RestMethod -Uri $url `
            -Method POST `
            -Headers @{ 'Authorization' = "Bearer $TelemetryToken" } `
            -ContentType 'application/json' `
            -Body $bodyJson `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
        return $resp
    } catch {
        Write-Verbose "Telemetria $Path falhou: $($_.Exception.Message)"
        return $null
    }
}

# Captura fingerprint UMA vez por execucao do script.
$Fingerprint = Get-VoiceLevFingerprint

# Versao local atual (string crua), pre-troca. Usado pra emitir update_event
# com from_version preenchido quando ha mismatch. $null se nao instalado.
$LocalVersionBefore = $null
if (Test-Path -LiteralPath $ExePath) {
    try {
        $vi = (Get-Item -LiteralPath $ExePath).VersionInfo.ProductVersion
        if ($vi) { $LocalVersionBefore = $vi.Split('+')[0].Trim() }
    } catch { }
}

# install_method vem do env var setado pelo wrapper Instalar-VoiceLev.cmd.
# Sem env, assume ps1 (one-liner irm | iex direto no PowerShell). Pra forcar:
#   $env:VOICELEV_INSTALL_METHOD = 'manual'
# antes de invocar o script (uso raro, so' debug).
$InstallMethod = if ($env:VOICELEV_INSTALL_METHOD) { $env:VOICELEV_INSTALL_METHOD } else { 'ps1' }
if ($InstallMethod -notin @('cmd', 'ps1', 'manual')) {
    Write-Verbose "VOICELEV_INSTALL_METHOD invalido ('$InstallMethod'), usando 'ps1'."
    $InstallMethod = 'ps1'
}

# Triggered_by pro update_event: distingue se rodada veio do Task Scheduler
# (auto-update agendado) vs invocacao manual. Heuristica simples: presence
# de VOICELEV_TRIGGERED_BY env var setada pelo scheduled task Action.
$TriggeredBy = if ($env:VOICELEV_TRIGGERED_BY) { $env:VOICELEV_TRIGGERED_BY } else { 'manual_irm' }

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
    # IMPORTANTE: Register-ScheduledTask (PS cmdlet) registra tasks na RAIZ do
    # Task Scheduler Library, o que requer admin no Windows 10/11 com UAC
    # default. Usuarios sem elevacao recebem "Access is denied".
    #
    # Solucao: usar schtasks.exe diretamente com XML que declara o Principal
    # como InteractiveToken + LeastPrivilege (usuario atual sem admin). Isso
    # cria task per-user que NAO requer elevacao. Funciona em ambos os casos:
    # admin OR sem admin. Mais portavel que o cmdlet PS.
    $TaskName = 'VoiceLev Auto Update'
    # Sete VOICELEV_TRIGGERED_BY antes do irm pra que o install.ps1 emita
    # telemetria com triggered_by='scheduled_task' (diferencia auto-update
    # automatico de invocacao manual irm|iex na dashboard).
    $Cmd = "`$env:VOICELEV_TRIGGERED_BY='scheduled_task'; irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex"
    # Escape pra XML: a aspa dupla do irm vai como &quot;
    $CmdEscaped = $Cmd.Replace('"', '&quot;')

    # StartBoundary precisa ser timestamp local em formato ISO (sem timezone).
    # Usamos amanha 4h pra primeira execucao; depois cai no ritmo diario.
    $startBoundary = (Get-Date).Date.AddDays(1).AddHours(4).ToString('yyyy-MM-ddTHH:mm:ss')

    # XML minimal aceito pelo schtasks.exe /Create /XML em qualquer versao do
    # Windows 10/11. Ordem dos elementos dentro de Settings/CalendarTrigger eh
    # IMPORTANTE -- schema XSD do Task Scheduler eh strict.
    $TaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <RandomDelay>PT30M</RandomDelay>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$CmdEscaped"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    # schtasks /Create /XML precisa do arquivo em UTF-16 LE (com BOM). Usamos
    # Unicode encoding do PS pra garantir.
    $xmlPath = Join-Path $env:TEMP "voicelev-task-$([Guid]::NewGuid().ToString('N')).xml"
    try {
        [System.IO.File]::WriteAllText($xmlPath, $TaskXml, [System.Text.Encoding]::Unicode)
        # /F = sobrescreve se ja existe. /XML = registra do arquivo.
        $out = & schtasks.exe /Create /TN $TaskName /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Aviso: schtasks /Create falhou (exit $LASTEXITCODE): $out" -ForegroundColor Yellow
            Write-Host 'Auto-update ficara manual. Pra atualizar: re-rodar o one-liner irm | iex.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Aviso: falha ao registrar task de auto-update ($($_.Exception.Message))." -ForegroundColor Yellow
    } finally {
        if (Test-Path -LiteralPath $xmlPath) {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
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
        # v0.10.4: assistente desabilitado por enquanto. Flip pra $true depois
        # que reativar (e adicionar de volta o item no tray de App.axaml).
        AssistantEnabled = $false
    }
    Telemetry = [ordered]@{
        # v0.11.0: VoiceLev.exe envia heartbeat + dictation events pro
        # backend (/api/voicelev/telemetry/*). Flip pra $false pra desligar
        # silenciosamente sem mexer no resto do config.
        Enabled                  = $true
        # Intervalo do heartbeat (timer Avalonia dispara periodico). Pode
        # ser '01:00:00' (1h), '06:00:00' (6h), etc. Minimo: 5min (clamp).
        HeartbeatInterval        = '06:00:00'
        # Quando true, transcription_text do ditado e' enviado pro Supabase
        # em voicelev_dictation_events. Default false (LGPD-friendly: so'
        # metadata vai junto — chars/duration/success).
        IncludeTranscriptionText = $false
        RequestTimeout           = '00:00:08'
    }
    HotkeyDoubleTap = [ordered]@{
        # v0.12.0: hotkey principal e' "Ctrl Ctrl pra comecar, Ctrl pra parar".
        # Detector via low-level keyboard hook (so' single Ctrl tap puro
        # conta — Ctrl+C/V/T/etc nao disparam ditado por engano). O atalho
        # antigo Shift+Alt+D continua funcionando em paralelo nesta release.
        Enabled           = $true
        # Janela em ms entre o 1º e o 2º Ctrl tap. 400ms e' generoso (Discord
        # usa 250-300ms). Aumentar deixa mais facil; muito alto pode causar
        # false-positives.
        DoubleTapWindowMs = 400
    }
}
$Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

# 3.5.e -- Telemetria: register-device (UPSERT idempotente por fingerprint)
# Acontece ANTES do early-exit pra que toda execucao do script atualize
# last_seen e voicelev_version no Supabase. Resposta inclui is_new=true se
# primeira vez que essa fingerprint aparece — usamos pra distinguir
# first_install de reinstall no install_event abaixo.
$osCaption = $null
$osBuild = $null
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osCaption = $os.Caption
    $osBuild = $os.BuildNumber
} catch {
    Write-Verbose "Win32_OperatingSystem unavailable ($($_.Exception.Message))."
}
$osVersion = if ($osCaption -and $osBuild) { "$osCaption (build $osBuild)" } else { $null }

$registerResp = Send-VoiceLevTelemetry -Path 'register-device' -Body @{
    fingerprint      = $Fingerprint
    hostname         = $env:COMPUTERNAME
    windows_user     = $env:USERNAME
    os_version       = $osVersion
    voicelev_version = $Version.TrimStart('v')
    install_method   = $InstallMethod
    metadata         = @{
        ps_version = $PSVersionTable.PSVersion.ToString()
    }
}
$DeviceId = $null
$IsNewDevice = $false
if ($registerResp -and $registerResp.status -eq 'ok') {
    $DeviceId = $registerResp.device_id
    $IsNewDevice = [bool]$registerResp.is_new
}

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
            # Importante: se o app ja estava rodando, ele tem a config VELHA em
            # memoria (cached no boot anterior). Pra ele pegar a config que a
            # gente acabou de reescrever em 3.5.d, precisa restartar.
            # Isso eh barato (~3s) e cobre o caso do bug de config antiga.
            # Sem isso, maquinas que rodaram a v0.10.2 nested ficariam presas
            # no 401 ate o usuario fazer logout/login do Windows.
            $running = @(Get-Process -Name 'VoiceLev' -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                Write-Host "App ja rodando -- restartando pra recarregar config atualizada..." -ForegroundColor Yellow
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800
                Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
            }
            # Telemetria: reinstall_event (re-execucao do installer com versao
            # ja correta — comum em re-runs do scheduled task de auto-update).
            # Em maquina nova (IsNewDevice=true) raro cair aqui: significa que
            # alguem rodou installer manual, deu erro, e rodou de novo na mesma
            # versao. Marcamos como first_install pra dashboard ver "primeira
            # aparicao da maquina" corretamente.
            $eventType = if ($IsNewDevice) { 'first_install' } else { 'reinstall' }
            Send-VoiceLevTelemetry -Path 'install' -Body @{
                fingerprint      = $Fingerprint
                event_type       = $eventType
                voicelev_version = $targetSemver
                install_method   = $InstallMethod
                metadata         = @{
                    reason = 'early_exit_version_match'
                }
            } | Out-Null
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

# ---- 6. Telemetria pos-troca: update_event + install_event ----
# Versao trocou com sucesso. Emite 2 eventos pra dashboard ter visibilidade:
#   - update_event: registra from_version -> to_version (deixa rastrear quais
#     maquinas atualizaram em qual janela; debug de auto-update preso e' aqui)
#   - install_event: first_install (maquina nova) ou reinstall (mesmo PC,
#     versao trocou). Distincao vem do is_new do register-device acima.
$targetSemverPost = $Version.TrimStart('v')
Send-VoiceLevTelemetry -Path 'update' -Body @{
    fingerprint   = $Fingerprint
    from_version  = $LocalVersionBefore
    to_version    = $targetSemverPost
    success       = $true
    triggered_by  = $TriggeredBy
} | Out-Null

$postInstallEventType = if ($IsNewDevice) { 'first_install' } else { 'reinstall' }
Send-VoiceLevTelemetry -Path 'install' -Body @{
    fingerprint      = $Fingerprint
    event_type       = $postInstallEventType
    voicelev_version = $targetSemverPost
    install_method   = $InstallMethod
    metadata         = @{
        from_version = $LocalVersionBefore
        reason       = 'version_changed'
    }
} | Out-Null

# ---- 7. Inicia agora ----
if (-not $NoLaunch) {
    Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
}

Write-Host ""
Write-Host "OK -- VoiceLev $Version instalado." -ForegroundColor Green
Write-Host ""
Write-Host "Hotkey global (NOVO em v0.12.0):" -ForegroundColor Cyan
Write-Host "  Ctrl Ctrl    -- Apertar Ctrl 2x rapido pra COMECAR a gravar" -ForegroundColor White
Write-Host "  Ctrl         -- Apertar Ctrl 1x pra PARAR e colar onde o cursor esta" -ForegroundColor White
Write-Host "  Esc          -- Cancelar gravacao em curso (descarta audio)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Atalho legado Shift+Alt+D continua funcionando como toggle." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Tray icon no canto inferior direito permite abrir Settings ou sair." -ForegroundColor White
Write-Host ""
Write-Host "O app SOBE MINIMIZADO no proximo login do Windows (HKCU\...\Run)." -ForegroundColor DarkGray
