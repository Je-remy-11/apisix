#!/usr/bin/env python3
import sys
import yaml

def generate_lua(spec):
    lines = []
    lines.append("""--
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
--""")

    for imp in spec.get("imports", []):
        if "field" in imp:
            lines.append(f'local {imp["local_name"]} = require("{imp["require"]}").{imp["field"]}')
        else:
            lines.append(f'local {imp["local_name"]} = require("{imp["require"]}")')
    
    lines.append("")

    check_conf = spec.get("check_conf")
    if check_conf:
        id_name = check_conf.get("id_name", "id")
        lines.append(f"local function check_conf({id_name}, conf, need_id, schema, opts)")
        lines.append("    opts = opts or {}")
        if check_conf.get("schema_check", True):
            lines.append("""    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end""")
        
        custom_logic = check_conf.get("custom_logic")
        if custom_logic:
            lines.append("")
            for line in custom_logic.rstrip('\n').split('\n'):
                lines.append(f"    {line}" if line else "")
        
        references = check_conf.get("references", [])
        for ref in references:
            field = ref["field"]
            resource = ref["resource"]
            name = ref.get("name", resource)
            lines.append(f"""
    if conf.{field} and not opts.skip_references_check then
        local key = "/{resource}/" .. conf.{field}
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {{error_msg = "failed to fetch {name} info by "
                                     .. "{name} id [" .. conf.{field} .. "]: "
                                     .. err}}
        end

        if res.status ~= 200 then
            return nil, {{error_msg = "failed to fetch {name} info by "
                                     .. "{name} id [" .. conf.{field} .. "], "
                                     .. "response code: " .. res.status}}
        end
    end""")
        
        ret_val = check_conf.get("return_value", "true")
        lines.append(f"\n    return {ret_val}")
        lines.append("end\n")

    encrypt_conf = spec.get("encrypt_conf")
    if encrypt_conf:
        args = ", ".join(encrypt_conf.get("args", ["id", "conf"]))
        lines.append(f"local function encrypt_conf({args})")
        custom_logic = encrypt_conf.get("custom_logic", "")
        for line in custom_logic.rstrip('\n').split('\n'):
            lines.append(f"    {line}" if line else "")
        lines.append("end\n")

    lines.append("return resource.new({")
    lines.append(f'    name = "{spec["name"]}",')
    lines.append(f'    kind = "{spec["kind"]}",')
    lines.append(f'    schema = {spec["schema"]},')
    if check_conf:
        lines.append('    checker = check_conf,')
    if encrypt_conf:
        lines.append('    encrypt_conf = encrypt_conf,')
    
    unsupported_methods = spec.get("unsupported_methods")
    if unsupported_methods:
        methods = ", ".join(f'"{m}"' for m in unsupported_methods)
        lines.append(f'    unsupported_methods = {{{methods}}}')
    
    lines.append("})")
    
    return "\n".join(lines) + "\n"

def main():
    if len(sys.argv) < 3:
        print("Usage: resource_generator.py <spec.yaml> <out.lua>")
        sys.exit(1)
        
    spec_path = sys.argv[1]
    out_path = sys.argv[2]
    
    with open(spec_path, 'r') as f:
        spec = yaml.safe_load(f)
            
    code = generate_lua(spec)
    
    with open(out_path, 'w') as f:
        f.write(code)
    print(f"Generated {out_path}")

if __name__ == "__main__":
    main()
