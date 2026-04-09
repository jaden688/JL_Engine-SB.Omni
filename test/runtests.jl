using Test
using JLEngine

const FIXTURES = joinpath(@__DIR__, "fixtures")

@testset "JLEngine" begin
    registry_path = joinpath(FIXTURES, "personas", "Personas.mpf.json")
    persona_path = joinpath(FIXTURES, "personas", "SparkByte_Full.json")
    behavior_path = joinpath(FIXTURES, "behavior_states.json")

    @testset "Config and MPF" begin
        config = load_json_safely(joinpath(FIXTURES, "JLframe_Engine_Framework.json"))
        @test get(config, "jl_engine", Dict())["backends"]["default"] == "ollama-local"

        profiles = load_mpf_registry(registry_path)
        @test haskey(profiles, "SparkByte")
        @test profiles["SparkByte"].persona_file == "SparkByte_Full.json"

        persona = load_persona_file(persona_path)
        @test get_llm_boot_prompt(persona) == "You are SparkByte."
    end

    @testset "Signals" begin
        signals = score(SignalScorer(), "Just give me the answer, be concise.")
        @test signals.directive
        @test signals.pace > 0
    end

    @testset "Behavior" begin
        machine = BehaviorStateMachine(behavior_path)
        state = transition_by_trigger!(machine, "user_hyped", "trot")
        @test state.name == "Unleashed-Chaotic"
        @test current_blend(machine) !== nothing
    end

    @testset "Rhythm" begin
        engine = RhythmEngine()
        state = compute(engine; last_mode="trot", trigger="user_distressed", gait="trot", drift_pressure=0.1, safety_on=true)
        @test state.mode == "flop"
    end

    @testset "Drift" begin
        system = DriftPressureSystem()
        pressure = calculate(system, DriftPressureInput(
            persona_alignment_score=0.5,
            behavior_grid_alignment_score=0.5,
            safety_alignment_score=0.5,
            memory_alignment_score=0.5,
            conversational_coherence_score=0.5,
        ))
        response = get_response_action(system, pressure)
        @test pressure ≈ 0.5
        @test response.action_level == "Moderate Drift"
    end

    @testset "Aperture" begin
        persona = load_persona_file(persona_path)
        machine = BehaviorStateMachine(behavior_path)
        state = transition_by_trigger!(machine, "user_hyped", "walk")
        persona_state = Dict{String, Any}()
        aperture = EmotionalAperture(persona_state=persona_state)
        set_emotion_palette!(aperture, persona["emotion_palette"])
        result = update_from_signals!(
            aperture;
            behavior_state=state,
            gait="trot",
            rhythm="trot",
            persona_vividness=0.6,
            safety_mode=true,
            drift_pressure=0.1,
            user_sentiment=0.4,
            conversation_pacing=0.7,
            memory_density=0.2,
        )
        @test result["mode"] in ("BALANCED", "OPEN")
        @test result["emotion"] !== nothing
        @test get(persona_state, "emotion", nothing) !== nothing
    end

    @testset "Memory" begin
        memory = HybridMemorySystem()
        update_after_turn!(
            memory,
            "SparkByte",
            "hello",
            "hi",
            Dict{String, Any}(
                "gait" => "walk",
                "rhythm" => "flip",
                "aperture_mode" => "BALANCED",
                "dynamic" => Dict{String, Any}(),
                "flags" => Dict{String, Any}("stressed" => false),
            ),
        )
        context = get_context(memory, "SparkByte")
        @test length(context["persona_memory"]["recent_interactions"]) == 1
        @test context["shared_memory"]["last_active_persona"] == "SparkByte"
    end

    @testset "State Manager" begin
        manager = StateManager()
        update_from_output!(manager, "Great, nice, awesome!"; rhythm_state=Dict("variability" => 0.5), gait="trot")
        advisory = advisory_payload(manager, 0.35, 0.5)
        @test advisory["gating_bias"] >= 0.3
        @test export_snapshot(manager)["turn_count"] == 1
    end

    @testset "Persona Manager" begin
        profiles = load_mpf_registry(registry_path)
        spark = load_persona_file(persona_path)
        manager = PersonaManager(FIXTURES, "personas")
        set_active_persona!(manager, "SparkByte", spark, profiles)
        update_dynamic_weight!(manager, TurnSignals(0.4, 0.7, false, 0.1, 0.6, 0.2); rhythm_state=Dict("variability" => 0.5), aperture_state=Dict("score" => 0.7))
        projection = get_projection(manager)
        @test haskey(projection, "dynamic_trait_weight")
        @test haskey(projection, "operational_behavioral_traits")
    end

    @testset "Backends" begin
        configure_backends!(brain_id="noop-stub", tool_id="noop-stub")
        backend = get_brain_backend()
        reply, meta = generate(backend, [Dict("role" => "user", "content" => "hello world")]; options=Dict("temperature" => 0.4))
        @test reply == "hello world"
        @test meta["provider"] == "noop"
    end

    @testset "Core" begin
        core = JLEngineCore(EngineConfig(root_dir=FIXTURES))
        snapshot = analyze_turn!(core, "Please be concise and help me debug this.")
        @test snapshot["persona"] == "SparkByte"
        @test haskey(snapshot, "aperture_state")
        record_turn!(core, "Please be concise and help me debug this.", "Sure, let's debug it.")
        context = get_context(core.memory_system, "SparkByte")
        @test length(context["persona_memory"]["recent_interactions"]) == 1
        configure_backends!(brain_id="noop-stub")
        turn = run_turn!(core, "Say hello in one line.")
        @test turn["ok"] == true
        @test turn["reply"] == "Say hello in one line."
    end
end
