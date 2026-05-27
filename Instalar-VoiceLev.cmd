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

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { try { irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 | iex } catch { Write-Host ''; Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Tente abrir o PowerShell e rodar manualmente:' -ForegroundColor Yellow; Write-Host '  irm https://raw.githubusercontent.com/GoLevHQ/voicelev-releases/main/install.ps1 ^| iex' -ForegroundColor Cyan; exit 1 } }"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo  ------------------------------------------------------------
echo.

if "%EXITCODE%"=="0" (
    color 0A
    echo    SUCESSO -- VoiceLev esta rodando em segundo plano.
    echo.
    echo    Atalho global:
    echo.
    echo      Shift+Alt+D  -^>  Ditar transcricao em qualquer campo
    echo.
    echo    O app sobe sozinho no proximo login do Windows.
    echo.
    echo  ============================================================
) else (
    color 0C
    echo    FALHOU -- algo deu errado ^(exit %EXITCODE%^).
    echo.
    echo    Avise o pessoal do TI ^(Victor Cruz^) com print desta tela.
    echo.
    echo  ============================================================
)

echo.
echo  Pressione qualquer tecla para fechar...
pause >NUL
endlocal
