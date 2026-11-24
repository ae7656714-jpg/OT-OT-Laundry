@echo off
cd /d "%~dp0"
py -3 -m venv .venv
if errorlevel 1 goto failed
.venv\Scripts\python.exe -m pip install --upgrade pip
.venv\Scripts\python.exe -m pip install -r requirements-desktop.txt
if not exist .env copy .env.example .env
 echo.
echo Installation finished. Edit .env and add the Supabase Publishable Key.
pause
exit /b 0
:failed
echo Python 3 is required. Install Python 3.11 or later.
pause
exit /b 1
