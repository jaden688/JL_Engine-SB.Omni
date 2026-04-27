module JLEngine

haskey(ENV, "JULIA_CONDAPKG_BACKEND") || (ENV["JULIA_CONDAPKG_BACKEND"] = "Null")
haskey(ENV, "JULIA_PYTHONCALL_EXE") || (ENV["JULIA_PYTHONCALL_EXE"] = "python")

include("JLEngine/Types.jl")
include("JLEngine/Config.jl")
include("JLEngine/MPF.jl")
include("JLEngine/Signals.jl")
include("JLEngine/Behavior.jl")
include("JLEngine/Rhythm.jl")
include("JLEngine/Drift.jl")
include("JLEngine/Memory.jl")
include("JLEngine/Aperture.jl")
include("JLEngine/State.jl")
include("JLEngine/OperatorManager.jl")
include("JLEngine/Backends.jl")
include("JLEngine/Core.jl")
include("App.jl")

const TOOL_MAP = BYTE.TOOL_MAP
const TOOLS_SCHEMA = BYTE.TOOLS_SCHEMA
const tool_reddit_submit = BYTE.tool_reddit_submit

export EngineConfig,
    GearModifiers,
    MPFProfile,
    BehaviorState,
    BehaviorStateMachine,
    TurnSignals,
    SignalScorer,
    RhythmState,
    RhythmEngine,
    DriftPressureInput,
    DriftPressureSystem,
    DriftResponse,
    HybridMemorySystem,
    EmotionalAperture,
    ModulationState,
    StateManager,
    OperatorManager,
    AbstractBackend,
    NoopBackend,
    OllamaBackend,
    GoogleGeminiBackend,
    CustomHTTPBackend,
    JLEngineCore,
    gear_modifiers,
    load_json_safely,
    resolve_path,
    load_engine_config,
    load_mpf_registry,
    load_operator_file,
    get_llm_boot_prompt,
    score,
    current_state,
    current_blend,
    set_state_by_coords!,
    set_state_by_label!,
    transition_by_trigger!,
    compute,
    calculate,
    get_response_action,
    get_context,
    note_event!,
    add_breadcrumb!,
    get_breadcrumbs,
    get_intent_context,
    update_after_turn!,
    set_drive_type!,
    set_emotion_palette!,
    set_agent_state!,
    reset!,
    get_state,
    update_from_signals!,
    update_from_signal!,
    apply_output_feedback!,
    inject_drift_bias!,
    get_focus_level,
    get_overload_level,
    advisory_payload,
    export_snapshot,
    update_from_output!,
    set_active_operator!,
    apply_supervisor_bias!,
    update_dynamic_weight!,
    get_projection,
    get_backend,
    get_brain_backend,
    get_tool_backend,
    set_backend_model!,
    configure_backends!,
    set_brain_backend_id!,
    set_tool_backend_id!,
    sync_from_byte!,
    generate,
    set_operator!,
    analyze_turn!,
    record_turn!,
    run_turn!,
    process_turn,
    app_main,
    julia_main,
    runtime_root,
    state_root,
    TOOL_MAP,
    TOOLS_SCHEMA,
    tool_reddit_submit

end
