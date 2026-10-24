@echo off
rem Evil Islands VR prototype: runs the game from source in the headset.
rem Needs Godot 4.7 (GODOT below) and a running OpenXR runtime.
setlocal
if "%GODOT%"=="" set GODOT=C:\wsl\godot\4.7.2\Godot_v4.7.2-stable_win64.exe
cd /d "%~dp0"
start "" "%GODOT%" --path game --xr-mode on --rendering-driver vulkan --render-thread safe %*
