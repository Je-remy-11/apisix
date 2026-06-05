# APISIX Admin Resource Code Generator

## Overview

A code generator for Apache APISIX admin resource modules. Instead of manually writing repetitive CRUD boilerplate for each resource (routes, services, upstreams, consumers, etc.), you define a **Lua DSL spec** and the generator produces a complete, production-ready `xxx.lua` module.

## Motivation

APISIX admin resources share a common pattern:

```lua
return resource.new({
    name = "xxx",
    kind = "xxx",
    schema = core.schema.xxx,
    checker = check_conf,          -- custom validation
    encrypt_conf = encrypt_conf,   -- encryption hook
    unsupported_methods = {...},   -- route constraints
    delete_checker = delete_checker, -- reference guard
    list_filter_fields = {...},    -- query filters
})
```

Each resource module differs only in:
1. The **schema** it validates against
2. The **checker** function (custom business logic)
3. The **encrypt_conf** function (sensitive field handling)
4. **unsupported_methods** (HTTP method restrictions)
5. **delete_checker** (reference integrity guards)
6. **list_filter_fields** (query parameter filters)

The generator abstracts these differences into a declarative spec.

## Quick Start

```bash
# Generate a resource module from a spec
lua tools/resource-generator/generator.lua \
    tools/resource-generator/specs/consumers.lua \
    apisix/admin/consumers.lua

# Omit output path to print to stdout
lua tools/resource-generator/generator.lua \
    tools/resource-generator/specs/consumers.lua
```

## Spec File Format (Lua DSL)

A spec file is a Lua script that returns a configuration table:

```lua
return {
    resource = { ... },
    schema = "...",
    unsupported_methods = { ... },
    checker = { ... },
    encrypt_conf = { ... },
    delete_checker = { ... },
    list_filter_fields = { ... },
    extra_imports = { ... },
}
```

### Field Reference

#### `resource` (required)

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `name` | string | etcd key prefix and module name | `"consumers"` |
| `kind` | string | Human-readable singular name for error messages | `"consumer"` |

#### `schema` (required)

String referencing the JSON Schema in `core.schema.*`. The generator emits `schema = core.schema.<value>`.

```lua
schema = "consumer"  -- generates: schema = core.schema.consumer
```

#### `unsupported_methods` (optional)

Array of HTTP methods to disable. Each causes the corresponding handler to return 405.

```lua
unsupported_methods = { "post", "patch" }
```

#### `checker` (optional)

Defines the `check_conf` function. Three modes:

##### Mode: `"builtin"` (default)

Simple schema validation only. No custom logic needed.

```lua
checker = {
    mode = "builtin",
    return_value = "need_id and id or true",  -- default
}
```

##### Mode: `"custom"`

Full custom checker. You provide the entire function body.

```lua
checker = {
    mode = "custom",
    code = [[
        local ok, err = apisix_ssl.check_ssl_conf(false, conf)
        if not ok then
            return nil, {error_msg = err}
        end
        return need_id and id or true
    ]],
}
```

##### Mode: `"composed"` (recommended for most resources)

Starts with the builtin schema check, then appends extra validation steps.

```lua
checker = {
    mode = "composed",

    extra_checks = {
        {
            name = "username_consistency",
            code = [[
                if id and id ~= conf.username then
                    return nil, {error_msg = "wrong username"}
                end
            ]],
        },
        {
            name = "group_id_reference",
            requires = {
                { module = "apisix.admin.plugins", as = "admin_plugins" },
            },
            code = [[
                if conf.group_id and not opts.skip_references_check then
                    local key = "/consumer_groups/" .. conf.group_id
                    local res, err = core.etcd.get(key)
                    if not res then
                        return nil, {error_msg = "failed to fetch: " .. err}
                    end
                    if res.status ~= 200 then
                        return nil, {error_msg = "not found, code: " .. res.status}
                    end
                end
            ]],
        },
    },

    return_value = "conf.username",
}
```

**Checker function parameters:**
- `id` — the resource ID from the URL path
- `conf` — the configuration table from the request body
- `need_id` — boolean, whether an ID is required for this operation
- `schema` — the JSON schema reference
- `opts` — options table (e.g., `opts.skip_references_check`)

**Return convention:**
- On failure: `return nil, {error_msg = "description"}`
- On success: `return <return_value>` (typically `id`, `true`, or `conf.username`)

#### `encrypt_conf` (optional)

Defines the `encrypt_conf` function for sensitive field encryption.

##### Mode: `"plugins"` (most common)

Encrypts all plugin configurations.

```lua
encrypt_conf = {
    mode = "plugins",
    schema_type = "TYPE_CONSUMER",  -- optional: TYPE_ROUTE (default), TYPE_CONSUMER, TYPE_METADATA
    local_name = "plugins_encrypt_conf",  -- the local variable name for the import
}
```

##### Mode: `"custom"`

Full custom encryption logic.

```lua
encrypt_conf = {
    mode = "custom",
    code = [[
        apisix_upstream.encrypt_conf(conf.upstream)
        plugins_encrypt_conf(conf.plugins)
    ]],
}
```

#### `delete_checker` (optional)

Defines a pre-delete reference integrity check.

##### Mode: `"builtin_reference"`

Scans another resource type for references to the ID being deleted.

```lua
delete_checker = {
    mode = "builtin_reference",
    reference_resource = "consumers",      -- resource to scan
    reference_field = "group_id",          -- field to match against the ID
    get_function = "consumers",            -- function to get the resource list
    error_msg_template = "can not delete this consumer group, consumer [{ref_id}] is still using it now",
}
```

Placeholders in `error_msg_template`:
- `{ref_id}` — replaced with the referencing resource's ID

##### Mode: `"custom"`

Full custom delete checker.

```lua
delete_checker = {
    mode = "custom",
    code = [[
        local routes, routes_ver = get_routes()
        if routes_ver and routes then
            for _, route in ipairs(routes) do
                if type(route) == "table" and route.value
                   and route.value.plugin_config_id
                   and tostring(route.value.plugin_config_id) == id then
                    return 400, {error_msg = "can not delete this plugin config, route [" .. route.value.id .. "] is still using it now"}
                end
            end
        end
        return nil, nil
    ]],
}
```

#### `list_filter_fields` (optional)

Fields that can be used as query parameters to filter list results.

```lua
list_filter_fields = { "service_id", "upstream_id" }
```

#### `extra_imports` (optional)

Additional Lua modules to import at the top of the generated file.

```lua
extra_imports = {
    -- Simple require with local name
    { module = "apisix.admin.plugins", as = "plugins" },

    -- Import a specific member function
    { module = "apisix.admin.plugins", alias = "plugins_encrypt_conf", member = "encrypt_conf" },

    -- Import a value from a module (e.g., a function)
    { module = "apisix.consumer", member = "consumers" },
}
```

## Architecture

```
tools/resource-generator/
├── generator.lua          # Main generator script
├── yaml_parser.lua        # (legacy) YAML parser — use Lua DSL specs instead
├── specs/                 # Resource specification files
│   ├── consumers.lua
│   ├── consumer_groups.lua
│   ├── global_rules.lua
│   └── plugin_metadata.lua
└── README.md              # This file
```

## Generated Code Structure

The generator produces a file with this structure:

```lua
-- License header
-- Standard imports (core, resource) + extra_imports

-- check_conf function (from checker spec)

-- encrypt_conf function (from encrypt_conf spec, if defined)

-- delete_checker function (from delete_checker spec, if defined)

return resource.new({
    name = "...",
    kind = "...",
    schema = core.schema.<schema>,
    checker = check_conf,
    encrypt_conf = encrypt_conf,       -- if defined
    unsupported_methods = {...},       -- if defined
    list_filter_fields = {...},        -- if defined
    delete_checker = delete_checker,   -- if defined
})
```

## Migration Guide

To migrate an existing resource module to the generator:

1. **Identify the pattern** — look at the `resource.new()` call and the helper functions
2. **Create a spec file** — map each component to the DSL fields
3. **Run the generator** — compare output with the original
4. **Replace the original** — once output matches, replace the file

### Example: Migrating `consumers.lua`

Original file has:
- `check_conf` with username check, plugin validation, group_id reference
- `encrypt_conf` for plugin encryption
- `unsupported_methods = {"post", "patch"}`

Corresponding spec: see `specs/consumers.lua`

## Extending the Generator

To add new generation capabilities:

1. Add a new mode to the relevant dispatcher function (e.g., `gen_checker`)
2. Add a new template function (e.g., `gen_checker_<new_mode>`)
3. Update the `generate()` assembly function if needed
4. Add a spec example demonstrating the new feature

## Testing

Run the generator for each spec and diff against the original:

```bash
lua tools/resource-generator/generator.lua \
    tools/resource-generator/specs/consumers.lua \
    /tmp/consumers_generated.lua

diff -u apisix/admin/consumers.lua /tmp/consumers_generated.lua
```

Minor whitespace differences are expected. The logic should be identical.
