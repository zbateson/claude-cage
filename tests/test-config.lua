#!/usr/bin/env lua
-- Test config loading hierarchy with new exclude object syntax

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
    }
}

-- Simulate user config
print("Loading user config...")
claude_cage {
    syncPrepend = "my-claude-",
    exclude = {
        regex = { ".*\\.log$" },
        name = { ".DS_Store" }
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
    mounted = "my-project"
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

-- Test expected results
print("\n=== Test Results ===")
assert(config.user == "claude", "user should be 'claude'")
assert(config.source == "my-project", "source should be 'my-project'")
assert(config.syncPrepend == "my-claude-", "syncPrepend should be 'my-claude-' (overridden by user)")
assert(config.mounted == "my-project", "mounted should be 'my-project'")
assert(#exclude.path == 3, "exclude.path should have 3 items (merged from system and local)")
assert(#exclude.name == 3, "exclude.name should have 3 items (merged from all configs)")
assert(#exclude.regex == 1, "exclude.regex should have 1 item (from user)")
assert(#exclude.belowPath == 1, "exclude.belowPath should have 1 item (from system)")
print("✓ All tests passed!")
