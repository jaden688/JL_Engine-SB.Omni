function _env_trim(name::AbstractString, default::AbstractString="")
    return strip(get(ENV, String(name), default))
end

function _env_bool(name::AbstractString, default::Bool=false)::Bool
    raw = lowercase(_env_trim(name, default ? "1" : "0"))
    return !(raw in ("", "0", "false", "no", "off"))
end

function _env_int(name::AbstractString, default::Int=0)::Int
    raw = _env_trim(name, string(default))
    return try parse(Int, raw) catch; default end
end

function _env_float(name::AbstractString, default::Float64=0.0)::Float64
    raw = _env_trim(name, string(default))
    return try parse(Float64, raw) catch; default end
end

const A2A_API_KEY = _env_trim("A2A_API_KEY")
const A2A_ADMIN_KEY = _env_trim("A2A_ADMIN_KEY")
const A2A_BILLING_ENFORCE = _env_bool("A2A_BILLING_ENFORCE", false)
const A2A_MAX_REQUESTS_PER_MINUTE = _env_int("A2A_MAX_REQUESTS_PER_MINUTE", 0)
const A2A_PRICE_PER_1K_REQUESTS = _env_float("A2A_PRICE_PER_1K_REQUESTS", 0.0)
const A2A_PRICE_PER_1K_INPUT_CHARS = _env_float("A2A_PRICE_PER_1K_INPUT_CHARS", 0.0)
const A2A_PRICE_PER_1K_OUTPUT_CHARS = _env_float("A2A_PRICE_PER_1K_OUTPUT_CHARS", 0.0)
const A2A_PRICE_PER_TOOL_CALL = _env_float("A2A_PRICE_PER_TOOL_CALL", 0.0)
const A2A_BILLING_PAYMENT_LINK_URL = _env_trim("A2A_BILLING_PAYMENT_LINK_URL")
const A2A_BILLING_PORTAL_URL = _env_trim("A2A_BILLING_PORTAL_URL")
const A2A_BILLING_SUCCESS_URL = _env_trim("A2A_BILLING_SUCCESS_URL")
const A2A_BILLING_CANCEL_URL = _env_trim("A2A_BILLING_CANCEL_URL")
const A2A_BILLING_PORTAL_RETURN_URL = _env_trim("A2A_BILLING_PORTAL_RETURN_URL")

_a2a_api_key() = A2A_API_KEY
_a2a_admin_key() = A2A_ADMIN_KEY
_billing_enforce_enabled() = A2A_BILLING_ENFORCE
_a2a_max_requests_per_minute() = A2A_MAX_REQUESTS_PER_MINUTE
_a2a_price_per_1k_requests() = A2A_PRICE_PER_1K_REQUESTS
_a2a_price_per_1k_input_chars() = A2A_PRICE_PER_1K_INPUT_CHARS
_a2a_price_per_1k_output_chars() = A2A_PRICE_PER_1K_OUTPUT_CHARS
_a2a_price_per_tool_call() = A2A_PRICE_PER_TOOL_CALL
_a2a_billing_payment_link_url() = A2A_BILLING_PAYMENT_LINK_URL
_a2a_billing_portal_url() = A2A_BILLING_PORTAL_URL
_a2a_billing_success_url() = A2A_BILLING_SUCCESS_URL
_a2a_billing_cancel_url() = A2A_BILLING_CANCEL_URL
_a2a_billing_portal_return_url() = A2A_BILLING_PORTAL_RETURN_URL

function _a2a_public_mode()::Bool
    return isempty(_a2a_api_key()) && isempty(_a2a_admin_key()) && !_billing_enforce_enabled()
end

function _a2a_auth_scheme()::String
    return _a2a_public_mode() ? "none" : "bearer"
end

function _a2a_auth_required()::Bool
    return !_a2a_public_mode()
end

function _a2a_request_key(req::HTTP.Request)::String
    auth = strip(HTTP.header(req, "Authorization", ""))
    if startswith(lowercase(auth), "bearer ")
        return strip(auth[8:end])
    end
    return strip(HTTP.header(req, "X-API-Key", ""))
end

function _a2a_mask_key(key::AbstractString)::String
    s = strip(String(key))
    isempty(s) && return ""
    length(s) <= 8 && return s
    return string(first(s, 4), "…", last(s, 4))
end

function _a2a_is_admin_key(key::AbstractString)::Bool
    s = strip(String(key))
    isempty(s) && return false
    admin = _a2a_admin_key()
    if !isempty(admin)
        return s == admin
    end
    bootstrap = _a2a_api_key()
    return !isempty(bootstrap) && s == bootstrap
end

function _a2a_account_status_allows_access(status::AbstractString)::Bool
    st = lowercase(strip(String(status)))
    return st in ("active", "trialing", "grace", "paid", "open", "admin")
end

function _a2a_account_row_to_dict(r)::Dict{String,Any}
    return Dict(
        "api_key" => string(r.api_key),
        "label" => ismissing(r.label) ? "" : string(r.label),
        "plan" => ismissing(r.plan) ? "" : string(r.plan),
        "subscription_status" => ismissing(r.subscription_status) ? "" : string(r.subscription_status),
        "billing_email" => ismissing(r.billing_email) ? "" : string(r.billing_email),
        "stripe_customer_id" => ismissing(r.stripe_customer_id) ? "" : string(r.stripe_customer_id),
        "stripe_subscription_id" => ismissing(r.stripe_subscription_id) ? "" : string(r.stripe_subscription_id),
        "stripe_price_id" => ismissing(r.stripe_price_id) ? "" : string(r.stripe_price_id),
        "checkout_session_id" => ismissing(r.checkout_session_id) ? "" : string(r.checkout_session_id),
        "active_until" => ismissing(r.active_until) ? "" : string(r.active_until),
        "created_at" => ismissing(r.created_at) ? "" : string(r.created_at),
        "updated_at" => ismissing(r.updated_at) ? "" : string(r.updated_at),
        "last_seen_at" => ismissing(r.last_seen_at) ? "" : string(r.last_seen_at),
        "notes" => ismissing(r.notes) ? "" : string(r.notes),
        "metadata_json" => ismissing(r.metadata_json) ? "{}" : string(r.metadata_json),
    )
end

function _a2a_synthetic_account(api_key::AbstractString)::Union{Nothing,Dict{String,Any}}
    s = strip(String(api_key))
    isempty(s) && return nothing
    now_text = string(now(UTC))
    if !isempty(_a2a_admin_key()) && s == _a2a_admin_key()
        return Dict(
            "api_key" => s, "label" => "Admin key", "plan" => "admin",
            "subscription_status" => "admin", "billing_email" => "",
            "stripe_customer_id" => "", "stripe_subscription_id" => "",
            "stripe_price_id" => "", "checkout_session_id" => "",
            "active_until" => "", "created_at" => now_text, "updated_at" => now_text,
            "last_seen_at" => now_text, "notes" => "", "metadata_json" => "{}",
        )
    elseif !isempty(_a2a_api_key()) && s == _a2a_api_key()
        return Dict(
            "api_key" => s, "label" => "Bootstrap key", "plan" => "owner",
            "subscription_status" => _billing_enforce_enabled() ? "active" : "open",
            "billing_email" => "", "stripe_customer_id" => "", "stripe_subscription_id" => "",
            "stripe_price_id" => "", "checkout_session_id" => "", "active_until" => "",
            "created_at" => now_text, "updated_at" => now_text, "last_seen_at" => now_text,
            "notes" => "", "metadata_json" => "{}",
        )
    end
    return nothing
end

function _a2a_get_account(db::SQLite.DB, api_key::AbstractString)
    key = strip(String(api_key))
    isempty(key) && return nothing
    synthetic = _a2a_synthetic_account(key)
    synthetic !== nothing && return synthetic
    rows = SQLite.DBInterface.execute(db, """
        SELECT api_key, label, plan, subscription_status, billing_email,
               stripe_customer_id, stripe_subscription_id, stripe_price_id,
               checkout_session_id, active_until, created_at, updated_at,
               last_seen_at, notes, metadata_json
        FROM a2a_accounts WHERE api_key=?
    """, (key,)) |> DataFrame
    isempty(rows) && return nothing
    return _a2a_account_row_to_dict(rows[1, :])
end

function _a2a_account_exists(db::SQLite.DB, api_key::AbstractString)::Bool
    key = strip(String(api_key))
    isempty(key) && return false
    rows = SQLite.DBInterface.execute(db, "SELECT 1 FROM a2a_accounts WHERE api_key=? LIMIT 1", (key,)) |> DataFrame
    return !isempty(rows)
end

function _billing_init_db!(db::SQLite.DB)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS a2a_accounts (
            api_key TEXT PRIMARY KEY,
            label TEXT,
            plan TEXT,
            subscription_status TEXT,
            billing_email TEXT,
            stripe_customer_id TEXT,
            stripe_subscription_id TEXT,
            stripe_price_id TEXT,
            checkout_session_id TEXT,
            active_until TEXT,
            created_at TEXT,
            updated_at TEXT,
            last_seen_at TEXT,
            notes TEXT,
            metadata_json TEXT
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS a2a_usage_ledger (
            id INTEGER PRIMARY KEY,
            created_at TEXT,
            created_at_unix INTEGER,
            api_key TEXT,
            task_id TEXT,
            method TEXT,
            request_chars INTEGER,
            response_chars INTEGER,
            tool_calls INTEGER,
            price_usd REAL,
            status TEXT,
            metadata_json TEXT
        )
    """)
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_a2a_usage_key_time ON a2a_usage_ledger(api_key, created_at_unix)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_a2a_accounts_status ON a2a_accounts(subscription_status)")
end

function _a2a_merge_account(current::Dict{String,Any}, kwargs::Dict{String,Any})::Dict{String,Any}
    out = copy(current)
    for (k, v) in kwargs
        if v === nothing
            continue
        elseif v isa AbstractString
            s = strip(String(v))
            isempty(s) && continue
            out[k] = s
        else
            out[k] = v
        end
    end
    out["updated_at"] = string(now(UTC))
    return out
end

function _a2a_upsert_account!(
    db::SQLite.DB,
    api_key::AbstractString;
    label=nothing,
    plan=nothing,
    subscription_status=nothing,
    billing_email=nothing,
    stripe_customer_id=nothing,
    stripe_subscription_id=nothing,
    stripe_price_id=nothing,
    checkout_session_id=nothing,
    active_until=nothing,
    notes=nothing,
    metadata_json=nothing,
    last_seen_at=nothing,
)
    key = strip(String(api_key))
    isempty(key) && error("api_key is required")
    current = _a2a_get_account(db, key)
    base = current === nothing ? Dict{String,Any}(
        "api_key" => key, "label" => "", "plan" => "", "subscription_status" => "",
        "billing_email" => "", "stripe_customer_id" => "", "stripe_subscription_id" => "",
        "stripe_price_id" => "", "checkout_session_id" => "", "active_until" => "",
        "created_at" => string(now(UTC)), "updated_at" => string(now(UTC)), "last_seen_at" => "",
        "notes" => "", "metadata_json" => "{}",
    ) : Dict{String,Any}(current)
    merged = _a2a_merge_account(base, Dict{String,Any}(
        "label" => label, "plan" => plan, "subscription_status" => subscription_status,
        "billing_email" => billing_email, "stripe_customer_id" => stripe_customer_id,
        "stripe_subscription_id" => stripe_subscription_id, "stripe_price_id" => stripe_price_id,
        "checkout_session_id" => checkout_session_id, "active_until" => active_until,
        "notes" => notes, "metadata_json" => metadata_json, "last_seen_at" => last_seen_at,
    ))
    if !haskey(merged, "created_at") || isempty(string(merged["created_at"]))
        merged["created_at"] = string(now(UTC))
    end
    SQLite.execute(db, """
        INSERT OR REPLACE INTO a2a_accounts
        (api_key, label, plan, subscription_status, billing_email,
         stripe_customer_id, stripe_subscription_id, stripe_price_id,
         checkout_session_id, active_until, created_at, updated_at,
         last_seen_at, notes, metadata_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """, (
        merged["api_key"], merged["label"], merged["plan"], merged["subscription_status"],
        merged["billing_email"], merged["stripe_customer_id"], merged["stripe_subscription_id"],
        merged["stripe_price_id"], merged["checkout_session_id"], merged["active_until"],
        merged["created_at"], merged["updated_at"], merged["last_seen_at"], merged["notes"],
        merged["metadata_json"],
    ))
    return merged
end

function _a2a_auth_response(message::AbstractString; code::Int=401)
    return HTTP.Response(code, ["Content-Type" => "application/json"], JSON.json(Dict("error" => string(message))))
end

function _a2a_check_auth(req::HTTP.Request, db::SQLite.DB=nothing; require_admin::Bool=false)::Union{Nothing,HTTP.Response}
    if !_a2a_auth_required() && !require_admin
        return nothing
    end
    key = _a2a_request_key(req)
    isempty(key) && return _a2a_auth_response("Unauthorized — missing bearer token")
    if require_admin
        _a2a_is_admin_key(key) && return nothing
        return _a2a_auth_response("Forbidden — admin key required", code=403)
    end
    _a2a_is_admin_key(key) && return nothing
    account = db === nothing ? nothing : _a2a_get_account(db, key)
    account === nothing && return _a2a_auth_response("Unauthorized — invalid or inactive API key")
    _a2a_account_status_allows_access(get(account, "subscription_status", "")) && return nothing
    return _a2a_auth_response("Payment required — subscription inactive", code=402)
end

function _a2a_usage_window_since_unix(window::AbstractString="30d")::Int
    normalized = lowercase(strip(String(window)))
    now_unix = round(Int, time())
    if normalized in ("lifetime", "all", "total")
        return 0
    elseif normalized in ("1h", "hour", "60m")
        return now_unix - 3600
    elseif normalized in ("24h", "day")
        return now_unix - 86400
    elseif normalized in ("7d", "week")
        return now_unix - 7 * 86400
    else
        return now_unix - 30 * 86400
    end
end

function _a2a_rate_limit_response(db::SQLite.DB, api_key::AbstractString)::Union{Nothing,HTTP.Response}
    limit = _a2a_max_requests_per_minute()
    limit <= 0 && return nothing
    key = strip(String(api_key))
    isempty(key) && return nothing
    _a2a_is_admin_key(key) && return nothing
    cutoff = round(Int, time()) - 60
    rows = SQLite.DBInterface.execute(db, """
        SELECT COUNT(*) AS count
        FROM a2a_usage_ledger
        WHERE api_key=? AND created_at_unix >= ?
    """, (key, cutoff)) |> DataFrame
    count = isempty(rows) ? 0 : Int(rows[1, :count])
    count < limit && return nothing
    return HTTP.Response(429, ["Content-Type" => "application/json"],
        JSON.json(Dict("error" => "Rate limit exceeded", "limit_per_minute" => limit)))
end

function _a2a_estimated_price(request_count::Int, request_chars::Int, response_chars::Int, tool_calls::Int)::Float64
    return request_count / 1000 * _a2a_price_per_1k_requests() +
        request_chars / 1000 * _a2a_price_per_1k_input_chars() +
        response_chars / 1000 * _a2a_price_per_1k_output_chars() +
        tool_calls * _a2a_price_per_tool_call()
end

function _a2a_record_usage!(
    db::SQLite.DB,
    api_key::AbstractString,
    task_id::AbstractString,
    method::AbstractString,
    input_text::AbstractString,
    result;
    tool_calls::Int=0,
    status::AbstractString="completed",
    metadata::Dict{String,Any}=Dict{String,Any}(),
)
    key = strip(String(api_key))
    isempty(key) && return nothing
    request_chars = length(String(input_text))
    result_json = JSON.json(result)
    response_chars = length(result_json)
    price_usd = _a2a_estimated_price(1, request_chars, response_chars, tool_calls)
    now_unix = round(Int, time())
    now_text = string(now(UTC))
    meta_json = isempty(metadata) ? "{}" : JSON.json(metadata)
    SQLite.execute(db, """
        INSERT INTO a2a_usage_ledger
        (created_at, created_at_unix, api_key, task_id, method, request_chars,
         response_chars, tool_calls, price_usd, status, metadata_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    """, (now_text, now_unix, key, String(task_id), String(method), request_chars, response_chars, tool_calls, price_usd, String(status), meta_json))
    if _a2a_account_exists(db, key)
        SQLite.execute(db, "UPDATE a2a_accounts SET last_seen_at=?, updated_at=? WHERE api_key=?", (now_text, now_text, key))
    end
    return nothing
end

function _a2a_usage_summary(db::SQLite.DB, api_key::AbstractString; window::AbstractString="30d")
    key = strip(String(api_key))
    since_unix = _a2a_usage_window_since_unix(window)
    rows = SQLite.DBInterface.execute(db, """
        SELECT COUNT(*) AS request_count,
               COALESCE(SUM(request_chars), 0) AS request_chars,
               COALESCE(SUM(response_chars), 0) AS response_chars,
               COALESCE(SUM(tool_calls), 0) AS tool_calls,
               COALESCE(SUM(price_usd), 0.0) AS price_usd,
               COALESCE(MAX(created_at_unix), 0) AS last_seen_unix
        FROM a2a_usage_ledger
        WHERE api_key=? AND created_at_unix >= ?
    """, (key, since_unix)) |> DataFrame
    row = isempty(rows) ? nothing : rows[1, :]
    account = _a2a_get_account(db, key)
    request_count = row === nothing ? 0 : Int(row.request_count)
    request_chars = row === nothing ? 0 : Int(row.request_chars)
    response_chars = row === nothing ? 0 : Int(row.response_chars)
    tool_calls = row === nothing ? 0 : Int(row.tool_calls)
    price_usd = row === nothing ? 0.0 : Float64(row.price_usd)
    last_seen_unix = row === nothing ? 0 : Int(row.last_seen_unix)
    return Dict(
        "api_key" => _a2a_mask_key(key),
        "window" => window,
        "since_unix" => since_unix,
        "request_count" => request_count,
        "request_chars" => request_chars,
        "response_chars" => response_chars,
        "tool_calls" => tool_calls,
        "estimated_usd" => round(price_usd, digits=6),
        "last_seen_unix" => last_seen_unix,
        "subscription_status" => account === nothing ? "" : get(account, "subscription_status", ""),
        "plan" => account === nothing ? "" : get(account, "plan", ""),
    )
end

function _a2a_default_success_url()::String
    configured = _a2a_billing_success_url()
    isempty(configured) && return rstrip(A2A_PUBLIC_URL, '/') * "/billing/success?checkout_session={CHECKOUT_SESSION_ID}"
    return occursin("{CHECKOUT_SESSION_ID}", configured) ? configured : configured * (occursin("?", configured) ? "&checkout_session={CHECKOUT_SESSION_ID}" : "?checkout_session={CHECKOUT_SESSION_ID}")
end

function _a2a_default_cancel_url()::String
    configured = _a2a_billing_cancel_url()
    isempty(configured) && return rstrip(A2A_PUBLIC_URL, '/') * "/billing/cancel"
    return configured
end

function _a2a_default_portal_return_url()::String
    configured = _a2a_billing_portal_return_url()
    isempty(configured) && return rstrip(A2A_PUBLIC_URL, '/') * "/settings/billing"
    return configured
end

function _a2a_issue_access_key()::String
    return replace(string(uuid4()), "-" => "")
end

function _a2a_prepare_checkout!(db::SQLite.DB, params::Dict{String,Any})
    key = strip(String(get(params, "api_key", "")))
    isempty(key) && (key = _a2a_issue_access_key())
    label = string(get(params, "label", ""))
    plan = string(get(params, "plan", "starter"))
    billing_email = string(get(params, "billing_email", get(params, "customer_email", "")))
    status = string(get(params, "subscription_status", _billing_enforce_enabled() ? "inactive" : "active"))
    account = _a2a_upsert_account!(db, key;
        label=label,
        plan=plan,
        billing_email=billing_email,
        subscription_status=status,
        notes=string(get(params, "notes", "checkout requested")),
        metadata_json=JSON.json(get(params, "metadata", Dict{String,Any}())),
    )
    checkout_url = _a2a_billing_payment_link_url()
    portal_url = _a2a_billing_portal_url()
    if isempty(checkout_url)
        return Dict(
            "error" => "Set A2A_BILLING_PAYMENT_LINK_URL to enable checkout links",
            "api_key" => key,
            "account" => account,
        )
    end
    _a2a_upsert_account!(db, key;
        checkout_session_id=string(get(params, "checkout_session_id", "")),
        subscription_status="pending_checkout",
        stripe_price_id=string(get(params, "stripe_price_id", "")),
    )
    return Dict(
        "api_key" => key,
        "checkout_url" => checkout_url,
        "portal_url" => portal_url,
        "account" => _a2a_get_account(db, key),
    )
end

function _a2a_portal_payload(db::SQLite.DB, params::Dict{String,Any})
    key = strip(String(get(params, "api_key", "")))
    account = _a2a_get_account(db, key)
    portal_url = _a2a_billing_portal_url()
    if isempty(portal_url)
        return Dict("error" => "Set A2A_BILLING_PORTAL_URL to enable customer portal links", "api_key" => key, "account" => account)
    end
    return Dict("api_key" => key, "portal_url" => portal_url, "return_url" => _a2a_default_portal_return_url(), "account" => account)
end

function _a2a_billing_status_payload(db::SQLite.DB, api_key::AbstractString; window::AbstractString="30d")
    key = strip(String(api_key))
    account = _a2a_get_account(db, key)
    account_dict = account === nothing ? Dict{String,Any}(
        "api_key" => _a2a_mask_key(key),
        "label" => "",
        "plan" => "",
        "subscription_status" => _a2a_public_mode() ? "open" : "inactive",
        "billing_email" => "",
        "stripe_customer_id" => "",
        "stripe_subscription_id" => "",
        "stripe_price_id" => "",
        "checkout_session_id" => "",
        "active_until" => "",
        "created_at" => "",
        "updated_at" => "",
        "last_seen_at" => "",
        "notes" => "",
        "metadata_json" => "{}",
    ) : account
    usage_30d = _a2a_usage_summary(db, key; window=window)
    usage_all = _a2a_usage_summary(db, key; window="lifetime")
    status = lowercase(strip(String(get(account_dict, "subscription_status", ""))))
    active = _a2a_account_status_allows_access(status) && !(status == "open" && _billing_enforce_enabled())
    return Dict(
        "billing_enforced" => _billing_enforce_enabled(),
        "auth_scheme" => _a2a_auth_scheme(),
        "active" => active,
        "account" => account_dict,
        "usage" => Dict("30d" => usage_30d, "lifetime" => usage_all),
        "pricing" => Dict(
            "price_per_1k_requests" => _a2a_price_per_1k_requests(),
            "price_per_1k_input_chars" => _a2a_price_per_1k_input_chars(),
            "price_per_1k_output_chars" => _a2a_price_per_1k_output_chars(),
            "price_per_tool_call" => _a2a_price_per_tool_call(),
        ),
        "checkout" => Dict("payment_link_url" => _a2a_billing_payment_link_url(), "default_success_url" => _a2a_default_success_url(), "default_cancel_url" => _a2a_default_cancel_url()),
        "portal" => Dict("portal_url" => _a2a_billing_portal_url(), "default_return_url" => _a2a_default_portal_return_url()),
        "rate_limit" => Dict("requests_per_minute" => _a2a_max_requests_per_minute()),
    )
end

function _a2a_usage_payload(db::SQLite.DB, api_key::AbstractString; window::AbstractString="30d")
    key = strip(String(api_key))
    return Dict(
        "billing_enforced" => _billing_enforce_enabled(),
        "account" => _a2a_get_account(db, key),
        "usage" => _a2a_usage_summary(db, key; window=window),
        "pricing" => Dict(
            "price_per_1k_requests" => _a2a_price_per_1k_requests(),
            "price_per_1k_input_chars" => _a2a_price_per_1k_input_chars(),
            "price_per_1k_output_chars" => _a2a_price_per_1k_output_chars(),
            "price_per_tool_call" => _a2a_price_per_tool_call(),
        ),
    )
end

function _a2a_create_key_payload(db::SQLite.DB, params::Dict{String,Any})
    key = strip(String(get(params, "api_key", "")))
    isempty(key) && (key = _a2a_issue_access_key())
    account = _a2a_upsert_account!(db, key;
        label=get(params, "label", nothing),
        plan=get(params, "plan", nothing),
        billing_email=get(params, "billing_email", get(params, "customer_email", nothing)),
        subscription_status=get(params, "subscription_status", _billing_enforce_enabled() ? "inactive" : "active"),
        stripe_customer_id=get(params, "stripe_customer_id", nothing),
        stripe_subscription_id=get(params, "stripe_subscription_id", nothing),
        stripe_price_id=get(params, "stripe_price_id", nothing),
        active_until=get(params, "active_until", nothing),
        notes=get(params, "notes", "created by billing/key/create"),
        metadata_json=haskey(params, "metadata") ? JSON.json(params["metadata"]) : nothing,
    )
    if get(params, "create_checkout", true)
        checkout = _a2a_prepare_checkout!(db, Dict{String,Any}(
            "api_key" => key,
            "label" => get(params, "label", ""),
            "plan" => get(params, "plan", "starter"),
            "billing_email" => get(params, "billing_email", get(params, "customer_email", "")),
            "subscription_status" => get(params, "subscription_status", "inactive"),
            "stripe_price_id" => get(params, "stripe_price_id", ""),
            "notes" => get(params, "notes", "created by billing/key/create"),
            "metadata" => get(params, "metadata", Dict{String,Any}()),
        ))
        haskey(checkout, "error") && return Dict("api_key" => key, "account" => account, "checkout" => checkout)
        return merge(Dict("api_key" => key, "account" => account), checkout)
    end
    return Dict("api_key" => key, "account" => account)
end

function _a2a_update_key_payload(db::SQLite.DB, params::Dict{String,Any})
    key = strip(String(get(params, "api_key", "")))
    isempty(key) && return Dict("error" => "api_key is required")
    account = _a2a_upsert_account!(db, key;
        label=get(params, "label", nothing),
        plan=get(params, "plan", nothing),
        subscription_status=get(params, "subscription_status", nothing),
        billing_email=get(params, "billing_email", nothing),
        stripe_customer_id=get(params, "stripe_customer_id", nothing),
        stripe_subscription_id=get(params, "stripe_subscription_id", nothing),
        stripe_price_id=get(params, "stripe_price_id", nothing),
        checkout_session_id=get(params, "checkout_session_id", nothing),
        active_until=get(params, "active_until", nothing),
        notes=get(params, "notes", nothing),
        metadata_json=haskey(params, "metadata") ? JSON.json(params["metadata"]) : nothing,
    )
    return Dict("api_key" => key, "account" => account)
end

function _a2a_handle_billing_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, meth::AbstractString, params::Dict{String,Any})::Union{Nothing,HTTP.Response}
    billing_methods = Set(["billing/status", "usage/get", "billing/key/create", "billing/key/update", "billing/link", "billing/checkout", "billing/portal"])
    meth in billing_methods || return nothing

    if meth in ("billing/key/create", "billing/key/update", "billing/link")
        auth_err = _a2a_check_auth(req, db; require_admin=true)
        auth_err !== nothing && return auth_err
    else
        auth_err = _a2a_check_auth(req, db)
        auth_err !== nothing && return auth_err
    end

    api_key = strip(String(get(params, "api_key", "")))
    if isempty(api_key) && meth in ("billing/status", "usage/get", "billing/checkout", "billing/portal")
        api_key = _a2a_request_key(req)
    end

    result = if meth == "billing/status"
        _a2a_billing_status_payload(db, api_key; window=string(get(params, "window", "30d")))
    elseif meth == "usage/get"
        _a2a_usage_payload(db, api_key; window=string(get(params, "window", "30d")))
    elseif meth == "billing/key/create"
        _a2a_create_key_payload(db, params)
    elseif meth == "billing/key/update" || meth == "billing/link"
        _a2a_update_key_payload(db, params)
    elseif meth == "billing/checkout"
        _a2a_prepare_checkout!(db, Dict{String,Any}(
            "api_key" => isempty(api_key) ? _a2a_issue_access_key() : api_key,
            "label" => get(params, "label", ""),
            "plan" => get(params, "plan", "starter"),
            "billing_email" => get(params, "billing_email", get(params, "customer_email", "")),
            "subscription_status" => get(params, "subscription_status", "inactive"),
            "stripe_price_id" => get(params, "stripe_price_id", ""),
            "notes" => get(params, "notes", "billing/checkout"),
            "metadata" => get(params, "metadata", Dict{String,Any}()),
        ))
    elseif meth == "billing/portal"
        _a2a_portal_payload(db, Dict{String,Any}(
            "api_key" => api_key,
            "customer_id" => get(params, "customer_id", ""),
        ))
    else
        Dict("error" => "Unsupported billing method: $meth")
    end

    haskey(result, "error") && return HTTP.Response(400, ["Content-Type" => "application/json"], JSON.json(_rpc_error(rpc_id, -32000, string(result["error"]))))
    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(_rpc_result(rpc_id, result)))
end

function _a2a_task_entitlement_block(db::SQLite.DB, api_key::AbstractString, task_id::AbstractString, input_text::AbstractString, tool::AbstractString)
    rate_err = _a2a_rate_limit_response(db, api_key)
    rate_err !== nothing && return rate_err
    !_billing_enforce_enabled() && return nothing
    _a2a_is_admin_key(api_key) && return nothing
    account = _a2a_get_account(db, api_key)
    if account === nothing
        return HTTP.Response(402, ["Content-Type" => "application/json"], JSON.json(Dict("error" => "Payment required", "billing_enforced" => true, "upgrade" => _a2a_billing_payment_link_url(), "task_id" => task_id)))
    end
    status = lowercase(strip(String(get(account, "subscription_status", ""))))
    if status == "open" && _billing_enforce_enabled()
        return HTTP.Response(402, ["Content-Type" => "application/json"], JSON.json(Dict("error" => "Payment required", "billing_enforced" => true, "subscription_status" => status, "upgrade" => _a2a_billing_payment_link_url(), "task_id" => task_id, "tool" => tool, "input_chars" => length(String(input_text)))))
    end
    _a2a_account_status_allows_access(status) && return nothing
    return HTTP.Response(402, ["Content-Type" => "application/json"],
        JSON.json(Dict("error" => "Payment required", "billing_enforced" => true, "subscription_status" => status, "upgrade" => _a2a_billing_payment_link_url(), "task_id" => task_id, "tool" => tool, "input_chars" => length(String(input_text)))))
end
