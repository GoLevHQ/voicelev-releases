@echo off
setlocal
title Instalando VoiceLev
mode con: cols=72 lines=22
color 0A

echo.
echo  ============================================================
echo    INSTALANDO VOICELEV
echo  ============================================================
echo.
echo  Isso vai instalar o assistente de voz da Lev/Onn:
echo.
echo    1. Baixar o aplicativo (~171 MB)
echo    2. Configurar para iniciar com o Windows
echo    3. Iniciar em segundo plano
echo.
echo  Nao precisa de privilegios de administrador.
echo  Nao precisa fazer mais nada aqui.
echo.
echo  Aguarde ~30 segundos (depende da sua internet).
echo.
echo  ------------------------------------------------------------
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { try { $env:VOICELEV_INSTALL_METHOD = 'cmd'; $env:VOICELEV_TRIGGERED_BY = 'cmd_wrapper'; irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex } catch { Write-Host ''; Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Tente abrir o PowerShell e rodar manualmente:' -ForegroundColor Yellow; Write-Host '  irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 ^| iex' -ForegroundColor Cyan; exit 1 } }"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo  ------------------------------------------------------------
echo.

REM IMPORTANTE: dentro de blocos if/else do cmd.exe, parenteses sem escape
REM em qualquer linha dentro do bloco quebram o parser (fechamento prematuro
REM do bloco). Bug visto em v0.12.0: "(descarta audio)" fechou o if, ambos
REM SUCESSO e FALHOU rodavam. Pra evitar isso a partir de v0.12.1: zero
REM parenteses dentro de strings de echo aqui — reformulamos as frases.
if "%EXITCODE%"=="0" (
    color 0A
    echo    SUCESSO -- VoiceLev esta rodando em segundo plano.
    echo.
    echo    Como usar:
    echo.
    echo      Ctrl Ctrl  -^>  Apertar Ctrl 2x rapido pra COMECAR a gravar
    echo      Ctrl       -^>  Apertar Ctrl 1x pra PARAR e colar o texto
    echo      Esc        -^>  Cancelar gravacao sem colar nada
    echo.
    echo    Atalho antigo Shift+Alt+D tambem continua funcionando.
    echo.
    echo    O app sobe sozinho no proximo login do Windows.
    echo.
    echo  ============================================================
) else (
    color 0C
    echo    FALHOU -- algo deu errado. Exit code: %EXITCODE%
    echo.
    echo    Avise o pessoal do TI [Victor Cruz] com print desta tela.
    echo.
    echo  ============================================================
)

echo.
echo  Pressione qualquer tecla para fechar...
pause >NUL
endlocal
