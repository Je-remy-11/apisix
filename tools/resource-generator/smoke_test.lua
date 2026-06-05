-- Smoke test for the resource code generator.
-- Run with: lua tools/resource-generator/smoke_test.lua
--
-- Since we can't run Lua in the sandbox, this file documents the expected output
-- and can be run when a Lua interpreter is available.

local gen = require("tools.resource-generator.generator")

local all_pass = true
local failed = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("[PASS] " .. name)
    else
        print("[FAIL] " .. name .. ": " .. tostring(err))
        all_pass = false
        table.insert(failed, name)
    end
end

-- ============================================================
-- Test 1: Generate consumers module
-- ============================================================
test("consumers spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/consumers.lua")
    local code = gen.generate(spec)
    assert(type(code) == "string", "expected string output")
    assert(#code > 0, "expected non-empty output")
    -- Check key components
    assert(code:find("resource.new"), "must contain resource.new() call")
    assert(code:find("check_conf"), "must contain check_conf()")
    assert(code:find("encrypt_conf"), "must contain encrypt_conf()")
    assert(code:find("username_match") or code:find("username"), "must contain username check")
    assert(code:find("group_id"), "must contain group_id reference check")
    assert(code:find("unsupported_methods"), "must contain unsupported_methods")
    assert(code:find("consumer"), "must contain kind=consumer")
    assert(code:find("TYPE_CONSUMER"), "must contain TYPE_CONSUMER for plugin check")
end)

-- ============================================================
-- Test 2: Generate routes module
-- ============================================================
test("routes spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/routes.lua")
    local code = gen.generate(spec)
    assert(type(code) == "string")
    assert(code:find("resource.new"), "must contain resource.new()")
    assert(code:find("check_conf"), "must contain check_conf()")
    assert(code:find("encrypt_conf"), "must contain encrypt_conf()")
    assert(code:find("delete_checker"), "must contain delete_checker()")
    assert(code:find("assert_not_both"), "or inline mutual exclusion",
           "must handle host/hosts exclusion")
    assert(code:find("upstream_id"), "must check upstream_id reference")
    assert(code:find("service_id"), "must check service_id reference")
    assert(code:find("plugin_config_id"), "must check plugin_config_id reference")
    assert(code:find("list_filter_fields"), "must contain list_filter_fields")
end)

-- ============================================================
-- Test 3: Generate upstreams module
-- ============================================================
test("upstreams spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/upstreams.lua")
    local code = gen.generate(spec)
    assert(code:find("delete_checker"), "must contain delete_checker()")
    assert(code:find("up_id_in_plugins"), "must contain traffic-split plugin check")
    assert(code:find("check_resources_reference"), "must contain multi-resource checker")
    assert(code:find("get_routes"), "must check routes")
    assert(code:find("get_services"), "must check services")
    assert(code:find("get_plugin_configs"), "must check plugin_configs")
    assert(code:find("get_consumers"), "must check consumers")
    assert(code:find("get_consumer_groups"), "must check consumer_groups")
    assert(code:find("get_global_rules"), "must check global_rules")
end)

-- ============================================================
-- Test 4: Generate ssl module
-- ============================================================
test("ssls spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/ssls.lua")
    local code = gen.generate(spec)
    assert(code:find("check_ssl_conf"), "must use SSL checker")
    assert(not code:find("encrypt_conf"), "SSL has no encrypt_conf")
    assert(not code:find("delete_checker"), "SSL has no delete_checker")
end)

-- ============================================================
-- Test 5: Generate secrets module
-- ============================================================
test("secrets spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/secrets.lua")
    local code = gen.generate(spec)
    assert(code:find("secret_type"), "must handle secret_type")
    assert(code:find("secret_manager"), "must validate secret manager")
    assert(not code:find("schema ="), "secrets has no fixed schema")
end)

-- ============================================================
-- Test 6: Generate plugin_metadata module
-- ============================================================
test("plugin_metadata spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/plugin_metadata.lua")
    local code = gen.generate(spec)
    assert(code:find("validate_plugin"), "must have plugin validator")
    assert(code:find("inject_metadata_schema"), "must have schema injector")
    assert(code:find("no_id"), "no_id resources handled by resource.lua")
end)

-- ============================================================
-- Test 7: Generate credentials module
-- ============================================================
test("credentials spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/credentials.lua")
    local code = gen.generate(spec)
    assert(code:find("credentials_auth_check") or code:find("auth"),
           "must restrict to auth plugins")
    assert(code:find("get_credential_etcd_key"), "must have custom etcd key")
end)

-- ============================================================
-- Test 8: Generate global_rules module
-- ============================================================
test("global_rules spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/global_rules.lua")
    local code = gen.generate(spec)
    assert(code:find("plugin_conflict"), "must detect plugin conflicts")
    assert(code:find("unsupported_methods"), "must disable POST")
end)

-- ============================================================
-- Test 9: Generate protos module
-- ============================================================
test("protos spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/protos.lua")
    local code = gen.generate(spec)
    assert(code:find("compile_proto"), "must compile protobuf content")
    assert(code:find("delete_checker"), "must have delete_checker")
end)

-- ============================================================
-- Test 10: Generate stream_routes module
-- ============================================================
test("stream_routes spec generates complete module", function()
    local spec = dofile("tools/resource-generator/specs/stream_routes.lua")
    local code = gen.generate(spec)
    assert(code:find("etcd_protocol_ref") or code:find("protocol"),
           "must check protocol superior_id")
    assert(code:find("stream_route_checker"), "must call stream_route_checker")
    assert(code:find("list_filter_fields"), "must have list_filter_fields")
end)

-- ============================================================
-- Summary
-- ============================================================
print("")
if all_pass then
    print("All tests PASSED!")
    os.exit(0)
else
    print("FAILED tests: " .. table.concat(failed, ", "))
    os.exit(1)
end