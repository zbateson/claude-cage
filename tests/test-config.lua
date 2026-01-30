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
        elseif k == "cageLocal" and type(v) == "table" then
            -- Merge cageLocal sub-fields (path, name, belowPath, regex)
            result.cageLocal = result.cageLocal or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.cageLocal[subkey] = result.cageLocal[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.cageLocal[subkey], item)
                    end
                end
            end
        elseif k == "homeConfigSync" and type(v) == "table" then
            -- Merge homeConfigSync arrays (each entry is a string or table)
            result.homeConfigSync = result.homeConfigSync or {}
            for _, item in ipairs(v) do
                table.insert(result.homeConfigSync, item)
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
    cageLocal = {
        name = { ".bashrc" }
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
    cageLocal = {
        name = { ".profile" }
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

local cageLocal = config.cageLocal or {}
print_array("cageLocal.path", cageLocal.path)
print_array("cageLocal.name", cageLocal.name)
print_array("cageLocal.regex", cageLocal.regex)
print_array("cageLocal.belowPath", cageLocal.belowPath)

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

-- Test cageLocal merging
assert(#cageLocal.name == 2, "cageLocal.name should have 2 items (merged from system and local)")

-- Test block merging
assert(#block.ips == 1, "block.ips should have 1 item (from system)")
assert(#block.networks == 2, "block.networks should have 2 items (merged from system and user)")

-- Test allow merging
assert(#allow.ips == 2, "allow.ips should have 2 items (merged from user and local)")
assert(#allow.domains == 1, "allow.domains should have 1 item (from local)")

-- ============================================================================
-- Test homeConfigSync parsing (new syntax)
-- ============================================================================
print("\n=== Testing homeConfigSync parsing ===")

-- Reset configs for homeConfigSync test
configs = {}
claude_cage {
    homeConfigSync = {
        -- Simple string: init mode
        ".gitconfig",

        -- Table syntax with modes
        { path = ".claude", mode = "sync",
          exclude = { path = { "settings.json" }, belowPath = { "logs" } } },
        { path = ".claude.json", mode = "sync" },
        { path = ".npmrc", mode = "copy" },
        { path = ".some-dir", mode = "link" },
        { path = ".config/foo", destination = ".foo", mode = "init" },
    }
}

-- Process homeConfigSync
local homeConfigSync = configs[1].homeConfigSync

-- Helper to parse entry
local function parse_entry(entry)
    local path, dest, mode, exclude_path, exclude_belowPath = "", "", "init", "", ""

    if type(entry) == "string" then
        path = entry
        dest = entry
    elseif type(entry) == "table" and entry.path then
        path = entry.path
        dest = entry.destination or entry.path
        mode = entry.mode or "init"
        if entry.exclude then
            if entry.exclude.path then
                exclude_path = table.concat(entry.exclude.path, "|")
            end
            if entry.exclude.belowPath then
                exclude_belowPath = table.concat(entry.exclude.belowPath, "|")
            end
        end
    end

    return path, dest, mode, exclude_path, exclude_belowPath
end

-- Test simple string
local path, dest, mode = parse_entry(homeConfigSync[1])
assert(path == ".gitconfig", "Simple string: path should be .gitconfig")
assert(dest == ".gitconfig", "Simple string: dest should be .gitconfig")
assert(mode == "init", "Simple string: mode should be init")
print("  ✓ Simple string parsing works")

-- Test table syntax with sync mode and excludes
local exclude_path, exclude_belowPath
path, dest, mode, exclude_path, exclude_belowPath = parse_entry(homeConfigSync[2])
assert(path == ".claude", "Table sync: path should be .claude")
assert(dest == ".claude", "Table sync: dest should be .claude")
assert(mode == "sync", "Table sync: mode should be sync")
assert(exclude_path == "settings.json", "Table sync: exclude_path should be settings.json")
assert(exclude_belowPath == "logs", "Table sync: exclude_belowPath should be logs")
print("  ✓ Table syntax with sync mode and excludes works")

-- Test copy mode
path, dest, mode = parse_entry(homeConfigSync[4])
assert(path == ".npmrc", "Copy mode: path should be .npmrc")
assert(mode == "copy", "Copy mode: mode should be copy")
print("  ✓ Copy mode works")

-- Test link mode
path, dest, mode = parse_entry(homeConfigSync[5])
assert(path == ".some-dir", "Link mode: path should be .some-dir")
assert(mode == "link", "Link mode: mode should be link")
print("  ✓ Link mode works")

-- Test destination override
path, dest, mode = parse_entry(homeConfigSync[6])
assert(path == ".config/foo", "Dest override: path should be .config/foo")
assert(dest == ".foo", "Dest override: dest should be .foo")
assert(mode == "init", "Dest override: mode should be init")
print("  ✓ Destination override works")

-- ============================================================================
-- Test homeConfigSync merging
-- ============================================================================
print("\n=== Testing homeConfigSync merging ===")

-- Reset configs for merge test
configs = {}

-- Simulate user config
claude_cage {
    homeConfigSync = {
        ".gitconfig",
        { path = ".claude", mode = "sync" },
    }
}

-- Simulate project config
claude_cage {
    homeConfigSync = {
        ".npmrc",
        { path = ".project-specific", mode = "copy" },
    }
}

-- Merge configs
local merged = {}
for _, cfg in ipairs(configs) do
    merged = merge_config(merged, cfg)
end

-- Test that homeConfigSync entries are merged (not overwritten)
local mergedHomeConfigSync = merged.homeConfigSync or {}
assert(#mergedHomeConfigSync == 4, "homeConfigSync should have 4 items (merged from both configs), got " .. #mergedHomeConfigSync)

-- Verify order (user config entries come first)
local first_path = type(mergedHomeConfigSync[1]) == "string" and mergedHomeConfigSync[1] or mergedHomeConfigSync[1].path
assert(first_path == ".gitconfig", "First entry should be .gitconfig from user config")

local third_path = type(mergedHomeConfigSync[3]) == "string" and mergedHomeConfigSync[3] or mergedHomeConfigSync[3].path
assert(third_path == ".npmrc", "Third entry should be .npmrc from project config")

print("  ✓ homeConfigSync entries are merged across configs")

print("\n✓ All tests passed!")
