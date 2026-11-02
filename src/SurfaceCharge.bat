@echo off
chcp 65001 >nul
title Surface Charge Control
:: ==========================================================================
::  SurfaceCharge.bat  -  Surface Pro 12" Smart Charging (80%% limit) control
::  Double-click -> UAC prompt -> colored menu (unlock / limit / status / live)
::  CLI:  SurfaceCharge.bat unlock | limit80 | default | status
::  https://github.com/TonbiLX/surface-charge-limit
:: ==========================================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo  Requesting administrator rights...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
  )
  exit /b
)
color 0B
set "ACT=%~1"
if "%ACT%"=="" set "ACT=menu"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SurfaceCharge.ps1" -Lang en -Action %ACT%
if /i not "%ACT%"=="menu" pause
