@echo off
set YGO_CONTROL_PORT=7789
cd /d "D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game"
start "" "D:\dsh_workspaces\MC_bot_dsh\mycard-client\bin\release\x64\YGOPro.exe" -h tiramisu.moenext.com -p 7911  -j -d Blackwing -k
