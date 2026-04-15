mutable struct JLEngineCore
    config::EngineConfig
    master_blob::Dict{String, Any}
    master_config::Dict{String, Any}
    core_rules::Vector{String}
    mpf_profiles::Dict{String, MPFProfile}
    persona_state::Dict{String, Any}
    behavior_engine::BehaviorStateMachine
    emotional_aperture::EmotionalAperture
    signal_scorer::SignalScorer
    drift_system::DriftPressureSystem
    rhythm_engine::RhythmEngine
    memory_system::HybridMemorySystem
    state_manager::StateManager
    persona_manager::PersonaManager
    current_persona_name::String
    current_persona_data::Dict{String, Any}
    current_persona_file::Union{Nothing, String}
    current_gait::String
    current_rhythm_mode::String
    stability_score::Float64
end

function JLEngineCore(config::EngineConfig=EngineConfig())
    master_path = resolve_path(config.root_dir, config.master_file)
    master_blob = load_json_safely(master_path)
    master_config = load_engine_config(master_path)
    core_rules = [String(rule) for rule in get(master_config, "core_rules", Any[]) if rule isa AbstractString]
    mpf_profiles = load_mpf_registry(resolve_path(config.root_dir, config.mpf_registry_file))
    persona_state = Dict{String, Any}("emotion" => nothing, "emotion_meta" => nothing)

    engine = JLEngineCore(
        config,
        master_blob,
        master_config,
        core_rules,
        mpf_profiles,
        persona_state,
        BehaviorStateMachine(resolve_path(config.root_dir, config.behavior_states_file)),
        EmotionalAperture(persona_state=persona_state),
        SignalScorer(),
        DriftPressureSystem(),
        RhythmEngine(),
        HybridMemorySystem(),
        StateManager(),
        PersonaManager(config.root_dir, config.personas_dir),
        config.default_persona_name,
        Dict{String, Any}(),
        nothing,
        "walk",
        "flop",
        0.5,
    )
    set_persona!(engine, config.default_persona_name)
    return engine
end

function set_persona!(engine::JLEngineCore, persona_name::AbstractString)
    selected_name = haskey(engine.mpf_profiles, persona_name) ? String(persona_name) : engine.config.default_persona_name
    profile = get(engine.mpf_profiles, selected_name, nothing)
    profile === nothing && return false

    engine.current_persona_name = selected_name
    engine.current_persona_file = profile.persona_file
    engine.persona_state["emotion"] = nothing
    engine.persona_state["emotion_meta"] = nothing

    persona_path = resolve_path(engine.config.root_dir, joinpath(engine.config.personas_dir, profile.persona_file))
    engine.current_persona_data = isfile(persona_path) ? load_persona_file(persona_path) : Dict{String, Any}()
    set_persona_state!(engine.emotional_aperture, engine.persona_state)
    set_emotion_palette!(engine.emotional_aperture, get(engine.current_persona_data, "emotion_palette", Any[]))
    profile.drive_type !== nothing && set_drive_type!(engine.emotional_aperture, profile.drive_type)
    set_active_persona!(engine.persona_manager, selected_name, engine.current_persona_data, engine.mpf_profiles)

    # Apply the persona's default LLM backend
    if profile.default_backend_id !== nothing && !isempty(profile.default_backend_id)
        set_brain_backend_id!(String(profile.default_backend_id))
    end

    engine.current_gait = "walk"
    engine.current_rhythm_mode = "flop"
    engine.stability_score = 0.5
    return true
end

function analyze_turn!(engine::JLEngineCore, user_message::AbstractString; image=nothing, mime=nothing, persona_name=nothing, safety_on::Bool=engine.config.safety_on)
    persona_name !== nothing && set_persona!(engine, String(persona_name))

    signals = score(engine.signal_scorer, user_message)
    # If image is present, boost arousal or adjust signals if needed
    if image !== nothing
        # Vision-based signal adjustment could go here. For now, just boost arousal.
        # signals.arousal = min(1.0, signals.arousal + 0.1)
    end
    trigger = _derive_trigger(signals)
    engine.current_gait = _infer_gait(signals)

    drift_input = DriftPressureInput(
        persona_alignment_score=1.0 - min(0.25, signals.confusion * 0.2),
        behavior_grid_alignment_score=1.0 - min(0.35, signals.arousal * 0.15),
        safety_alignment_score=safety_on ? 1.0 : 0.9,
        memory_alignment_score=1.0 - min(0.40, signals.memory_density * 0.25),
        conversational_coherence_score=1.0 - min(0.60, signals.confusion * 0.8),
    )
    pressure = calculate(engine.drift_system, drift_input)
    drift_response = get_response_action(engine.drift_system, pressure)
    advisory = advisory_payload(engine.state_manager, engine.stability_score, pressure)
    gating_advice = advisory["gating_bias"] > 0 ? Dict{String, Any}("level" => "weak_block", "weight" => advisory["gating_bias"]) : Dict{String, Any}("level" => "allow", "weight" => 0.0)
    behavior_state = transition_by_trigger!(engine.behavior_engine, trigger, engine.current_gait; gating_advice=gating_advice)

    rhythm_state = compute(
        engine.rhythm_engine;
        last_mode=engine.current_rhythm_mode,
        trigger=trigger,
        gait=engine.current_gait,
        behavior_state=behavior_state,
        drift_pressure=pressure,
        safety_on=safety_on,
        modulation_hint=advisory,
    )
    engine.current_rhythm_mode = rhythm_state.mode

    inject_drift_bias!(engine.emotional_aperture, advisory["emotional_drift"])
    aperture_state = update_from_signals!(
        engine.emotional_aperture;
        behavior_state=behavior_state,
        gait=engine.current_gait,
        rhythm=rhythm_state.mode,
        persona_vividness=0.6,
        safety_mode=safety_on,
        drift_pressure=pressure,
        user_sentiment=signals.sentiment,
        conversation_pacing=signals.pace,
        memory_density=signals.memory_density,
    )
    update_dynamic_weight!(engine.persona_manager, signals; rhythm_state=_rhythm_state_dict(rhythm_state), aperture_state=aperture_state)
    persona_projection = get_projection(engine.persona_manager)

    return Dict{String, Any}(
        "persona" => engine.current_persona_name,
        "persona_file" => engine.current_persona_file,
        "persona_projection" => persona_projection,
        "trigger" => trigger,
        "gait" => engine.current_gait,
        "signals" => _signals_dict(signals),
        "behavior_state" => _behavior_state_dict(behavior_state),
        "behavior_blend" => current_blend(engine.behavior_engine),
        "rhythm" => _rhythm_state_dict(rhythm_state),
        "drift" => _drift_response_dict(drift_response),
        "aperture_state" => aperture_state,
        "advisory" => advisory,
        "core_rules" => engine.core_rules,
        "memory_context" => get_context(engine.memory_system, engine.current_persona_name),
        "has_image" => image !== nothing,
    )
end

function record_turn!(engine::JLEngineCore, user_message::AbstractString, output::AbstractString; snapshot=nothing)
    engine_state = snapshot isa AbstractDict ? get(snapshot, "engine_state", nothing) : nothing
    if !(engine_state isa AbstractDict)
        engine_state = Dict{String, Any}(
            "gait" => engine.current_gait,
            "rhythm" => engine.current_rhythm_mode,
            "aperture_mode" => get(engine.emotional_aperture.last_state, "mode", nothing),
            "dynamic" => export_snapshot(engine.state_manager),
            "flags" => Dict{String, Any}(),
        )
    end
    # Note: image content is currently not saved in SQLite memory to save space, 
    # but we could add image hashes or small thumbnails if needed.
    update_after_turn!(engine.memory_system, engine.current_persona_name, user_message, output, engine_state)
    rhythm_snapshot = snapshot isa AbstractDict ? get(snapshot, "rhythm", nothing) : nothing
    drift_snapshot = snapshot isa AbstractDict ? get(snapshot, "drift", Dict{String, Any}()) : Dict{String, Any}()
    update_from_output!(engine.state_manager, output; rhythm_state=rhythm_snapshot, gait=engine.current_gait)
    apply_output_feedback!(engine.emotional_aperture, output; rhythm_state=rhythm_snapshot, gait=engine.current_gait)
    engine.stability_score = clamp(0.55 - get(drift_snapshot, "pressure", 0.0) * 0.25 + export_snapshot(engine.state_manager)["last_sentiment"] * 0.05, 0.1, 0.95)
    return get_context(engine.memory_system, engine.current_persona_name)
end

get_llm_boot_prompt(engine::JLEngineCore, target::AbstractString="generic_llm") = get_llm_boot_prompt(engine.current_persona_data, target)

function run_turn!(engine::JLEngineCore, user_message::AbstractString; image=nothing, mime=nothing, persona_name=nothing, backend_id=nothing, backend_overrides=nothing)
    snapshot = analyze_turn!(engine, user_message; image=image, mime=mime, persona_name=persona_name)
    messages = _build_messages(engine, user_message, snapshot; image=image, mime=mime)
    options = Dict{String, Any}(
        "temperature" => clamp(get(snapshot["aperture_state"], "temp", 0.45) + get(snapshot["drift"], "temperature_delta", 0.0), 0.1, 1.5),
        "top_p" => clamp(get(snapshot["aperture_state"], "top_p", 0.7), 0.1, 1.0),
    )
    backend = backend_id === nothing ? get_brain_backend() : get_backend(String(backend_id); overrides=backend_overrides)
    reply, backend_meta = generate(backend, messages; options=options)
    context = record_turn!(engine, user_message, reply; snapshot=snapshot)
    return Dict{String, Any}(
        "ok" => true,
        "reply" => reply,
        "telemetry" => merge(snapshot, Dict{String, Any}("backend_meta" => backend_meta, "messages" => messages)),
        "memory_context" => context,
    )
end

function process_turn(engine::JLEngineCore, user_message::AbstractString; kwargs...)
    return run_turn!(engine, user_message; kwargs...)
end

function _derive_trigger(signals::TurnSignals)
    signals.sentiment > 0.5 && signals.arousal > 0.5 && return "user_hyped"
    signals.sentiment < -0.3 && signals.arousal > 0.3 && return "user_frustrated"
    signals.confusion > 0.6 && return "user_confused"
    signals.sentiment < -0.4 && signals.arousal > 0.2 && return "user_distressed"
    signals.directive && return "user_directive"
    return "neutral"
end

function _infer_gait(signals::TurnSignals)
    signals.confusion > 0.7 && signals.sentiment < 0 && return "idle"
    signals.arousal >= 0.85 && return "sprint"
    signals.arousal >= 0.60 && return "trot"
    return "walk"
end

function _signals_dict(signals::TurnSignals)
    return Dict{String, Any}(
        "sentiment" => signals.sentiment,
        "arousal" => signals.arousal,
        "directive" => signals.directive,
        "confusion" => signals.confusion,
        "pace" => signals.pace,
        "memory_density" => signals.memory_density,
    )
end

function _behavior_state_dict(state::BehaviorState)
    return Dict{String, Any}(
        "id" => state.id,
        "name" => state.name,
        "expressiveness" => state.expressiveness,
        "pacing" => state.pacing,
        "tone_bias" => state.tone_bias,
        "memory_strictness" => state.memory_strictness,
    )
end

function _rhythm_state_dict(state::RhythmState)
    return Dict{String, Any}(
        "mode" => state.mode,
        "index" => state.index,
        "variability" => state.variability,
        "momentum" => state.momentum,
        "attractor" => state.attractor,
        "modifiers" => state.modifiers,
        "debug" => state.debug,
    )
end

function _drift_response_dict(response::DriftResponse)
    return Dict{String, Any}(
        "pressure" => response.pressure,
        "action_level" => response.action_level,
        "temperature_delta" => response.temperature_delta,
        "force_gait" => response.force_gait,
        "force_rhythm" => response.force_rhythm,
        "supervisor_warning" => response.supervisor_warning,
        "reinforce_gait" => response.reinforce_gait,
    )
end

function _build_messages(engine::JLEngineCore, user_text::AbstractString, snapshot::AbstractDict; image=nothing, mime=nothing)
    projection = get(snapshot, "persona_projection", engine.current_persona_data)
    lines = String[]
    !isempty(engine.core_rules) && begin
        push!(lines, "CORE RULES:")
        append!(lines, ["- $(rule)" for rule in engine.core_rules])
    end
    push!(lines, "")
    push!(lines, "ACTIVE PERSONA: $(get(projection, "name", engine.current_persona_name))")
    base_prompt = get(projection, "base_prompt", "")
    base_prompt isa AbstractString && !isempty(base_prompt) && push!(lines, String(base_prompt))
    push!(lines, "")
    push!(lines, "ENGINE STATE SNAPSHOT:")
    push!(lines, "- Gait: $(get(snapshot, "gait", engine.current_gait))")
    push!(lines, "- Rhythm mode: $(get(get(snapshot, "rhythm", Dict{String, Any}()), "mode", engine.current_rhythm_mode))")
    push!(lines, "- Aperture mode: $(get(get(snapshot, "aperture_state", Dict{String, Any}()), "mode", "GUARDED"))")
    push!(lines, "- Drift pressure: $(round(get(get(snapshot, "drift", Dict{String, Any}()), "pressure", 0.0); digits=3))")
    push!(lines, "- Stability score: $(round(engine.stability_score; digits=3))")

    # Inject modular profile directives if loadout was resolved
    tone_cfg = get(projection, "tone_config", nothing)
    if tone_cfg isa AbstractDict && !isempty(tone_cfg)
        push!(lines, "")
        push!(lines, "TONE: warmth=$(get(tone_cfg, "warmth", 0.5)), sass=$(get(tone_cfg, "sass_level", 0.0)), directness=$(get(tone_cfg, "directness", 0.5)), verbosity=$(get(tone_cfg, "verbosity_bias", "medium"))")
    end
    behavior_cfg = get(projection, "behavior_config", nothing)
    if behavior_cfg isa AbstractDict && !isempty(behavior_cfg)
        mode = get(behavior_cfg, "mode", "")
        steps = get(behavior_cfg, "steps", Any[])
        !isempty(mode) && push!(lines, "BEHAVIOR MODE: $(mode) — steps: $(join(steps, " → "))")
    end
    gates_cfg = get(projection, "gates_config", nothing)
    if gates_cfg isa AbstractDict && !isempty(gates_cfg)
        push!(lines, "GATES: safety=$(get(gates_cfg, "safety_strictness", "medium")), clarity_check=$(get(gates_cfg, "clarity_check", true)), style_refine=$(get(gates_cfg, "style_refine", true))")
    end
    tasks_cfg = get(projection, "tasks_config", nothing)
    if tasks_cfg isa AbstractDict
        supported = get(tasks_cfg, "supported_tasks", Any[])
        !isempty(supported) && push!(lines, "SUPPORTED TASKS: $(join(supported, ", "))")
    end

    history = Any[]
    memory_context = get(snapshot, "memory_context", Dict{String, Any}())
    persona_memory = get(memory_context, "persona_memory", Dict{String, Any}())
    recent = get(persona_memory, "recent_interactions", Any[])
    if recent isa AbstractVector
        for interaction in recent[max(1, length(recent)-2):end]
            interaction isa AbstractDict || continue
            push!(history, Dict{String, Any}("role" => "user", "content" => get(interaction, "user_message", "")))
            push!(history, Dict{String, Any}("role" => "assistant", "content" => get(interaction, "output", "")))
        end
    end

    messages = Any[Dict{String, Any}("role" => "system", "content" => join(lines, "\n"))]
    append!(messages, history)
    
    # Build multimodal user message if image is present
    user_content = if image !== nothing
        Any[
            Dict{String, Any}("type" => "text", "text" => user_text),
            Dict{String, Any}("type" => "image", "image" => image, "mime" => something(mime, "image/png"))
        ]
    else
        user_text
    end
    
    push!(messages, Dict{String, Any}("role" => "user", "content" => user_content))
    return messages
end
