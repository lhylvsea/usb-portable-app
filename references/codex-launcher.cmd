@echo off
setlocal
set "ROOT=%~dp0"
set "PROFILE=%ROOT%data\profile"
set "USERPROFILE=%PROFILE%"
set "HOME=%PROFILE%"
set "HOMEDRIVE=%~d0"
set "HOMEPATH=%PROFILE:~2%"
set "CODEX_PORTABLE_ROOT=%ROOT:~0,-1%"
set "CODEX_HOME=%PROFILE%\.codex"
set "APPDATA=%PROFILE%\AppData\Roaming"
set "LOCALAPPDATA=%PROFILE%\AppData\Local"
set "XDG_CONFIG_HOME=%PROFILE%\.config"
set "XDG_DATA_HOME=%PROFILE%\.local\share"
set "XDG_CACHE_HOME=%PROFILE%\.cache"
set "GIT_CONFIG_GLOBAL=%PROFILE%\.gitconfig"
set "NPM_CONFIG_USERCONFIG=%PROFILE%\.npmrc"
set "NPM_CONFIG_CACHE=%LOCALAPPDATA%\npm-cache"
set "PIP_CONFIG_FILE=%PROFILE%\pip\pip.ini"
set "PIP_CACHE_DIR=%LOCALAPPDATA%\pip\Cache"
set "PYTHONUSERBASE=%APPDATA%\Python"
set "UV_CACHE_DIR=%LOCALAPPDATA%\uv\cache"
set "DOTNET_CLI_HOME=%PROFILE%\.dotnet"
set "CARGO_HOME=%PROFILE%\.cargo"
set "RUSTUP_HOME=%PROFILE%\.rustup"

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%portable\Prepare-Portable.ps1" -PortableRoot "%ROOT:~0,-1%" -Mode Launch
if errorlevel 1 (
  echo Portable environment preparation failed.
  pause
  exit /b 1
)

if exist "%ROOT%portable\Repair-DependencyRecords.ps1" (
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%portable\Repair-DependencyRecords.ps1" -VendorDir "%ROOT%app\resources\vendor" -DataDir "%PROFILE%\.codex"
  if errorlevel 1 (
    echo Dependency self-heal check failed.
    pause
    exit /b 1
  )
)

start "" "%ROOT%app\ChatGPT.exe" %*
endlocal
