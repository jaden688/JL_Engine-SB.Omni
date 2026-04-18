ENV["JULIA_CONDAPKG_BACKEND"] = "Null"
ENV["JULIA_PYTHONCALL_EXE"] = "python"

import Pkg

function _env_true(name::AbstractString; default::Bool=false)
    value = lowercase(strip(get(ENV, name, default ? "1" : "0")))
    return !(value in ("", "0", "false", "no", "off"))
end

function _active_project_path()
    active = try
        Base.active_project()
    catch
        nothing
    end
    active === nothing && return ""
    return abspath(String(active))
end

function _ensure_project_setup!()
    project_toml = abspath(joinpath(@__DIR__, "Project.toml"))
    if _active_project_path() != project_toml && !_env_true("SPARKBYTE_SKIP_PKG_SETUP")
        Pkg.activate(@__DIR__)
        if !_env_true("SPARKBYTE_SKIP_PKG_INSTANTIATE")
            Pkg.instantiate()
        end
    end
end

_ensure_project_setup!()

include(joinpath(@__DIR__, "health_check.jl"))
run_health_check()

using JLEngine

JLEngine.app_main()
