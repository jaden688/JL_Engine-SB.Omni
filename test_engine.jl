push!(LOAD_PATH, "src")
using JLEngine

config = EngineConfig(
    root_dir = "data",
    master_file = "JLframe_Engine_Framework.json",
    behavior_states_file = "behavior_states.json",
    mpf_registry_file = "personas/Personas.mpf.json",
    personas_dir = "personas",
    default_persona_name = "SparkByte"
)

engine = JLEngineCore(config)
snapshot = analyze_turn!(engine, "Hello there SparkByte!")
println(snapshot["aperture_state"])
println(snapshot["rhythm"])
println(snapshot["drift"])
