@echo off
chcp 65001 >nul
title Surface Sarj Kontrol
:: ==========================================================================
::  SurfaceSarj.bat  -  Surface Pro 12" Akilli Sarj (%%80 siniri) kontrol
::  Cift tikla -> yonetici onayi -> renkli menu (ac / kapat / durum / canli)
::  Komut satiri:  SurfaceSarj.bat unlock | limit80 | default | status
::  https://github.com/TonbiLX/surface-charge-limit
:: ==========================================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo  Yonetici izni isteniyor...
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SurfaceCharge.ps1" -Lang tr -Action %ACT%
if /i not "%ACT%"=="menu" pause
