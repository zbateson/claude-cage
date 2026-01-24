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
        if k == "exclude" and type(v) == "table" then
            -- Merge exclude arrays
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
    syncprepend = "claude-",
    exclude = { "target", ".git", "node_modules" }
}

-- Simulate user config
print("Loading user config...")
claude_cage {
    syncprepend = "my-claude-",
    exclude = { "*.log" }
}

-- Simulate local config
print("Loading local config...")
claude_cage {
    source = "my-project",
    exclude = { "secrets.txt" },
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
print("  syncprepend: " .. (config.syncprepend or "nil"))
print("  mounted: " .. (config.mounted or "nil"))
print("  exclude:")
if config.exclude then
    for _, item in ipairs(config.exclude) do
        print("    - " .. item)
    end
end

-- Test expected results
print("\n=== Test Results ===")
assert(config.user == "claude", "user should be 'claude'")
assert(config.source == "my-project", "source should be 'my-project'")
assert(config.syncprepend == "my-claude-", "syncprepend should be 'my-claude-' (overridden by user)")
assert(config.mounted == "my-project", "mounted should be 'my-project'")
assert(#config.exclude == 5, "exclude should have 5 items (merged from all configs)")
print("✓ All tests passed!")
