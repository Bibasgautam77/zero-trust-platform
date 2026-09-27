@echo off
REM ============================================================
REM Enterprise Zero-Trust Access Platform
REM One-click start: does first-time setup automatically, then
REM starts the whole stack every time you run it afterward.
REM Double-click this file, or run it from a terminal in this folder.
REM ============================================================
cd /d "%~dp0"
setlocal enabledelayedexpansion

echo ================================================
echo  Zero-Trust Access Platform - Start
echo ================================================
echo.

REM ---------- 1. Check Docker ----------
where docker >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: Docker is not installed or not on PATH.
    echo Install Docker Desktop from https://www.docker.com/products/docker-desktop
    pause
    exit /b 1
)

docker compose version >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: Docker Compose v2 is required. Update Docker Desktop.
    pause
    exit /b 1
)

docker info >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: Docker Desktop does not appear to be running.
    echo Start Docker Desktop, wait for it to finish starting, then run this again.
    pause
    exit /b 1
)

REM ---------- 2. First-run setup ----------
set FIRST_RUN=0
if not exist ".env" (
    set FIRST_RUN=1
    echo Creating .env from .env.example ...
    copy .env.example .env >nul
    echo IMPORTANT: edit .env and replace all "changeme_*" placeholders before any
    echo real/production use. Continuing with development defaults for now.
    echo.
)

echo Building images (first run can take several minutes)...
docker compose build
if %errorlevel% neq 0 (
    echo ERROR: docker compose build failed. See output above.
    pause
    exit /b 1
)

REM ---------- 3. Start infrastructure first, wait for Postgres ----------
echo Starting infrastructure services (postgres, redis, opa, keycloak)...
docker compose up -d postgres redis opa keycloak
if %errorlevel% neq 0 (
    echo ERROR: failed to start infrastructure services.
    pause
    exit /b 1
)

echo Waiting for Postgres to become healthy...
set /a pgattempts=0
:pgwait
set /a pgattempts+=1
for /f "tokens=*" %%i in ('docker inspect -f "{{.State.Health.Status}}" ztp_postgres 2^>nul') do set PGSTATUS=%%i
if "!PGSTATUS!"=="healthy" goto pgready
if !pgattempts! GEQ 60 (
    echo ERROR: Postgres did not become healthy in time. Check "docker compose logs postgres".
    pause
    exit /b 1
)
timeout /t 2 >nul
goto pgwait
:pgready
echo Postgres is healthy.

REM ---------- 4. Seed default roles + bootstrap admin (idempotent - safe every run) ----------
echo Seeding default roles and bootstrap admin account (skips if already seeded)...
docker compose run --rm backend python -m scripts.seed_data

REM ---------- 5. Start everything else ----------
echo Starting backend and frontend...
docker compose up -d
if %errorlevel% neq 0 (
    echo ERROR: docker compose up failed. See output above.
    pause
    exit /b 1
)

echo Waiting for backend health check...
set /a beattempts=0
:bewait
set /a beattempts+=1
curl -s -o nul -w "%%{http_code}" http://localhost:8000/health > "%TEMP%\ztp_health.txt" 2>nul
set /p HEALTHCODE=<"%TEMP%\ztp_health.txt"
if "%HEALTHCODE%"=="200" goto beready
if !beattempts! GEQ 30 (
    echo WARNING: backend did not report healthy in time. Check "docker compose logs backend".
    goto bedone
)
timeout /t 2 >nul
goto bewait
:beready
echo Backend is healthy.
:bedone

echo.
echo ================================================
echo  Zero-Trust Access Platform is running
echo ================================================
echo  Frontend:  http://localhost:3000
echo  Backend:   http://localhost:8000/docs
echo  Keycloak:  http://localhost:8080  (admin console)
echo  OPA:       http://localhost:8181
echo.
if !FIRST_RUN! EQU 1 (
    echo NOTE: this was the first run. Scroll up to find the printed bootstrap
    echo admin email/password from the seed step above, and edit .env with real
    echo secrets before using this outside your own machine.
    echo.
)
echo Use scripts\stop.bat to stop, or scripts\restart.bat to restart.
echo Run this script again any time - it is safe to re-run.
echo.
pause
endlocal
