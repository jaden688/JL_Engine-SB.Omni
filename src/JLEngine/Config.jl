using JSON3

function _materialize_json(value)
    if value isa JSON3.Object
        return Dict{String, Any}(String(key) => _materialize_json(item) for (key, item) in pairs(value))
    elseif value isa JSON3.Array
        return [_materialize_json(item) for item in value]
    elseif value isa AbstractDict
        return Dict{String, Any}(string(key) => _materialize_json(item) for (key, item) in pairs(value))
    elseif value isa AbstractVector
        return [_materialize_json(item) for item in value]
    end
    return value
end

function load_json_safely(path::AbstractString)
    if !isfile(path)
        return Dict{String, Any}()
    end

    text = read(path, String)
    text = replace(text, "\ufeff" => "")
    if isempty(strip(text))
        return Dict{String, Any}()
    end

    try
        return _materialize_json(JSON3.read(text))
    catch
        return Dict{String, Any}()
    end
end

function resolve_path(root_dir::AbstractString, path::AbstractString)
    return isabspath(path) ? path : normpath(joinpath(root_dir, path))
end

function load_engine_config(path::AbstractString)
    blob = load_json_safely(path)
    jl_blob = get(blob, "jl_engine", Dict{String, Any}())
    if jl_blob isa AbstractDict
        return Dict{String, Any}(string(key) => value for (key, value) in pairs(jl_blob))
    end
    return Dict{String, Any}()
end
