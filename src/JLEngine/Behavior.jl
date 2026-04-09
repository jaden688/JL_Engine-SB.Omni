function _float_or(value, default::Float64)
    value isa Real && return Float64(value)
    try
        return parse(Float64, string(value))
    catch
        return default
    end
end

function _int_or(value, default::Int)
    value isa Integer && return Int(value)
    try
        return parse(Int, string(value))
    catch
        return default
    end
end

function _behavior_state_from_dict(data)
    data isa AbstractDict || return BehaviorState()
    return BehaviorState(
        id=String(get(data, "id", "0,0")),
        name=String(get(data, "name", "Unknown")),
        expressiveness=_float_or(get(data, "expressiveness", 0.5), 0.5),
        pacing=String(get(data, "pacing", "normal")),
        tone_bias=String(get(data, "tone_bias", "neutral")),
        memory_strictness=String(get(data, "memory_strictness", "medium")),
    )
end

mutable struct BehaviorStateMachine
    states::Vector{Vector{BehaviorState}}
    trigger_mappings::Dict{String, Tuple{Int, Int}}
    rows::Int
    columns::Int
    current_row::Int
    current_col::Int
    gating_advice::Dict{String, Any}
    blend_weight::Float64
    last_blend::Union{Nothing, Dict{String, Any}}
end

function BehaviorStateMachine(config_path::AbstractString)
    config = load_json_safely(config_path)
    raw_rows = get(config, "states", Any[])
    states = Vector{Vector{BehaviorState}}()

    if raw_rows isa AbstractVector
        for row in raw_rows
            row isa AbstractVector || continue
            push!(states, [_behavior_state_from_dict(item) for item in row])
        end
    end

    if isempty(states)
        states = [[BehaviorState() for _ in 1:4] for _ in 1:5]
    end

    trigger_mappings = Dict{String, Tuple{Int, Int}}()
    raw_mappings = get(config, "trigger_mappings", Dict{String, Any}())
    if raw_mappings isa AbstractDict
        for (trigger, coords) in raw_mappings
            coords isa AbstractVector || continue
            length(coords) >= 2 || continue
            trigger_mappings[String(trigger)] = (_int_or(coords[1], 2), _int_or(coords[2], 1))
        end
    end

    dims = get(config, "grid_dimensions", Dict{String, Any}())
    rows = dims isa AbstractDict ? _int_or(get(dims, "rows", length(states)), length(states)) : length(states)
    cols = dims isa AbstractDict ? _int_or(get(dims, "columns", length(first(states))), length(first(states))) : length(first(states))

    machine = BehaviorStateMachine(
        states,
        trigger_mappings,
        rows,
        cols,
        2,
        0,
        Dict{String, Any}("level" => "allow", "weight" => 0.0, "reason" => nothing),
        0.0,
        nothing,
    )
    _compute_blend!(machine)
    return machine
end

current_state(machine::BehaviorStateMachine) = machine.states[machine.current_row + 1][machine.current_col + 1]
current_blend(machine::BehaviorStateMachine) = machine.last_blend

function set_state_by_coords!(machine::BehaviorStateMachine, row::Integer, col::Integer)
    machine.current_row = clamp(Int(row), 0, machine.rows - 1)
    machine.current_col = clamp(Int(col), 0, machine.columns - 1)
    _compute_blend!(machine)
    return current_state(machine)
end

function set_state_by_label!(machine::BehaviorStateMachine, label::AbstractString)
    target = lowercase(strip(label))
    isempty(target) && return false

    for (r, row) in enumerate(machine.states)
        for (c, state) in enumerate(row)
            if lowercase(state.name) == target || lowercase(state.id) == target
                set_state_by_coords!(machine, r - 1, c - 1)
                return true
            end
        end
    end
    return false
end

function transition_by_trigger!(machine::BehaviorStateMachine, trigger::Union{Nothing, AbstractString}, gait::AbstractString; gating_advice=nothing)
    advice = _normalize_advice(gating_advice === nothing ? machine.gating_advice : gating_advice)
    if get(advice, "level", "allow") == "weak_block"
        machine.gating_advice = advice
    else
        machine.gating_advice = Dict{String, Any}("level" => "allow", "weight" => 0.0, "reason" => get(advice, "reason", nothing))
    end

    if trigger !== nothing && haskey(machine.trigger_mappings, String(trigger))
        target_row, target_col = machine.trigger_mappings[String(trigger)]
        gait_lower = lowercase(strip(gait))

        if gait_lower in ("trot", "gallop")
            target_row = min(machine.rows - 1, target_row + 1)
        elseif gait_lower == "sprint"
            target_row = min(machine.rows - 1, target_row + 2)
        elseif gait_lower == "idle"
            target_row = max(0, target_row - 1)
        end

        if get(advice, "level", "allow") == "weak_block"
            pull = _float_or(get(advice, "weight", 0.3), 0.3)
            target_row = round(Int, target_row * (1 - pull) + 2 * pull)
        end

        if Bool(get(advice, "safety", false))
            target_row = 1
            target_col = 0
        end

        set_state_by_coords!(machine, target_row, target_col)
    else
        set_state_by_coords!(machine, 2, 1)
    end

    machine.blend_weight = _float_or(get(advice, "weight", 0.0), 0.0)
    _compute_blend!(machine)
    return current_state(machine)
end

function _normalize_advice(advice)
    advice isa AbstractDict || return Dict{String, Any}("level" => "allow", "weight" => 0.0, "safety" => false, "reason" => nothing)

    level = lowercase(String(get(advice, "level", "allow")))
    level == "block" && (level = "weak_block")
    safety = level == "safety_block" || Bool(get(advice, "safety", false))
    weight = clamp(_float_or(get(advice, "weight", 0.0), 0.0), 0.0, 1.0)

    return Dict{String, Any}(
        "level" => level,
        "weight" => weight,
        "safety" => safety,
        "reason" => get(advice, "reason", nothing),
    )
end

function _state_summary(state::BehaviorState)
    return Dict{String, Any}("id" => state.id, "name" => state.name)
end

function _compute_blend!(machine::BehaviorStateMachine)
    primary = current_state(machine)
    stabilizer = machine.states[3][2]
    weight = clamp(machine.blend_weight, 0.0, 1.0)

    if weight <= 0.05 || (primary.id == stabilizer.id && primary.name == stabilizer.name)
        machine.last_blend = Dict{String, Any}(
            "primary" => _state_summary(primary),
            "secondary" => nothing,
            "weights" => (1.0, 0.0),
        )
        return machine.last_blend
    end

    secondary = machine.current_col > 0 ? machine.states[machine.current_row + 1][machine.current_col] : stabilizer
    machine.last_blend = Dict{String, Any}(
        "primary" => _state_summary(primary),
        "secondary" => _state_summary(secondary),
        "weights" => (round(1.0 - weight; digits=2), round(weight; digits=2)),
    )
    return machine.last_blend
end
