-- APISIX Admin Resource Spec: secrets
-- Demonstrates: no POST, dynamic schema via secrets_check, complex etcd key logic

return {
    name = "secrets",
    kind = "secret",

    unsupported_methods = {"post"},

    -- secrets has no fixed schema — schema is loaded dynamically
    -- based on opts.secret_type. We pass nil here and handle it in the checker.

    imports = {
        "local pcall = pcall",
    },

    validations = {
        {type = "secrets_check"},
    },

    -- The secrets module has no encrypt_conf and no delete_checker.
    -- The etcd key format for secrets is "/secrets/{type}/{id}".
    -- This is handled by resource.lua internally when name=="secrets",
    -- so no custom function is needed in the generated module.
}