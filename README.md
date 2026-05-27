# VoiceLev — Releases

Distribuição binária e instalador do **VoiceLev** — assistente de voz da Lev/Onn (ditado por voz + chat com a base de conhecimento).

Os binários **NÃO ficam neste repo** (são grandes, ~171 MB). Estão como *assets* nas releases.

---

## Instalação rápida (Windows 10/11)

Dois jeitos — escolha o que prefere. Ambos funcionam **sem privilégios de admin**.

### Opção 1: dois cliques (mais fácil)

Baixe o instalador e dê duplo-clique:

➡️ [**Instalar-VoiceLev.cmd**](https://github.com/GoLevHQ/voicelev-releases/releases/latest/download/Instalar-VoiceLev.cmd)

> Na primeira vez o Windows SmartScreen pode pedir confirmação porque o arquivo veio da internet:
> "**Mais informações**" → "**Executar mesmo assim**".

A janela mostra o progresso e fecha quando termina. Pode minimizar e fazer outras coisas — não precisa fazer nada além disso.

### Opção 2: PowerShell (mais técnico)

Abra o PowerShell (Tecla Windows → "PowerShell" → Enter, **sem precisar de "Executar como administrador"**) e cole:

```powershell
irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex
```

O que isso faz (**instalação invisível** — nada no Desktop, nada no Start Menu, sem prompts):

1. Detecta a última release neste repo
2. Baixa `VoiceLev.exe` (~171 MB, self-contained — inclui o .NET 10 runtime)
3. Instala em `%LOCALAPPDATA%\Programs\VoiceLev\`
4. Cria config em `%APPDATA%\VoiceLev\config.json` (URL do backend + token compartilhado fase-1a)
5. Registra `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\VoiceLev` — app inicia minimizado a cada login do Windows
6. Registra **Tarefa Agendada do Windows** (`VoiceLev Auto Update`) — daily às 4h + a cada login. Toda release nova propaga automaticamente em até 24h, sem ação manual
7. Inicia agora

Tempo total: ~30s na primeira instalação. Re-execuções (e cada disparo do auto-update) levam ~5s quando já está na versão certa (early-exit). O usuário não vê nenhuma alteração visível no sistema — o app fica só na tray, ativado por hotkeys globais.

## Como funciona o auto-update

A partir da v0.10.3+:

1. Você publica uma release nova (ex: `v0.10.5`) com o `VoiceLev.exe` como asset
2. Em até 24h (ou no próximo login do usuário) cada máquina dispara a tarefa agendada
3. A tarefa baixa este `install.ps1`, descobre que a release atual no GitHub é `v0.10.5`, compara com a versão local
4. Se igual → no-op em ~5s, máquina segue como está
5. Se diferente → mata o `VoiceLev.exe` atual, baixa o novo, troca, reinicia (transparente; usuário não vê janela)

Mensagens locais (`%APPDATA%\VoiceLev\chat-last.json`) sobrevivem ao restart porque vivem fora do install dir.

Pra forçar update imediato numa máquina específica via SSH:
```bash
ssh maquina-x 'powershell -NoProfile -Command "Start-ScheduledTask -TaskName \"VoiceLev Auto Update\""'
```

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
.\install.ps1 -NoAutoStart            # não registrar no HKCU\...\Run (default: registra)
.\install.ps1 -NoAutoUpdate           # não criar Tarefa Agendada de auto-update (default: cria)
.\install.ps1 -WithDesktopShortcut    # criar atalho no Desktop (default: NÃO cria)
.\install.ps1 -NoLaunch               # baixar e instalar mas não iniciar agora
.\install.ps1 -Version v0.10.2        # versão específica em vez do latest
```

### Deploy massivo via SSH

Pra rolar instalações em N máquinas sem precisar tocar em cada uma (admin do TI):

```bash
# Da sua maquina (Mac/Linux) com SSH configurado para os hosts:
for host in maquina1 maquina2 maquina3; do
  ssh "$host" "powershell -NoProfile -Command \"irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex\""
done
```

Cada execução é idempotente: re-rodar atualiza pra o latest sem efeitos colaterais.

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

# Remove Tarefa Agendada de auto-update
Unregister-ScheduledTask -TaskName 'VoiceLev Auto Update' -Confirm:$false -ErrorAction SilentlyContinue

# Remove desktop shortcut (se existir de versão antiga)
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
