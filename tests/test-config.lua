#!/usr/bin/env lua
-- Test config loading hierarchy with new exclude/block/allow object syntax

-- Function to merge two tables (later overrides earlier)
local function merge_config(base, override)
    local result = {}

    -- Copy base config
    for k, v in pairs(base) do
        result[k] = v
    end

    -- Override with new values
    for k, v in pairs(override) do
        if k == "exclude" and type(v) == "table" then
            -- Merge exclude sub-fields (path, name, belowPath, regex)
            result.exclude = result.exclude or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.exclude[subkey] = result.exclude[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.exclude[subkey], item)
                    end
                end
            end
        elseif k == "block" and type(v) == "table" then
            -- Merge block sub-fields (domains, ips, networks)
            result.block = result.block or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.block[subkey] = result.block[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.block[subkey], item)
                    end
                end
            end
        elseif k == "allow" and type(v) == "table" then
            -- Merge allow sub-fields (domains, ips, networks)
            result.allow = result.allow or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.allow[subkey] = result.allow[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.allow[subkey], item)
                    end
                end
            end
        else
            -- Override value
            result[k] = v
        end
    end

    return result
end

-- Define a handler for claude_cage function
local configs = {}
function claude_cage(tbl)
    table.insert(configs, tbl)
end

-- Simulate system config
print("Loading system config...")
claude_cage {
    user = "claude",
    syncPrepend = "claude-",
    exclude = {
        path = { "target", ".git" },
        name = { "*.tmp" },
        belowPath = { "node_modules" }
    },
    networkMode = "blocklist",
    block = {
        ips = { "169.254.169.254" },
        networks = { "10.0.0.0/8" }
    }
}

-- Simulate user config
print("Loading user config...")
claude_cage {
    syncPrepend = "my-claude-",
    exclude = {
        regex = { ".*\\.log$" },
        name = { ".DS_Store" }
    },
    block = {
        networks = { "192.168.0.0/16" }
    },
    allow = {
        ips = { "127.0.0.1:5432" }
    }
}

-- Simulate local config
print("Loading local config...")
claude_cage {
    source = "my-project",
    exclude = {
        path = { "secrets.txt" },
        name = { "*.swp" }
    },
    mounted = "my-project",
    allow = {
        ips = { "127.0.0.1:3000" },
        domains = { "github.com:443" }
    }
}

-- Merge all configs
local config = {}
for _, cfg in ipairs(configs) do
    config = merge_config(config, cfg)
end

-- Display merged config
print("\nMerged configuration:")
print("  user: " .. (config.user or "nil"))
print("  source: " .. (config.source or "nil"))
print("  syncPrepend: " .. (config.syncPrepend or "nil"))
print("  mounted: " .. (config.mounted or "nil"))
print("  networkMode: " .. (config.networkMode or "nil"))

local function print_array(name, arr)
    if arr and #arr > 0 then
        print("  " .. name .. ":")
        for _, item in ipairs(arr) do
            print("    - " .. item)
        end
    end
end

local exclude = config.exclude or {}
print_array("exclude.path", exclude.path)
print_array("exclude.name", exclude.name)
print_array("exclude.regex", exclude.regex)
print_array("exclude.belowPath", exclude.belowPath)

local block = config.block or {}
print_array("block.ips", block.ips)
print_array("block.networks", block.networks)
print_array("block.domains", block.domains)

local allow = config.allow or {}
print_array("allow.ips", allow.ips)
print_array("allow.networks", allow.networks)
print_array("allow.domains", allow.domains)

-- Test expected results
print("\n=== Test Results ===")
assert(config.user == "claude", "user should be 'claude'")
assert(config.source == "my-project", "source should be 'my-project'")
assert(config.syncPrepend == "my-claude-", "syncPrepend should be 'my-claude-' (overridden by user)")
assert(config.mounted == "my-project", "mounted should be 'my-project'")
assert(config.networkMode == "blocklist", "networkMode should be 'blocklist'")

-- Test exclude merging
assert(#exclude.path == 3, "exclude.path should have 3 items (merged from system and local)")
assert(#exclude.name == 3, "exclude.name should have 3 items (merged from all configs)")
assert(#exclude.regex == 1, "exclude.regex should have 1 item (from user)")
assert(#exclude.belowPath == 1, "exclude.belowPath should have 1 item (from system)")

-- Test block merging
assert(#block.ips == 1, "block.ips should have 1 item (from system)")
assert(#block.networks == 2, "block.networks should have 2 items (merged from system and user)")

-- Test allow merging
assert(#allow.ips == 2, "allow.ips should have 2 items (merged from user and local)")
assert(#allow.domains == 1, "allow.domains should have 1 item (from local)")

print("✓ All tests passed!")
