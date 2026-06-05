-- APISIX Admin Resource Spec: ssl
-- Demonstrates: simple check_conf via ssl_check delegate

return {
    name = "ssls",
    kind = "ssl",
    schema = "core.schema.ssl",

    imports = {
        "local apisix_ssl = require(\"apisix.ssl\")",
    },

    validations = {
        {type = "ssl_check"},
    },
}