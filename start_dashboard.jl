if !haskey(ENV, "SPARKBYTE_PORT")
    ENV["SPARKBYTE_PORT"] = "8081"
end

if !haskey(ENV, "SPARKBYTE_HOST")
    ENV["SPARKBYTE_HOST"] = "127.0.0.1"
end

println("start_dashboard.jl is deprecated. Launching SparkByte UI on http://$(ENV["SPARKBYTE_HOST"]):$(ENV["SPARKBYTE_PORT"])")
include(joinpath(@__DIR__, "sparkbyte.jl"))
