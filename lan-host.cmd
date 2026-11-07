@echo off
set YGO_CONTROL_PORT=7788
set YGO_CTRL_DEBUG=1
if not "%1"=="" set YGO_HOOKS=%1
set DECK=%2
if "%DECK%"=="" set DECK=Blackwing
cd /d D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game
start "" "D:\dsh_workspaces\MC_bot_dsh\mycard-client\bin\release\x64\YGOPro.exe" -c -h 127.0.0.1 -p 7911 -n HostA -d %DECK% -k

