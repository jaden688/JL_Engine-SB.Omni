using Test
using SQLite

@testset "A2A billing" begin
    db = SQLite.DB(":memory:")
    _billing_init_db!(db)

    @test _a2a_auth_scheme() == (_a2a_public_mode() ? "none" : "bearer")

    status = _a2a_billing_status_payload(db, "")
    @test haskey(status, "billing_enforced")
    @test status["auth_scheme"] == _a2a_auth_scheme()

    created = _a2a_create_key_payload(db, Dict{String,Any}(
        "create_checkout" => false,
        "label" => "Launch customer",
        "plan" => "starter",
    ))
    @test length(created["api_key"]) >= 16
    @test created["account"]["label"] == "Launch customer"

    updated = _a2a_update_key_payload(db, Dict{String,Any}(
        "api_key" => created["api_key"],
        "subscription_status" => "active",
        "notes" => "paid",
    ))
    @test updated["account"]["subscription_status"] == "active"
    @test updated["account"]["notes"] == "paid"
end
