--
-- Example Resource Definition using DSL
--

local resource_generator = require("apisix.admin.resource_generator")

local consumers_def = {
    name = "consumers",
    kind = "consumer",
    schema = "core.schema.consumer",
    return_id_field = "username",
    imports = {
        { name = "core", path = "apisix.core" },
        { name = "plugins", path = "apisix.admin.plugins" },
    },
    custom_imports = {
        "local plugins_encrypt_conf = require(\"apisix.admin.plugins\").encrypt_conf"
    },
    check_conf = {
        { type = "schema" },
        { 
            type = "id_consistency", 
            id_var = "id", 
            conf_field = "username" 
        },
        { 
            type = "plugins", 
            module = "plugins", 
            schema_type = "core.schema.TYPE_CONSUMER" 
        },
        { 
            type = "reference_check", 
            field = "group_id", 
            resource = "consumer_groups", 
            resource_desc = "consumer group" 
        },
    },
    encrypt_conf = {
        "plugins_encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)"
    },
    unsupported_methods = { "post", "patch" },
}

local routes_def = {
    name = "routes",
    kind = "route",
    schema = "core.schema.route",
    imports = {
        { name = "core", path = "apisix.core" },
        { name = "apisix_upstream", path = "apisix.upstream" },
    },
    custom_imports = {
        "local schema_plugin = require(\"apisix.admin.plugins\").check_schema",
        "local plugins_encrypt_conf = require(\"apisix.admin.plugins\").encrypt_conf",
        "local expr = require(\"resty.expr.v1\")",
        "local type = type",
        "local loadstring = loadstring",
        "local ipairs = ipairs",
        "local jp = require(\"jsonpath\")",
    },
    custom_code_top = {
        "local function validate_post_arg(node)",
        "    if type(node) ~= \"table\" then",
        "        return true",
        "    end",
        "    if #node >= 3 and type(node[1]) == \"string\" and node[1]:find(\"^post_arg%.\") then",
        "        local key = node[1]",
        "        local json_path = \"$.\" .. key:sub(11)",
        "        local _, err = jp.parse(json_path)",
        "        if err then",
        "            return false, err",
        "        end",
        "        return true",
        "    end",
        "    for _, child in ipairs(node) do",
        "        local ok, err = validate_post_arg(child)",
        "        if not ok then",
        "            return false, err",
        "        end",
        "    end",
        "    return true",
        "end",
    },
    check_conf = {
        { type = "mutually_exclusive", a = "host", b = "hosts" },
        { type = "mutually_exclusive", a = "remote_addr", b = "remote_addrs" },
        { type = "schema" },
        { type = "sub_schema", field = "upstream", module = "apisix_upstream" },
        { 
            type = "reference_check", 
            field = "upstream_id", 
            resource = "upstreams", 
            resource_desc = "upstream" 
        },
        { 
            type = "reference_check", 
            field = "service_id", 
            resource = "services", 
            resource_desc = "service" 
        },
        { 
            type = "reference_check", 
            field = "plugin_config_id", 
            resource = "plugin_configs", 
            resource_desc = "plugin config" 
        },
        { 
            type = "plugins", 
            module = "schema_plugin" 
        },
        {
            type = "custom",
            code = {
                "    if conf.vars then",
                "        ok, err = expr.new(conf.vars)",
                "        if not ok then",
                "            return nil, {error_msg = \"failed to validate the 'vars' expression: \" .. err}",
                "        end",
                "    end",
                "    ok, err = validate_post_arg(conf.vars)",
                "    if not ok  then",
                "        return nil, {error_msg = \"failed to validate the 'vars' expression: \" ..",
                "                                    err}",
                "    end",
                "    if conf.filter_func then",
                "        local func, err = loadstring(\"return \" .. conf.filter_func)",
                "        if not func then",
                "            return nil, {error_msg = \"failed to load 'filter_func' string: \"",
                "                                     .. err}",
                "        end",
                "        if type(func()) ~= \"function\" then",
                "            return nil, {error_msg = \"'filter_func' should be a function\"}",
                "        end",
                "    end",
                "    if conf.script then",
                "        local obj, err = loadstring(conf.script)",
                "        if not obj then",
                "            return nil, {error_msg = \"failed to load 'script' string: \"",
                "                                     .. err}",
                "        end",
                "        if type(obj()) ~= \"table\" then",
                "            return nil, {error_msg = \"'script' should be a Lua object\"}",
                "        end",
                "    end",
            }
        },
    },
    encrypt_conf = {
        "apisix_upstream.encrypt_conf(conf.upstream)",
        "plugins_encrypt_conf(conf.plugins)"
    },
    list_filter_fields = {
        service_id = true,
        upstream_id = true,
    },
}

return {
    consumers = consumers_def,
    routes = routes_def,
    generate = function(name)
        if name == "consumers" then
            return resource_generator.generate(consumers_def)
        elseif name == "routes" then
            return resource_generator.generate(routes_def)
        end
        return nil
    end
}
