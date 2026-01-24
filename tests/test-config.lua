#!/usr/bin/env lua
-- Test config loading hierarchy

-- Function to merge two tables (later overrides earlier)
local function merge_config(base, override)
    local result = {}

    -- Copy base config
    for k, v in pairs(base) do
        result[k] = v
    end

    -- Override with new values
    for k, v in pairs(override) do
        local array_fields = {"excludeName", "excludePath", "excludeRegex", "belowPath"}
        local is_array_field = false
        for _, field in ipairs(array_fields) do
            if k == field then
                is_array_field = true
                break
            end
        end

        if is_array_field and type(v) == "table" then
            -- Merge array fields
            result[k] = result[k] or {}
            for _, item in ipairs(v) do
                table.insert(result[k], item)
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
    excludePath = { "target", ".git" },
    excludeName = { "*.tmp" },
    belowPath = { "node_modules" }
}

-- Simulate user config
print("Loading user config...")
claude_cage {
    syncPrepend = "my-claude-",
    excludeRegex = { ".*\\.log$" },
    excludeName = { ".DS_Store" }
}

-- Simulate local config
print("Loading local config...")
claude_cage {
    source = "my-project",
    excludePath = { "secrets.txt" },
    excludeName = { "*.swp" },
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

print_array("excludePath", config.excludePath)
print_array("excludeName", config.excludeName)
print_array("excludeRegex", config.excludeRegex)
print_array("belowPath", config.belowPath)

-- Test expected results
print("\n=== Test Results ===")
assert(config.user == "claude", "user should be 'claude'")
assert(config.source == "my-project", "source should be 'my-project'")
assert(config.syncPrepend == "my-claude-", "syncPrepend should be 'my-claude-' (overridden by user)")
assert(config.mounted == "my-project", "mounted should be 'my-project'")
assert(#config.excludePath == 3, "excludePath should have 3 items (merged from system and local)")
assert(#config.excludeName == 3, "excludeName should have 3 items (merged from all configs)")
assert(#config.excludeRegex == 1, "excludeRegex should have 1 item (from user)")
assert(#config.belowPath == 1, "belowPath should have 1 item (from system)")
print("✓ All tests passed!")
