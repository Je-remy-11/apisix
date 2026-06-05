import json
import sys
import os

try:
    import yaml
    def load_file(path):
        with open(path, 'r') as f:
            if path.endswith('.yaml') or path.endswith('.yml'):
                return yaml.safe_load(f)
            return json.load(f)
except ImportError:
    def load_file(path):
        with open(path, 'r') as f:
            if path.endswith('.yaml') or path.endswith('.yml'):
                print("PyYAML not installed. Please install it to parse YAML, or use JSON.")
                sys.exit(1)
            return json.load(f)

def generate_lua(config):
    lines = []
    
    # Header
    lines.append('''--
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
--''')

    # Imports
    for imp in config.get('imports', []):
        req = f'require("{imp["require"]}")'
        if 'property' in imp:
            req += f'.{imp["property"]}'
        lines.append(f'local {imp["local_name"]} = {req}')
    lines.append('')

    # Checker
    checker = config.get('checker')
    if checker:
        args = checker.get('args', 'id, conf, need_id, schema, opts')
        lines.append(f'local function check_conf({args})')
        lines.append('    opts = opts or {}')
        lines.append('    local ok, err = core.schema.check(schema, conf)')
        lines.append('    if not ok then')
        lines.append('        return nil, {error_msg = "invalid configuration: " .. err}')
        lines.append('    end')
        lines.append('')
        
        custom_logic = checker.get('custom_logic', '').rstrip()
        if custom_logic:
            for line in custom_logic.split('\n'):
                # Handle indentation mapping based on existing code style
                if line.strip() == '':
                    lines.append('')
                else:
                    lines.append(f'    {line}')
            lines.append('')
        
        ret_val = checker.get('return_value', 'true')
        lines.append(f'    return {ret_val}')
        lines.append('end')
        lines.append('')

    # Encrypt Conf
    encrypt_conf = config.get('encrypt_conf')
    if encrypt_conf:
        args = encrypt_conf.get('args', 'id, conf')
        lines.append(f'local function encrypt_conf({args})')
        logic = encrypt_conf.get('custom_logic', '').rstrip()
        if logic:
            for line in logic.split('\n'):
                if line.strip() == '':
                    lines.append('')
                else:
                    lines.append(f'    {line}')
        lines.append('end')
        lines.append('')

    # Resource New
    lines.append('return resource.new({')
    lines.append(f'    name = "{config["name"]}",')
    lines.append(f'    kind = "{config["kind"]}",')
    lines.append(f'    schema = {config["schema"]},')
    
    if checker:
        lines.append('    checker = check_conf,')
    if encrypt_conf:
        lines.append('    encrypt_conf = encrypt_conf,')
        
    unsupported = config.get('unsupported_methods')
    if unsupported:
        methods = ', '.join([f'"{m}"' for m in unsupported])
        lines.append(f'    unsupported_methods = {{{methods}}}')
    else:
        # Remove trailing comma from last property if no unsupported_methods
        lines[-1] = lines[-1].rstrip(',')
        
    lines.append('})')
    
    return '\n'.join(lines) + '\n'

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python gen_admin_resource.py <input.yaml/json> <output.lua>")
        sys.exit(1)
        
    in_file = sys.argv[1]
    out_file = sys.argv[2]
    
    config = load_file(in_file)
    lua_code = generate_lua(config)
    
    with open(out_file, 'w') as f:
        f.write(lua_code)
    
    print(f"Generated {out_file} successfully.")