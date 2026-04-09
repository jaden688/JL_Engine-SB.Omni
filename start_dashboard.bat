@echo off
rem Start Gremlin live dashboard on port 8080
julia --project="C:\Users\J_lin\Desktop\JL_Engine (3)\jl-vs\vscode-main\copilot-separate-leopard" -e "using JLEngine; JLEngine.BYTE.dispatch(\"live_dashboard\", Dict(\"port\"=>8080))"