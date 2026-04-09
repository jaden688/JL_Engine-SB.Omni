mutable struct PersonaManager
    root_dir::String
    personas_dir::String
    active_name::Union{Nothing, String}
    base_data::Dict{String, Any}
    secondary_data::Union{Nothing, Dict{String, Any}}
    dynamic_trait_weight::Float64
end

PersonaManager(root_dir::AbstractString=pwd(), personas_dir::AbstractString="personas") = PersonaManager(String(root_dir), String(personas_dir), nothing, Dict{String, Any}(), nothing, 0.5)

function set_active_persona!(manager::PersonaManager, name::AbstractString, data::AbstractDict, registry::Union{Nothing, Dict{String, MPFProfile}}=nothing)
    manager.active_name = String(name)
    manager.base_data = Dict{String, Any}(string(key) => value for (key, value) in pairs(data))
    manager.secondary_data = registry === nothing ? nothing : _find_related_persona(manager, String(name), registry)
    manager.dynamic_trait_weight = 0.5
    return manager
end

function _find_related_persona(manager::PersonaManager, name::String, registry::Dict{String, MPFProfile})
    base_tags = Set{String}()
    raw_tags = get(manager.base_data, "tags", get(get(manager.base_data, "identity", Dict{String, Any}()), "tags", Any[]))
    if raw_tags isa AbstractVector
        for tag in raw_tags
            tag isa AbstractString && push!(base_tags, String(tag))
        end
    end

    isempty(base_tags) && return

    for (display_name, profile) in registry
        display_name == name && continue
        tags = Set(profile.tags)
        isempty(intersect(base_tags, tags)) && continue
        persona_path = resolve_path(manager.root_dir, joinpath(manager.personas_dir, profile.persona_file))
        isfile(persona_path) || continue
        candidate = load_persona_file(persona_path)
        candidate isa AbstractDict && return Dict{String, Any}(string(key) => value for (key, value) in pairs(candidate))
    end
    return
end

function apply_supervisor_bias!(manager::PersonaManager, bias::Real)
    manager.dynamic_trait_weight = clamp(manager.dynamic_trait_weight + Float64(bias) * 0.25, 0.0, 1.0)
    return manager
end

function update_dynamic_weight!(manager::PersonaManager, signals=nothing; rhythm_state=nothing, aperture_state=nothing)
    sentiment = signals isa TurnSignals ? signals.sentiment : 0.0
    variability = rhythm_state isa AbstractDict ? _float_or(get(rhythm_state, "variability", 0.0), 0.0) : rhythm_state isa RhythmState ? rhythm_state.variability : 0.0
    aperture_score = aperture_state isa AbstractDict ? _float_or(get(aperture_state, "score", 0.0), 0.0) : 0.0
    delta = sentiment * 0.15 + variability * 0.1 + (aperture_score - 0.5) * 0.2
    manager.dynamic_trait_weight = clamp(manager.dynamic_trait_weight * 0.9 + delta, 0.0, 1.0)
    return manager
end

function _merge_trait_list(base_traits, secondary_traits, key::AbstractString)
    merged = String[]
    seen = Set{String}()
    for source in (base_traits, secondary_traits)
        values = source isa AbstractDict ? get(source, key, Any[]) : Any[]
        values isa AbstractVector || continue
        for item in values
            item isa AbstractString || continue
            text = String(item)
            in(text, seen) && continue
            push!(seen, text)
            push!(merged, text)
        end
    end
    return merged
end

function get_projection(manager::PersonaManager)
    persona = deepcopy(manager.base_data)
    persona["dynamic_trait_weight"] = round(manager.dynamic_trait_weight; digits=3)
    if manager.secondary_data !== nothing && manager.dynamic_trait_weight > 0.05
        base_traits = get(manager.base_data, "operational_behavioral_traits", Dict{String, Any}())
        secondary_traits = get(manager.secondary_data, "operational_behavioral_traits", Dict{String, Any}())
        persona["operational_behavioral_traits"] = Dict{String, Any}(
            "positive" => _merge_trait_list(base_traits, secondary_traits, "positive"),
            "negative" => _merge_trait_list(base_traits, secondary_traits, "negative"),
            "boundaries" => _merge_trait_list(base_traits, secondary_traits, "boundaries"),
            "dynamic_weight" => round(manager.dynamic_trait_weight; digits=3),
        )
    end
    return persona
end
