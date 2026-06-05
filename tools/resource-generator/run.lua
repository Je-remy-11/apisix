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

--- CLI entry point for the resource code generator.
--
-- Usage:
--   resty tools/resource-generator/run.lua specs/routes.lua --stdout
--   resty tools/resource-generator/run.lua specs/routes.yaml --output-dir ./apisix/admin
--
-- The generator reads the spec file (Lua table or YAML), produces the complete
-- admin resource module, and writes it to the target directory.

local gen = require("tools.resource-generator.generator")
gen.run_cli({...})