function load_mpf_registry(registry_path::AbstractString)
    raw_registry = load_json_safely(registry_path)
    profiles = Dict{String, MPFProfile}()

    for (display_name, entry) in raw_registry
        entry isa AbstractDict || continue
        agent_file = get(entry, "agent_file", nothing)
        agent_file isa AbstractString || continue
        tags = [String(tag) for tag in get(entry, "tags", Any[]) if tag isa AbstractString]
        profiles[String(display_name)] = MPFProfile(
            operator_file=String(persona_file),
            default_memory_mode=get(entry, "default_memory_mode", nothing),
            default_backend_id=get(entry, "default_backend_id", nothing),
            drive_type=get(entry, "drive_type", nothing),
            tags=tags,
        )
    end

    return profiles
end

function load_operator_file(path::AbstractString)
    data = load_json_safely(path)
    isempty(data) && return data

    # If agent has an active_loadout, resolve modular profiles
    loadout_id = get(data, "active_loadout", nothing)
    loadout_id isa AbstractString && !isempty(loadout_id) || return data

    # Find the modular_fat_agent_pack directory relative to the JL agent file
    agent_dir = dirname(path)
    pack_dir = joinpath(dirname(agent_dir), "modular_fat_agent_pack")
    !isdir(pack_dir) && return data

    # Load the loadout definition
    loadout_path = joinpath(pack_dir, "loadouts", "$(loadout_id).json")
    loadout = load_json_safely(loadout_path)
    isempty(loadout) && return data

    # Resolve each profile from the loadout
    resolved = Dict{String, Any}()
    profile_map = Dict(
        "tone_profile"     => "tone",
        "gate_profile"     => "gates",
        "tool_profile"     => "tools",
        "state_profile"    => "state",
        "behavior_profile" => "behavior",
        "task_profile"     => "tasks",
    )
    for (loadout_key, profile_subdir) in profile_map
        profile_name = get(loadout, loadout_key, nothing)
        profile_name isa AbstractString || continue
        profile_path = joinpath(pack_dir, "profiles", profile_subdir, "$(profile_name).json")
        profile_data = load_json_safely(profile_path)
        !isempty(profile_data) && (resolved[profile_subdir] = profile_data)
    end

    # Load any helpers referenced
    helpers_dir = joinpath(pack_dir, "helpers")
    if isdir(helpers_dir)
        helpers = Dict{String, Any}()
        for f in readdir(helpers_dir)
            endswith(f, ".json") || continue
            h = load_json_safely(joinpath(helpers_dir, f))
            hid = get(h, "helper_id", replace(f, ".json" => ""))
            helpers[String(hid)] = h
        end
        !isempty(helpers) && (resolved["helpers"] = helpers)
    end

    # Merge into agent data
    data["loadout"] = loadout
    data["loadout_id"] = loadout_id
    data["resolved_profiles"] = resolved

    # Flatten key profile values into top-level for engine consumption
    tone = get(resolved, "tone", Dict{String,Any}())
    data["tone_config"] = tone

    state = get(resolved, "state", Dict{String,Any}())
    data["state_config"] = state

    behavior = get(resolved, "behavior", Dict{String,Any}())
    data["behavior_config"] = behavior

    tools = get(resolved, "tools", Dict{String,Any}())
    data["tools_config"] = tools

    gates = get(resolved, "gates", Dict{String,Any}())
    data["gates_config"] = gates

    tasks = get(resolved, "tasks", Dict{String,Any}())
    data["tasks_config"] = tasks

    return data
end

function get_llm_boot_prompt(agent_config::AbstractDict, target::AbstractString="generic_llm")
    profiles = get(agent_config, "llm_profiles", nothing)
    base_prompt = ""

    if profiles isa AbstractDict
        profile = get(profiles, target, nothing)
        if profile isa AbstractDict
            prompt = get(profile, "boot_prompt", nothing)
            prompt isa AbstractString && (base_prompt = String(prompt))
        end

        if isempty(base_prompt)
            generic = get(profiles, "generic_llm", nothing)
            if generic isa AbstractDict
                prompt = get(generic, "boot_prompt", nothing)
                prompt isa AbstractString && (base_prompt = String(prompt))
            end
        end
    end
    
    # ── Inject Modular Agent Expressiveness (FULL FAT) ──────────────────────

    extra_context = String[]

    # 1. Identity — who SparkByte is
    identity = get(agent_config, "identity", Dict())
    if identity isa AbstractDict && !isempty(identity)
        block = "== IDENTITY ==\n"
        for key in ["name", "role", "archetype", "description"]
            v = get(identity, key, "")
            v isa AbstractString && !isempty(v) && (block *= uppercase(key) * ": " * v * "\n")
        end
        tags = get(identity, "tags", [])
        tags isa AbstractVector && !isempty(tags) && (block *= "TAGS: " * join([string(t) for t in tags], ", ") * "\n")
        push!(extra_context, strip(block))
    end

    # 2. Behavior & Directives (including edge_behavior)
    behavior = get(agent_config, "behavior_config", get(agent_config, "behavior", Dict()))
    if behavior isa AbstractDict && !isempty(behavior)
        block = "== BEHAVIOR & DIRECTIVES ==\n"
        for key in ["core_directives", "pillars", "avoidances"]
            vals = get(behavior, key, [])
            if vals isa AbstractVector && !isempty(vals)
                block *= uppercase(key) * ":\n"
                for v in vals
                    block *= " - " * string(v) * "\n"
                end
            end
        end
        edge = get(behavior, "edge_behavior", Dict())
        if edge isa AbstractDict && !isempty(edge)
            block *= "EDGE_BEHAVIOR:\n"
            for (k, v) in edge
                v isa AbstractString && (block *= " - " * string(k) * ": " * v * "\n")
            end
        end
        push!(extra_context, strip(block))
    end

    # 3. Cognitive modes — SASS_LAYER, HUMANIZED_EXPLANATION, etc.
    modes = get(agent_config, "cognitive_modes", Dict())
    if modes isa AbstractDict && !isempty(modes)
        block = "== COGNITIVE MODES (ACTIVE) ==\n"
        active = get(modes, "active_modes", [])
        active isa AbstractVector && !isempty(active) && (block *= "ACTIVE: " * join([string(m) for m in active], ", ") * "\n")
        mb = get(modes, "mode_behaviors", Dict())
        if mb isa AbstractDict
            for (k, v) in mb
                v isa AbstractString && (block *= " - " * string(k) * ": " * v * "\n")
            end
        end
        push!(extra_context, strip(block))
    end

    # 4. Gait, Rhythm, Tone — the voice layer
    tone = get(agent_config, "tone_config", Dict())
    gait = get(agent_config, "gait", Dict())
    rhythm = get(agent_config, "rhythm", Dict())

    if !isempty(tone) || !isempty(gait) || !isempty(rhythm)
        block = "== EXPRESSIVENESS & VOICE ==\n"
        for dict in (tone, gait, rhythm)
            if dict isa AbstractDict
                for (k, v) in dict
                    if v isa AbstractString
                        block *= uppercase(string(k)) * ": " * v * "\n"
                    elseif v isa AbstractVector
                        block *= uppercase(string(k)) * ": " * join([string(x) for x in v], ", ") * "\n"
                    elseif v isa AbstractDict
                        inner = String[]
                        for (k2, v2) in v
                            v2 isa AbstractString && push!(inner, "$(k2)=$(v2)")
                        end
                        !isempty(inner) && (block *= uppercase(string(k)) * ": " * join(inner, "; ") * "\n")
                    end
                end
            end
        end
        push!(extra_context, strip(block))
    end

    # 5. Emotion palette — the ACTUAL register/style samples
    palette = get(agent_config, "emotion_palette", [])
    if palette isa AbstractVector && !isempty(palette)
        block = "== EMOTION PALETTE (your default register lives here) ==\n"
        for facet in palette
            facet isa AbstractDict || continue
            label = String(get(facet, "label", get(facet, "id", "")))
            style = String(get(facet, "style", ""))
            isempty(label) && continue
            block *= " - " * label * (isempty(style) ? "" : ": " * style) * "\n"
        end
        push!(extra_context, strip(block))
    end

    # 6. Emotion wheel baseline — resting state
    wheel = get(agent_config, "emotion_wheel", Dict())
    if wheel isa AbstractDict && !isempty(wheel)
        baseline_root = String(get(wheel, "baseline_root", ""))
        baseline_family = String(get(wheel, "baseline_family", ""))
        if !isempty(baseline_root) || !isempty(baseline_family)
            block = "== BASELINE EMOTIONAL STATE ==\n"
            !isempty(baseline_root) && (block *= "ROOT: " * baseline_root * "\n")
            !isempty(baseline_family) && (block *= "FAMILY: " * baseline_family * "\n")
            push!(extra_context, strip(block))
        end
    end

    # 7. Abilities — execution traits (initiative, precision, clarity, etc.)
    abilities = get(agent_config, "abilities", Dict())
    if abilities isa AbstractDict
        traits = get(abilities, "execution_traits", Dict())
        if traits isa AbstractDict && !isempty(traits)
            block = "== EXECUTION TRAITS ==\n"
            for (k, v) in traits
                if v isa AbstractDict
                    b = String(get(v, "behavior", ""))
                    !isempty(b) && (block *= " - " * string(k) * ": " * b * "\n")
                end
            end
            push!(extra_context, strip(block))
        end
    end

    if !isempty(extra_context)
        return base_prompt * "\n\n" * join(extra_context, "\n\n")
    end

    return base_prompt
end
