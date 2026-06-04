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
local resource_codegen = require("apisix.admin.resource_codegen")


return resource_codegen.new({
    name = "consumers",
    kind = "consumer",
    schema = core.schema.consumer,
    checker = {
        steps = {
            {
                use = "schema",
            },
            {
                use = "id_matches_field",
                field = "username",
                error_msg = "wrong username",
            },
            {
                use = "plugins_schema",
                field = "plugins",
                schema_type = core.schema.TYPE_CONSUMER,
            },
            {
                use = "reference_exists",
                field = "group_id",
                key = "/consumer_groups/${value}",
                skip_option = "skip_references_check",
                fetch_error = "failed to fetch consumer group info by consumer group id [${value}]: ${err}",
                status_error = "failed to fetch consumer group info by consumer group id [${value}], response code: ${status}",
            },
        },
        success = {
            use = "field",
            field = "username",
        },
    },
    encrypt_conf = {
        steps = {
            {
                use = "plugins_encrypt",
                field = "plugins",
                schema_type = core.schema.TYPE_CONSUMER,
            },
        },
    },
    unsupported_methods = {"post", "patch"},
})
