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
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local resource = require("apisix.admin.resource")
local plugins = require("apisix.admin.plugins")
local apisix_upstream = require("apisix.upstream")
local plugins_encrypt_conf = require("apisix.admin.plugins").encrypt_conf
local yaml = require("lyaml")
local io_open = io.open
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local require = require
local setmetatable = setmetatable
local string_gmatch = string.gmatch
local tostring = tostring
local type = type
local loadstring = loadstring


local _M = {}


local function split_path(path)
    local parts = {}
    for part in string_gmatch(path, "[^.]+") do
        parts[#parts + 1] = part
    end
    return parts
end


local function read_path(obj, path)
    if not path or path == "" then
        return obj
    end

    local current = obj
    for _, part in ipairs(split_path(path)) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[part]
        if current == nil then
            return nil
        end
    end

    return current
end


local function resolve_ref(scope, ref)
    local current = scope
    for _, part in ipairs(split_path(ref)) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[part]
        if current == nil then
            return nil
        end
    end

    return current
end


local function render_template(template, ctx)
    return (template:gsub("%${([%w_]+)}", function(key)
        local value = ctx[key]
        if value == nil then
            return ""
        end
        return tostring(value)
    end))
end


local function normalize_template_ctx(ctx, step, value, res, err)
    return {
        id = ctx.id,
        kind = ctx.spec.kind,
        name = ctx.spec.name,
        need_id = ctx.need_id,
        value = value,
        err = err,
        status = res and res.status,
        field = step.field,
    }
end


local function resolve_handler(handler, scope)
    if type(handler) == "function" then
        return handler
    end

    if type(handler) ~= "string" then
        return nil
    end

    local resolved = resolve_ref(scope, handler)
    if resolved then
        return resolved
    end

    local module_name, func_name = handler:match("^(.+)%.([^.]+)$")
    if not module_name then
        return nil
    end

    local ok, mod = pcall(require, module_name)
    if not ok or type(mod) ~= "table" then
        return nil
    end

    return mod[func_name]
end


local function resolve_scalar(value, scope)
    if type(value) ~= "table" then
        return value
    end

    if value["$ref"] then
        return resolve_ref(scope, value["$ref"])
    end

    local is_array = true
    local index = 1
    for key, _ in pairs(value) do
        if key ~= index then
            is_array = false
            break
        end
        index = index + 1
    end

    local out = {}
    if is_array then
        for i, item in ipairs(value) do
            out[i] = resolve_scalar(item, scope)
        end
        return out
    end

    for key, item in pairs(value) do
        out[key] = resolve_scalar(item, scope)
    end
    return out
end


local builtin_checker_steps = {}
local builtin_encrypt_steps = {}


builtin_checker_steps.schema = function(ctx, step)
    local ok, err = core.schema.check(ctx.schema, ctx.conf)
    if not ok then
        return nil, {error_msg = (step.error_prefix or "invalid configuration: ") .. err}
    end

    return true
end


builtin_checker_steps.id_matches_field = function(ctx, step)
    local field_value = read_path(ctx.conf, step.field)
    if ctx.id and ctx.id ~= field_value then
        return nil, {error_msg = step.error_msg or ("wrong " .. step.field)}
    end

    return true
end


builtin_checker_steps.plugins_schema = function(ctx, step)
    local plugins_conf = read_path(ctx.conf, step.field or "plugins")
    if not plugins_conf then
        return true
    end

    local ok, err = plugins.check_schema(plugins_conf, step.schema_type)
    if not ok then
        return nil, {error_msg = (step.error_prefix or "invalid plugins configuration: ") .. err}
    end

    return true
end


builtin_checker_steps.reference_exists = function(ctx, step)
    local value = read_path(ctx.conf, step.field)
    if value == nil then
        return true
    end

    if step.skip_option and ctx.opts[step.skip_option] then
        return true
    end

    local key = render_template(step.key, normalize_template_ctx(ctx, step, value))
    local res, err = core.etcd.get(key)
    if not res then
        return nil, {error_msg = render_template(step.fetch_error, normalize_template_ctx(ctx, step, value, nil, err))}
    end

    if res.status ~= 200 then
        return nil, {error_msg = render_template(step.status_error,
            normalize_template_ctx(ctx, step, value, res))}
    end

    return true
end


builtin_checker_steps.upstream_conf = function(ctx, step)
    local upstream_conf = read_path(ctx.conf, step.field or "upstream")
    if not upstream_conf then
        return true
    end

    local ok, err = apisix_upstream.check_upstream_conf(upstream_conf)
    if not ok then
        return nil, {error_msg = err}
    end

    return true
end


builtin_checker_steps.script_lua_object = function(ctx, step)
    local script = read_path(ctx.conf, step.field or "script")
    if not script then
        return true
    end

    local obj, err = loadstring(script)
    if not obj then
        return nil, {error_msg = "failed to load '" .. (step.field or "script") .. "' string: " .. err}
    end

    if type(obj()) ~= "table" then
        return nil, {error_msg = "'" .. (step.field or "script") .. "' should be a Lua object"}
    end

    return true
end


builtin_checker_steps.auth_plugins_only = function(ctx, step)
    local plugins_conf = read_path(ctx.conf, step.field or "plugins")
    if not plugins_conf then
        return true
    end

    for name, _ in pairs(plugins_conf) do
        local plugin_obj = plugin.get(name)
        if not plugin_obj then
            return nil, {error_msg = "unknown plugin " .. name}
        end

        if plugin_obj.type ~= (step.plugin_type or "auth") then
            return nil, {error_msg = step.error_msg or ("only supports "
                .. (step.plugin_type or "auth") .. " type plugins in consumer credential")}
        end
    end

    return true
end


builtin_checker_steps.custom = function(ctx, step)
    local handler = assert(resolve_handler(step.handler, ctx.scope), "invalid custom checker handler")
    return handler(ctx, step)
end


builtin_encrypt_steps.plugins_encrypt = function(ctx, step)
    local plugins_conf = read_path(ctx.conf, step.field or "plugins")
    if plugins_conf then
        plugins_encrypt_conf(plugins_conf, step.schema_type)
    end
end


builtin_encrypt_steps.upstream_encrypt = function(ctx, step)
    local upstream_conf = read_path(ctx.conf, step.field or "upstream")
    if upstream_conf then
        apisix_upstream.encrypt_conf(upstream_conf)
    end
end


builtin_encrypt_steps.custom = function(ctx, step)
    local handler = assert(resolve_handler(step.handler, ctx.scope), "invalid custom encrypt handler")
    handler(ctx, step)
end


local function compile_checker(spec, scope)
    if type(spec) == "function" then
        return spec
    end

    local steps = spec and spec.steps or {}
    local success = spec and spec.success or true

    return function(id, conf, need_id, schema, opts)
        local ctx = {
            id = id,
            conf = conf,
            need_id = need_id,
            schema = schema,
            opts = opts or {},
            spec = spec.__resource_spec,
            scope = scope,
        }

        for _, step in ipairs(steps) do
            local runner = builtin_checker_steps[step.use]
            assert(runner, "unsupported checker step: " .. tostring(step.use))
            local ok, err = runner(ctx, step)
            if not ok then
                return ok, err
            end
        end

        if type(success) == "table" and success.use == "field" then
            return read_path(conf, success.field)
        end

        if type(success) == "function" then
            return success(ctx)
        end

        if success == nil then
            return true
        end

        return success
    end
end


local function compile_encryptor(spec, scope)
    if type(spec) == "function" then
        return spec
    end

    local steps = spec and spec.steps or {}
    if #steps == 0 then
        return nil
    end

    return function(id, conf)
        local ctx = {
            id = id,
            conf = conf,
            spec = spec.__resource_spec,
            scope = scope,
        }

        for _, step in ipairs(steps) do
            local runner = builtin_encrypt_steps[step.use]
            assert(runner, "unsupported encrypt step: " .. tostring(step.use))
            runner(ctx, step)
        end
    end
end


local function compile_spec(spec, scope)
    local compiled = {
        name = spec.name,
        kind = spec.kind,
        schema = spec.schema,
        unsupported_methods = spec.unsupported_methods,
        list_filter_fields = spec.list_filter_fields,
    }

    if spec.get_resource_etcd_key then
        compiled.get_resource_etcd_key = resolve_handler(spec.get_resource_etcd_key, scope)
    end

    if spec.delete_checker then
        compiled.delete_checker = resolve_handler(spec.delete_checker, scope)
    end

    if spec.checker or spec.check_conf then
        local checker_spec = spec.checker or spec.check_conf
        if type(checker_spec) == "table" then
            checker_spec.__resource_spec = spec
        end
        compiled.checker = compile_checker(checker_spec, scope)
    end

    if spec.encrypt_conf then
        local encrypt_spec = spec.encrypt_conf
        if type(encrypt_spec) == "table" then
            encrypt_spec.__resource_spec = spec
        end
        compiled.encrypt_conf = compile_encryptor(encrypt_spec, scope)
    end

    return compiled
end


local function build_scope(spec)
    local scope = {
        core = core,
    }

    local imports = spec.imports or {}
    for alias, module_name in pairs(imports) do
        scope[alias] = require(module_name)
    end

    return scope
end


function _M.from_table(spec)
    local scope = build_scope(spec)
    local normalized = spec
    if spec.imports then
        normalized = resolve_scalar(spec, scope)
    end

    local merged_scope = setmetatable(scope, {
        __index = _G,
    })
    return resource.new(compile_spec(normalized, merged_scope))
end


function _M.from_yaml(yaml_text)
    local spec = yaml.load(yaml_text, { all = false })
    return _M.from_table(spec)
end


function _M.from_yaml_file(file_path)
    local file, err = io_open(file_path, "r")
    if not file then
        return nil, err
    end

    local yaml_text = file:read("*a")
    file:close()
    return _M.from_yaml(yaml_text)
end


function _M.new(spec)
    if type(spec) == "string" then
        return _M.from_yaml(spec)
    end

    return _M.from_table(spec)
end


return _M
