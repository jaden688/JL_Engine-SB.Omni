@echo off
setlocal

if not defined SPARKBYTE_PORT set SPARKBYTE_PORT=8081
if not defined SPARKBYTE_HOST set SPARKBYTE_HOST=127.0.0.1

echo start_dashboard.bat is deprecated. Launching SparkByte UI on http://%SPARKBYTE_HOST%:%SPARKBYTE_PORT%
julia --project="C:\Users\J_lin\Desktop\JL_Engine (3)\jl-vs\vscode-main\copilot-separate-leopard" sparkbyte.jl
