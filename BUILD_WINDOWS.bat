@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo ==============================================
echo OT Laundry - Windows Release Builder
echo ==============================================

where py >nul 2>nul
if errorlevel 1 (
  echo Python Launcher is required. Install Python 3.11 or newer.
  pause
  exit /b 1
)

if not exist ".venv-build\Scripts\python.exe" (
  py -3 -m venv .venv-build
  if errorlevel 1 goto failed
)

.venv-build\Scripts\python.exe -m pip install --upgrade pip
if errorlevel 1 goto failed
.venv-build\Scripts\python.exe -m pip install -r requirements-desktop.txt
if errorlevel 1 goto failed

.venv-build\Scripts\python.exe -m PyInstaller --noconfirm --clean --windowed --onedir --name OT-Laundry --collect-all webview --collect-all clr_loader --hidden-import waitress --hidden-import webview.platforms.edgechromium --add-data "templates;templates" --add-data "static;static" --add-data ".env.example;." desktop.py
if errorlevel 1 goto failed

if exist "release\OT-Laundry-Portable" rmdir /s /q "release\OT-Laundry-Portable"
if not exist "release" mkdir "release"
xcopy "dist\OT-Laundry" "release\OT-Laundry-Portable\" /E /I /H /Y >nul
if errorlevel 1 goto failed
> "release\OT-Laundry-Portable\portable.flag" echo portable
copy /Y README_AR.md "release\OT-Laundry-Portable\README_AR.txt" >nul
copy /Y docs\USER_GUIDE_AR.md "release\OT-Laundry-Portable\USER_GUIDE_AR.txt" >nul

set ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe
if exist "%ISCC%" (
  "%ISCC%" packaging\OT-Laundry.iss
  if errorlevel 1 goto failed
  echo.
  echo Installer created in release folder.
) else (
  echo Inno Setup 6 was not found. Portable build is ready.
  echo Install Inno Setup 6 and compile packaging\OT-Laundry.iss to create Setup.exe.
)

echo.
echo Build completed. Check release folder.
pause
exit /b 0

:failed
echo.
echo Build failed. Read the error above and verify Python/dependencies.
pause
exit /b 1
