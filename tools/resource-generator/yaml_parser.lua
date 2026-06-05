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
-- A minimal YAML-like parser for the resource generator specs.
-- Supports: scalars, lists, nested mappings, multi-line block scalars (|).
-- This is NOT a full YAML parser — it handles the subset used by specs.
--
local type = type
local string = string
local table = table
local ipairs = ipairs
local tonumber = tonumber

local _M = {}


local function trim(s)
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end


local function get_indent(line)
    local spaces = line:match("^(%s*)")
    return spaces:len()
end


local function parse_value(val)
    val = trim(val)
    if val == "" then
        return nil
    end
    if val == "true" then
        return true
    end
    if val == "false" then
        return false
    end
    if val == "null" or val == "~" then
        return nil
    end
    local num = tonumber(val)
    if num then
        return num
    end
    -- strip quotes
    if (val:sub(1, 1) == '"' and val:sub(-1) == '"') or
       (val:sub(1, 1) == "'" and val:sub(-1) == "'") then
        return val:sub(2, -2)
    end
    return val
end


function _M.parse(yaml_text)
    local lines = {}
    for line in yaml_text:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local root = {}
    local stack = { { node = root, indent = -1 } }
    local current_list = nil
    local current_list_key = nil
    local current_list_indent = -1
    local block_scalar_key = nil
    local block_scalar_indent = -1
    local block_scalar_lines = nil

    local function flush_block_scalar()
        if block_scalar_key and block_scalar_lines then
            local parent = stack[#stack].node
            local val = table.concat(block_scalar_lines, "\n")
            if parent[block_scalar_key] and type(parent[block_scalar_key]) == "table" then
                parent[block_scalar_key].code = val
            else
                parent[block_scalar_key] = val
            end
        end
        block_scalar_key = nil
        block_scalar_lines = nil
        block_scalar_indent = -1
    end

    local function find_parent_for_indent(indent)
        while #stack > 1 and stack[#stack].indent >= indent do
            table.remove(stack)
        end
        return stack[#stack].node
    end

    for _, line in ipairs(lines) do
        -- skip empty lines and comments
        if trim(line) ~= "" and not trim(line):match("^#") then
            local indent = get_indent(line)
            local content = trim(line)

            -- flush block scalar if indent decreased
            if block_scalar_key and indent <= block_scalar_indent then
                flush_block_scalar()
            end

            -- list item
            if content:match("^- ") then
                local item_val = trim(content:sub(3))

                -- check if this is a list of mappings (key: value after -)
                if item_val:match("^[a-zA-Z_].*:") then
                    -- start of a list item that is a mapping
                    if not current_list or indent ~= current_list_indent then
                        current_list = {}
                        current_list_indent = indent
                        local parent = find_parent_for_indent(indent)
                        -- find the key this list belongs to
                        for i = #stack, 1, -1 do
                            if stack[i].indent < indent then
                                -- the key was set at this level
                                break
                            end
                        end
                        -- attach to the most recent parent
                        local pnode = stack[#stack].node
                        -- find which key this list belongs to by scanning backwards
                        -- we need to find the key that was last set at a lower indent
                        -- For simplicity, we store it via a marker
                        if current_list_key and pnode[current_list_key] == nil then
                            pnode[current_list_key] = current_list
                        elseif current_list_key and type(pnode[current_list_key]) ~= "table" then
                            pnode[current_list_key] = current_list
                        end
                    end

                    local item_map = {}
                    table.insert(current_list, item_map)
                    -- push item_map onto stack
                    table.insert(stack, { node = item_map, indent = indent + 2 })

                    -- parse the first key:value of the item
                    local k, v = item_val:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*:%s*(.*)")
                    if k then
                        if v and v ~= "" then
                            -- check for block scalar
                            if v == "|" or v:match("^|%s*$") then
                                block_scalar_key = k
                                block_scalar_indent = indent + 4
                                block_scalar_lines = {}
                                item_map[k] = {}
                            else
                                item_map[k] = parse_value(v)
                            end
                        else
                            item_map[k] = nil
                        end
                    end
                else
                    -- simple list item
                    if not current_list or indent ~= current_list_indent then
                        current_list = {}
                        current_list_indent = indent
                        local pnode = stack[#stack].node
                        if current_list_key then
                            pnode[current_list_key] = current_list
                        end
                    end
                    table.insert(current_list, parse_value(item_val))
                end
            elseif content:match("^[a-zA-Z_][a-zA-Z0-9_]*%s*:") then
                -- key: value mapping
                if current_list and indent > current_list_indent then
                    -- this is a key inside a list item mapping
                    local item = current_list[#current_list]
                    if type(item) == "table" then
                        local k, v = content:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*:%s*(.*)")
                        if k then
                            if v and v ~= "" then
                                if v == "|" or v:match("^|%s*$") then
                                    block_scalar_key = k
                                    block_scalar_indent = indent + 2
                                    block_scalar_lines = {}
                                    item[k] = {}
                                else
                                    item[k] = parse_value(v)
                                end
                            end
                        end
                    end
                else
                    current_list = nil
                    current_list_key = nil
                    flush_block_scalar()

                    local k, v = content:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*:%s*(.*)")
                    if k then
                        local parent = find_parent_for_indent(indent)

                        if v and v ~= "" then
                            if v == "|" or v:match("^|%s*$") then
                                block_scalar_key = k
                                block_scalar_indent = indent + 2
                                block_scalar_lines = {}
                                parent[k] = {}
                            else
                                parent[k] = parse_value(v)
                                current_list_key = k
                            end
                        else
                            -- value is a nested mapping or list
                            local child = {}
                            parent[k] = child
                            table.insert(stack, { node = child, indent = indent })
                            current_list_key = k
                        end
                    end
                end
            end

            -- block scalar content line
            if block_scalar_key and indent > block_scalar_indent - 2 and
               not content:match("^[a-zA-Z_][a-zA-Z0-9_]*%s*:") and
               not content:match("^- ") then
                table.insert(block_scalar_lines, line:sub(block_scalar_indent + 1))
            end
        end
    end

    flush_block_scalar()
    return root
end


return _M
