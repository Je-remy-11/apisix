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
-- APISIX Admin Resource Code Generator
-- =====================================
-- Reads a Lua DSL spec and generates a complete admin resource module.
--
-- Usage:
--   lua generator.lua <spec_file.lua> [output_file.lua]
--
-- If output_file is omitted, writes to stdout.
--
-- Spec file format (Lua DSL):
--   return {
--       resource = { name = "consumers", kind = "consumer" },
--       schema   = "consumer",
--       unsupported_methods = { "post", "patch" },
--       checker  = { ... },
--       encrypt_conf = { ... },
--       delete_checker = { ... },
--       list_filter_fields = { "service_id" },
--       extra_imports = { ... },
--   }
--
local arg = arg
local io = io
local string = string
local table = table
local type = type
local ipairs = ipairs
local tostring = tostring
local assert = assert
local error = error

-- ============================================================================
-- Spec loader
-- ============================================================================
local function load_spec(path)
    local f, err = io.open(path, "r")
    if not f then
        error("cannot open spec file: " .. tostring(err))
    end
    local content = f:read("*all")
    f:close()

    local fn, err = loadstring(content, "@" .. path)
    if not fn then
        error("invalid spec file: " .. tostring(err))
    end
    local spec = fn()
    if type(spec) ~= "table" then
        error("spec file must return a table")
    end
    return spec
end

-- ============================================================================
-- Template helpers
-- ============================================================================
local function indent_lines(text, spaces)
    local pad = string.rep(" ", spaces)
    local result = {}
    for line in text:gmatch("[^\n]*\n?") do
        if line ~= "" and line ~= "\n" then
            table.insert(result, pad .. line)
        elseif line == "\n" then
            table.insert(result, "")
        end
    end
    return table.concat(result, "\n")
end

local function dedent(text)
    local leading = text:match("^(\n*)(%s*)")
    if not leading then return text end
    local spaces = leading:len()
    if spaces == 0 then return text end
    local pattern = "\n" .. string.rep(" ", spaces)
    return text:gsub(pattern, "\n"):gsub("^" .. string.rep(" ", spaces), "")
end

-- ============================================================================
-- Code generation sections
-- ============================================================================

-- License header
local function gen_license()
    return [[--
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
--]]
end

-- Standard imports
local function gen_imports(spec)
    local lines = {}
    table.insert(lines, 'local core = require("apisix.core")')
    table.insert(lines, 'local resource = require("apisix.admin.resource")')

    if spec.extra_imports then
        for _, imp in ipairs(spec.extra_imports) do
            if imp.member then
                table.insert(lines,
                    string.format('local %s = require("%s").%s',
                        imp.alias or imp.as, imp.module, imp.member))
            elseif imp.as then
                table.insert(lines,
                    string.format('local %s = require("%s")', imp.as, imp.module))
            else
                table.insert(lines,
                    string.format('require("%s")', imp.module))
            end
        end
    end

    table.insert(lines, "")
    return table.concat(lines, "\n")
end

-- Checker function: mode = "builtin"
local function gen_checker_builtin(spec)
    local id_return = spec.checker.return_value or "need_id and id or true"
    return string.format([[
local function check_conf(id, conf, need_id, schema, opts)
    opts = opts or {}
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    return %s
end
]], id_return)
end

-- Checker function: mode = "custom"
local function gen_checker_custom(spec)
    local code = spec.checker.code
    if not code then
        error("checker.mode='custom' requires checker.code")
    end
    return string.format([[
local function check_conf(id, conf, need_id, schema, opts)
    opts = opts or {}
%s
end
]], indent_lines(dedent(code), 4))
end

-- Checker function: mode = "composed"
local function gen_checker_composed(spec)
    local parts = {}

    table.insert(parts, [[local function check_conf(id, conf, need_id, schema, opts)
    opts = opts or {}
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end
]])

    if spec.checker.extra_checks then
        for _, check in ipairs(spec.checker.extra_checks) do
            if check.requires then
                for _, req in ipairs(check.requires) do
                    -- require is already handled in imports; just inline the code
                end
            end
            if check.code then
                table.insert(parts, indent_lines(dedent(check.code), 4))
                table.insert(parts, "")
            end
        end
    end

    local ret = spec.checker.return_value or "true"
    table.insert(parts, string.format("    return %s\nend", ret))

    return table.concat(parts, "\n")
end

-- Checker function dispatcher
local function gen_checker(spec)
    if not spec.checker then
        return gen_checker_builtin(spec)
    end

    local mode = spec.checker.mode or "builtin"
    if mode == "builtin" then
        return gen_checker_builtin(spec)
    elseif mode == "custom" then
        return gen_checker_custom(spec)
    elseif mode == "composed" then
        return gen_checker_composed(spec)
    else
        error("unknown checker mode: " .. tostring(mode))
    end
end

-- Encrypt conf: mode = "plugins"
local function gen_encrypt_plugins(spec)
    local schema_type = ""
    if spec.encrypt_conf.schema_type then
        schema_type = ", core.schema." .. spec.encrypt_conf.schema_type
    end
    local local_name = spec.encrypt_conf.local_name or "plugins_encrypt_conf"
    return string.format([[
local function encrypt_conf(id, conf)
    %s(conf.plugins%s)
end
]], local_name, schema_type)
end

-- Encrypt conf: mode = "custom"
local function gen_encrypt_custom(spec)
    local code = spec.encrypt_conf.code
    if not code then
        error("encrypt_conf.mode='custom' requires encrypt_conf.code")
    end
    return string.format([[
local function encrypt_conf(id, conf)
%s
end
]], indent_lines(dedent(code), 4))
end

-- Encrypt conf dispatcher
local function gen_encrypt_conf(spec)
    if not spec.encrypt_conf then
        return ""
    end

    local mode = spec.encrypt_conf.mode or "plugins"
    if mode == "plugins" then
        return gen_encrypt_plugins(spec)
    elseif mode == "custom" then
        return gen_encrypt_custom(spec)
    else
        error("unknown encrypt_conf mode: " .. tostring(mode))
    end
end

-- Delete checker: mode = "builtin_reference"
local function gen_delete_checker_builtin(spec)
    local dc = spec.delete_checker
    local ref_resource = dc.reference_resource
    local ref_field = dc.reference_field or "id"
    local ref_kind = dc.reference_kind or ref_resource
    local err_msg = dc.error_msg_template or
        ("can not delete this " .. (spec.resource.kind or ref_resource) ..
         ", " .. ref_resource .. " [{ref_id}] is still using it now")

    local err_lua = err_msg:gsub("%{ref_id%}", '" .. %s.value.id .. "')
        :gsub("%{ref_kind%}", ref_kind)

    local get_fn = dc.get_function or ref_resource

    return string.format([[
local function delete_checker(id)
    local %s, %s_ver = %s()
    if %s_ver and %s then
        for _, item in ipairs(%s) do
            if type(item) == "table" and item.value
               and item.value.%s
               and tostring(item.value.%s) == id then
                return 400, {error_msg = "%s"}
            end
        end
    end

    return nil, nil
end
]], ref_resource, ref_resource, get_fn,
    ref_resource, ref_resource, ref_resource,
    ref_field, ref_field, err_lua)
end

-- Delete checker: mode = "custom"
local function gen_delete_checker_custom(spec)
    local code = spec.delete_checker.code
    if not code then
        error("delete_checker.mode='custom' requires delete_checker.code")
    end
    return string.format([[
local function delete_checker(id)
%s
end
]], indent_lines(dedent(code), 4))
end

-- Delete checker dispatcher
local function gen_delete_checker(spec)
    if not spec.delete_checker then
        return ""
    end

    local mode = spec.delete_checker.mode or "builtin_reference"
    if mode == "builtin_reference" then
        return gen_delete_checker_builtin(spec)
    elseif mode == "custom" then
        return gen_delete_checker_custom(spec)
    else
        error("unknown delete_checker mode: " .. tostring(mode))
    end
end

-- Unsupported methods array
local function gen_unsupported_methods(spec)
    if not spec.unsupported_methods or #spec.unsupported_methods == 0 then
        return ""
    end
    local items = {}
    for _, m in ipairs(spec.unsupported_methods) do
        table.insert(items, string.format('"%s"', m))
    end
    return string.format("    unsupported_methods = {%s},", table.concat(items, ", "))
end

-- List filter fields
local function gen_list_filter_fields(spec)
    if not spec.list_filter_fields or #spec.list_filter_fields == 0 then
        return ""
    end
    local items = {}
    for _, f in ipairs(spec.list_filter_fields) do
        table.insert(items, string.format('        %s = true,', f))
    end
    return string.format("    list_filter_fields = {\n%s\n    },", table.concat(items, "\n"))
end

-- ============================================================================
-- Main assembly
-- ============================================================================
local function generate(spec)
    local sections = {}

    -- 1. License header
    table.insert(sections, gen_license())
    table.insert(sections, "")

    -- 2. Imports
    table.insert(sections, gen_imports(spec))

    -- 3. Checker function
    table.insert(sections, gen_checker(spec))
    table.insert(sections, "")

    -- 4. Encrypt conf function
    local encrypt_code = gen_encrypt_conf(spec)
    if encrypt_code ~= "" then
        table.insert(sections, encrypt_code)
        table.insert(sections, "")
    end

    -- 5. Delete checker function
    local delete_code = gen_delete_checker(spec)
    if delete_code ~= "" then
        table.insert(sections, delete_code)
        table.insert(sections, "")
    end

    -- 6. resource.new() call
    local res = spec.resource
    local res_opts = {}
    table.insert(res_opts, string.format('    name = "%s",', res.name))
    table.insert(res_opts, string.format('    kind = "%s",', res.kind))
    table.insert(res_opts, string.format('    schema = core.schema.%s,', spec.schema))
    table.insert(res_opts, "    checker = check_conf,")

    if spec.encrypt_conf then
        table.insert(res_opts, "    encrypt_conf = encrypt_conf,")
    end

    local um = gen_unsupported_methods(spec)
    if um ~= "" then
        table.insert(res_opts, um)
    end

    local lff = gen_list_filter_fields(spec)
    if lff ~= "" then
        table.insert(res_opts, lff)
    end

    if spec.delete_checker then
        table.insert(res_opts, "    delete_checker = delete_checker")
    end

    local res_call = string.format("return resource.new({\n%s\n})",
        table.concat(res_opts, "\n"))
    table.insert(sections, res_call)

    return table.concat(sections, "\n") .. "\n"
end

-- ============================================================================
-- CLI entry point
-- ============================================================================
local function main()
    local spec_path = arg[1]
    local output_path = arg[2]

    if not spec_path then
        io.stderr:write("Usage: lua generator.lua <spec_file.lua> [output_file.lua]\n")
        os.exit(1)
    end

    local spec = load_spec(spec_path)
    local output = generate(spec)

    if output_path then
        local f, err = io.open(output_path, "w")
        if not f then
            io.stderr:write("cannot open output file: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        f:write(output)
        f:close()
        io.stderr:write("Generated: " .. output_path .. "\n")
    else
        io.write(output)
    end
end

main()

return { generate = generate, load_spec = load_spec }
