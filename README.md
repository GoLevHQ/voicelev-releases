# VoiceLev — Releases

Distribuição binária e instalador do **VoiceLev** — assistente de voz da Lev/Onn (ditado por voz + chat com a base de conhecimento).

Os binários **NÃO ficam neste repo** (são grandes, ~171 MB). Estão como *assets* nas releases.

---

## Instalação rápida (Windows 10/11)

Abra o PowerShell (não precisa admin) e cole:

```powershell
irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
```

O que isso faz:

1. Detecta a última release neste repo
2. Baixa `VoiceLev.exe` (~171 MB, self-contained — inclui o .NET 10 runtime)
3. Instala em `%LOCALAPPDATA%\Programs\VoiceLev\`
4. Cria config em `%APPDATA%\VoiceLev\config.json` (URL do backend + token compartilhado fase-1a)
5. Registra `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\VoiceLev` — app inicia minimizado a cada login do Windows
6. Cria atalho no Desktop
7. Inicia agora

Tempo total: ~30s (depende da internet).

### Hotkeys globais (depois de instalar)

| Atalho | Ação |
|---|---|
| `Shift+Alt+D` | Ditar — grava do mic, transcreve, cola onde o cursor está |
| `Shift+Alt+A` | Abrir chat do assistente (RAG na KB Global + tools OpenClaw) |

Tray icon no canto inferior direito permite abrir Settings, Assistente, ou sair.

---

## Instalação com opções

Pra usar flags, baixe o script primeiro e rode local:

```powershell
irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 -OutFile install.ps1
.\install.ps1 -NoAutoStart            # não registrar no HKCU\...\Run
.\install.ps1 -NoDesktopShortcut      # não criar atalho no Desktop
.\install.ps1 -NoLaunch               # baixar e instalar mas não iniciar agora
.\install.ps1 -Version v0.10.2        # versão específica em vez do latest
```

---

## Desinstalação

Por enquanto manual (uninstaller automático fica pra release futura):

```powershell
# Encerra o app
Get-Process VoiceLev -ErrorAction SilentlyContinue | Stop-Process -Force

# Remove instalação + config
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\VoiceLev"
Remove-Item -Recurse -Force "$env:APPDATA\VoiceLev"

# Remove auto-start
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'VoiceLev' -ErrorAction SilentlyContinue

# Remove desktop shortcut
Remove-Item -Force "$env:USERPROFILE\Desktop\VoiceLev.lnk" -ErrorAction SilentlyContinue
```

---

## Logs e troubleshooting

- **App logs**: `%APPDATA%\VoiceLev\logs\voicelev-*.log` (Serilog rolling daily, mantém 14 dias)
- **Config ativo**: `%APPDATA%\VoiceLev\config.json`
- **Histórico local de transcrições**: `%APPDATA%\VoiceLev\history.jsonl`
- **Última conversa do assistente**: `%APPDATA%\VoiceLev\chat-last.json` (restaurada ao reabrir o chat)

---

## Source

O código-fonte fica em [GoLevHQ/whispering](https://github.com/GoLevHQ/whispering) (privado). Este repo (`voicelev-releases`) tem apenas o instalador + releases compiladas.
