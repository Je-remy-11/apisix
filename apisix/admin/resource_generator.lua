--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

-- Resource Generator: Generate complete resource modules from concise definitions

local _M = {}

local function table_to_lua(tbl, indent)
    indent = indent or 0
    local result = {}
    local indent_str = string.rep("    ", indent)
    
    for k, v in pairs(tbl) do
        local key
        if type(k) == "string" then
            if string.match(k, "^[a-zA-Z_][a-zA-Z0-9_]*$") then
                key = k
            else
                key = string.format("[%q]", k)
            end
        else
            key = string.format("[%s]", tostring(k))
        end
        
        local val
        if type(v) == "string" then
            val = string.format("%q", v)
        elseif type(v) == "table" then
            val = table_to_lua(v, indent + 1)
        else
            val = tostring(v)
        end
        
        table.insert(result, indent_str .. key .. " = " .. val)
    end
    
    return "{\n" .. table.concat(result, ",\n") .. "\n" .. string.rep("    ", indent - 1) .. "}"
end

function _M.generate(def)
    local lines = {}
    
    table.insert(lines, "--")
    table.insert(lines, "-- Licensed to the Apache Software Foundation (ASF) under one or more")
    table.insert(lines, "-- contributor license agreements.  See the NOTICE file distributed with")
    table.insert(lines, "-- this work for additional information regarding copyright ownership.")
    table.insert(lines, "-- The ASF licenses this file to You under the Apache License, Version 2.0")
    table.insert(lines, "-- (the \"License\"); you may not use this file except in compliance with")
    table.insert(lines, "-- the License.  You may obtain a copy of the License at")
    table.insert(lines, "--")
    table.insert(lines, "--     http://www.apache.org/licenses/LICENSE-2.0")
    table.insert(lines, "--")
    table.insert(lines, "-- Unless required by applicable law or agreed to in writing, software")
    table.insert(lines, "-- distributed under the License is distributed on an \"AS IS\" BASIS,")
    table.insert(lines, "-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.")
    table.insert(lines, "-- See the License for the specific language governing permissions and")
    table.insert(lines, "-- limitations under the License.")
    table.insert(lines, "--")
    
    for _, import in ipairs(def.imports or {}) do
        table.insert(lines, string.format("local %s = require(\"%s\")", import.name, import.path))
    end
    table.insert(lines, "local resource = require(\"apisix.admin.resource\")")
    
    if def.custom_imports then
        for _, import in ipairs(def.custom_imports) do
            table.insert(lines, import)
        end
    end
    table.insert(lines, "")
    
    if def.custom_code_top then
        for _, line in ipairs(def.custom_code_top) do
            table.insert(lines, line)
        end
        table.insert(lines, "")
    end
    
    if def.check_conf then
        table.insert(lines, "local function check_conf(id, conf, need_id, schema, opts)")
        table.insert(lines, "    opts = opts or {}")
        
        for _, check in ipairs(def.check_conf) do
            if check.type == "schema" then
                table.insert(lines, "    local ok, err = core.schema.check(schema, conf)")
                table.insert(lines, "    if not ok then")
                table.insert(lines, "        return nil, {error_msg = \"invalid configuration: \" .. err}")
                table.insert(lines, "    end")
            elseif check.type == "mutually_exclusive" then
                table.insert(lines, string.format("    if conf.%s and conf.%s then", check.a, check.b))
                table.insert(lines, string.format("        return nil, {error_msg = \"only one of %s or %s is allowed\"}", check.a, check.b))
                table.insert(lines, "    end")
            elseif check.type == "plugins" then
                table.insert(lines, "    if conf.plugins then")
                local plugin_type = check.schema_type or "core.schema.TYPE_CONSUMER"
                table.insert(lines, string.format("        local ok, err = %s.check_schema(conf.plugins, %s)", 
                    check.module or "plugins", plugin_type))
                table.insert(lines, "        if not ok then")
                table.insert(lines, "            return nil, {error_msg = \"invalid plugins configuration: \" .. err}")
                table.insert(lines, "        end")
                table.insert(lines, "    end")
            elseif check.type == "id_consistency" then
                table.insert(lines, string.format("    if %s and %s ~= conf.%s then", check.id_var, check.id_var, check.conf_field))
                table.insert(lines, string.format("        return nil, {error_msg = \"wrong %s\" }", check.conf_field))
                table.insert(lines, "    end")
            elseif check.type == "reference_check" then
                table.insert(lines, string.format("    if conf.%s and not opts.skip_references_check then", check.field))
                table.insert(lines, string.format("        local key = \"/%s/\" .. conf.%s", check.resource, check.field))
                table.insert(lines, "        local res, err = core.etcd.get(key)")
                table.insert(lines, "        if not res then")
                table.insert(lines, string.format("            return nil, {error_msg = \"failed to fetch %s info by %s id [\" .. conf.%s .. \"]: \"",
                    check.resource_desc or check.resource, check.resource_desc or check.resource, check.field))
                table.insert(lines, "                                  .. err}")
                table.insert(lines, "        end")
                table.insert(lines, "        if res.status ~= 200 then")
                table.insert(lines, string.format("            return nil, {error_msg = \"failed to fetch %s info by %s id [\" .. conf.%s .. \"], \"",
                    check.resource_desc or check.resource, check.resource_desc or check.resource, check.field))
                table.insert(lines, "                                  .. \"response code: \" .. res.status}")
                table.insert(lines, "        end")
                table.insert(lines, "    end")
            elseif check.type == "sub_schema" then
                table.insert(lines, string.format("    local %s_conf = conf.%s", check.field, check.field))
                table.insert(lines, string.format("    if %s_conf then", check.field))
                table.insert(lines, string.format("        local ok, err = %s.check_%s_conf(%s_conf)", 
                    check.module, check.field, check.field))
                table.insert(lines, "        if not ok then")
                table.insert(lines, "            return nil, {error_msg = err}")
                table.insert(lines, "        end")
                table.insert(lines, "    end")
            elseif check.type == "custom" then
                for _, line in ipairs(check.code) do
                    table.insert(lines, line)
                end
            end
        end
        
        if def.return_id_field then
            table.insert(lines, string.format("    return conf.%s", def.return_id_field))
        else
            table.insert(lines, "    return true")
        end
        table.insert(lines, "end")
        table.insert(lines, "")
    end
    
    if def.encrypt_conf then
        table.insert(lines, "local function encrypt_conf(id, conf)")
        for _, enc in ipairs(def.encrypt_conf) do
            table.insert(lines, string.format("    %s", enc))
        end
        table.insert(lines, "end")
        table.insert(lines, "")
    end
    
    if def.delete_checker then
        table.insert(lines, "local function delete_checker(id)")
        for _, line in ipairs(def.delete_checker) do
            table.insert(lines, line)
        end
        table.insert(lines, "    return nil, nil")
        table.insert(lines, "end")
        table.insert(lines, "")
    end
    
    table.insert(lines, "return resource.new({")
    table.insert(lines, string.format("    name = \"%s\",", def.name))
    table.insert(lines, string.format("    kind = \"%s\",", def.kind))
    table.insert(lines, string.format("    schema = %s,", def.schema))
    
    if def.check_conf then
        table.insert(lines, "    checker = check_conf,")
    end
    if def.encrypt_conf then
        table.insert(lines, "    encrypt_conf = encrypt_conf,")
    end
    if def.unsupported_methods then
        table.insert(lines, string.format("    unsupported_methods = %s,", table_to_lua(def.unsupported_methods, 2)))
    end
    if def.list_filter_fields then
        table.insert(lines, string.format("    list_filter_fields = %s,", table_to_lua(def.list_filter_fields, 2)))
    end
    if def.delete_checker then
        table.insert(lines, "    delete_checker = delete_checker,")
    end
    
    if def.custom_new_params then
        for k, v in pairs(def.custom_new_params) do
            if type(v) == "string" then
                table.insert(lines, string.format("    %s = %s,", k, v))
            else
                table.insert(lines, string.format("    %s = %s,", k, table_to_lua(v, 2)))
            end
        end
    end
    
    table.insert(lines, "})")
    
    return table.concat(lines, "\n")
end

return _M
