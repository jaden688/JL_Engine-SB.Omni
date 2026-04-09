ENV["JULIA_CONDAPKG_BACKEND"] = "Null"
ENV["JULIA_PYTHONCALL_EXE"] = "python"

import Pkg

function _env_true(name::AbstractString; default::Bool=false)
    value = lowercase(strip(get(ENV, name, default ? "1" : "0")))
    return !(value in ("", "0", "false", "no", "off"))
end

Pkg.activate(@__DIR__)
if !_env_true("SPARKBYTE_SKIP_PKG_INSTANTIATE")
    Pkg.instantiate()
end

include(joinpath(@__DIR__, "health_check.jl"))
run_health_check()

using JLEngine

JLEngine.app_main()
