const DEFAULT_GEAR = "spur"

struct GearModifiers
    reaction_speed::Float64
    mode_inertia::Float64
    multi_mode::Bool
end

function gear_modifiers(gear::AbstractString=DEFAULT_GEAR)
    key = isempty(gear) ? DEFAULT_GEAR : lowercase(gear)
    if key == "worm"
        return GearModifiers(0.6, 0.78, false)
    elseif key == "cvt"
        return GearModifiers(0.9, 0.55, true)
    elseif key == "planetary"
        return GearModifiers(1.0, 0.5, true)
    end
    return GearModifiers(0.8, 0.65, false)
end

Base.@kwdef struct EngineConfig
    root_dir::String = pwd()
    master_file::String = "JLframe_Engine_Framework.json"
    behavior_states_file::String = "behavior_states.json"
    mpf_registry_file::String = joinpath("agents", "Agents.mpf.json")
    agents_dir::String = "agents"
    safety_on::Bool = true
    default_agent_name::String = "SparkByte"
    history_length::Int = 20
end

Base.@kwdef struct MPFProfile
    agent_file::String
    default_memory_mode::Union{Nothing, String} = nothing
    default_backend_id::Union{Nothing, String} = nothing
    drive_type::Union{Nothing, String} = nothing
    tags::Vector{String} = String[]
end

Base.@kwdef struct BehaviorState
    id::String = "0,0"
    name::String = "Unknown"
    expressiveness::Float64 = 0.5
    pacing::String = "normal"
    tone_bias::String = "neutral"
    memory_strictness::String = "medium"
end

Base.string(state::BehaviorState) = "[$(state.id)] $(state.name)"

function instructions(state::BehaviorState)
    return join(
        [
            "Current Behavior State: $(state.name) ($(state.id)).",
            "- Expressiveness Level: $(round(state.expressiveness * 100; digits=1))%",
            "- Conversational Pacing: $(state.pacing)",
            "- Dominant Tone: $(state.tone_bias)",
            "- Adherence to Memory: $(state.memory_strictness)",
        ],
        "\n",
    )
end

struct TurnSignals
    sentiment::Float64
    arousal::Float64
    directive::Bool
    confusion::Float64
    pace::Float64
    memory_density::Float64
end

struct RhythmState
    mode::String
    index::Float64
    variability::Float64
    momentum::Float64
    attractor::String
    modifiers::Dict{String, Float64}
    debug::Dict{String, Any}
end

Base.@kwdef struct DriftPressureInput
    agent_alignment_score::Float64 = 1.0
    behavior_grid_alignment_score::Float64 = 1.0
    safety_alignment_score::Float64 = 1.0
    memory_alignment_score::Float64 = 1.0
    conversational_coherence_score::Float64 = 1.0
end

struct DriftResponse
    pressure::Float64
    action_level::String
    temperature_delta::Float64
    force_gait::Union{Nothing, String}
    force_rhythm::Union{Nothing, String}
    supervisor_warning::Union{Nothing, String}
    reinforce_gait::Bool
end
