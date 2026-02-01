# ============================================================================
# Configuration parsing
# ============================================================================

# Check if lua is available
check_lua() {
    if ! command -v lua >/dev/null 2>&1; then
        echo "Now listen carefully. We got a problem here."
        echo "I need lua installed on this bird."
        echo "Can't do nothin' without it."
        exit 1
    fi
}


# Parse config files using Lua
# Sets all cfg_* variables
parse_config() {
    local system_config="$1"
    local user_config="$2"
    local local_config="$3"
    local derived_project="$4"
    local config_root_real="$5"

    local lua_output
    lua_output=$(lua - "$derived_project" "$config_root_real" <<EOF 2>&1
local derived_project = arg[1] or ""
local config_root = arg[2] or ""

-- Merge two tables (later overrides earlier)
local function merge_config(base, override)
    local result = {}
    for k, v in pairs(base) do
        result[k] = v
    end
    for k, v in pairs(override) do
        if k == "exclude" and type(v) == "table" then
            -- Merge exclude arrays
            result.exclude = result.exclude or {}
            for _, item in ipairs(v) do
                table.insert(result.exclude, item)
            end
        elseif k == "block" and type(v) == "table" then
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
            result.allow = result.allow or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.allow[subkey] = result.allow[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.allow[subkey], item)
                    end
                end
            end
        elseif k == "additionalMounts" and type(v) == "table" then
            result.additionalMounts = result.additionalMounts or {}
            for _, item in ipairs(v) do
                table.insert(result.additionalMounts, item)
            end
        else
            result[k] = v
        end
    end
    return result
end

-- Handler for claude_cage function
local configs = {}
function claude_cage(tbl)
    table.insert(configs, tbl)
end

-- Track excludes by source for display
local sources = {
    { name = "system", path = "$system_config", excludes = {} },
    { name = "user", path = "$user_config", excludes = {} },
    { name = "local", path = "$local_config", excludes = {} }
}

local function track_excludes(source_entry, cfg)
    if cfg.exclude and type(cfg.exclude) == "table" then
        for _, item in ipairs(cfg.exclude) do
            table.insert(source_entry.excludes, item)
        end
    end
end

-- Safe config loader
local function safe_load_config(filepath, config_handler)
    local f = io.open(filepath, "r")
    if not f then return false, "Cannot open file" end
    local content = f:read("*all")
    f:close()

    local safe_env = {
        claude_cage = config_handler,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
    }

    local chunk, parse_err = load(content, "@" .. filepath, "t", safe_env)
    if not chunk then
        return false, "Parse error: " .. tostring(parse_err)
    end

    local success, exec_err = pcall(chunk)
    if not success then
        return false, "Execution error: " .. tostring(exec_err)
    end

    return true, nil
end

-- Load configs in priority order
local config_files = {
    { idx = 1, path = "$system_config" },
    { idx = 2, path = "$user_config" },
    { idx = 3, path = "$local_config" }
}

for _, cf in ipairs(config_files) do
    local f = io.open(cf.path, "r")
    if f then
        f:close()
        local before_count = #configs
        local success, err = safe_load_config(cf.path, claude_cage)
        if not success then
            io.stderr:write("Error loading config: " .. cf.path .. "\n" .. tostring(err) .. "\n")
            os.exit(1)
        end
        for i = before_count + 1, #configs do
            track_excludes(sources[cf.idx], configs[i])
        end
    end
end

-- Merge all configs
local config = {}
for _, cfg in ipairs(configs) do
    config = merge_config(config, cfg)
end

-- Project name is the current directory name
local project = derived_project

-- Set defaults
local source = config.source or ""
local mounted = config.mounted or ""
local showBanner = config.showBanner
if showBanner == nil then showBanner = true end
local networkMode = config.networkMode or "disabled"
local mode = config.mode or "bwrap"
local autoMerge = config.autoMerge
if autoMerge == nil then autoMerge = false end
local isolated = config.isolated
if isolated == nil then isolated = false end

-- Docker options
local docker = config.docker or {}
local docker_image = docker.image or "node:lts-slim"
local docker_container = docker.container or ""

-- Source defaults to current directory
if source == "" then
    source = config_root
end

if mounted == "" then
    mounted = project ~= "" and project or "project"
end

-- Get exclude list
local exclude = config.exclude or {}

-- Network rules
local allow = config.allow or {}
local block = config.block or {}

local function array_to_string(arr)
    if not arr or #arr == 0 then return "EMPTY" end
    return table.concat(arr, "|")
end

-- Output (pipe-delimited)
print(source .. "|" .. mounted .. "|" .. tostring(showBanner))
print(array_to_string(exclude))
print(networkMode)
print(array_to_string(allow.domains))
print(array_to_string(allow.ips))
print(array_to_string(allow.networks))
print(array_to_string(block.domains))
print(array_to_string(block.ips))
print(array_to_string(block.networks))
print(project)
print(config_root)
print(mode)
print(tostring(autoMerge))
print(tostring(isolated))
print(docker_image)
print(docker_container)

-- Output excludes by source for display
local display_lines = {}
for _, src in ipairs(sources) do
    if #src.excludes > 0 then
        table.insert(display_lines, src.name .. "|" .. table.concat(src.excludes, ", "))
    end
end
print(#display_lines)
for _, line in ipairs(display_lines) do
    print(line)
end

-- Process additionalMounts
local mounts = config.additionalMounts or {}
local mount_entries = {}
for _, entry in ipairs(mounts) do
    local source, dest
    if type(entry) == "string" then
        source = entry
        dest = entry
    elseif type(entry) == "table" then
        source = entry.source or entry[1]
        dest = entry["as"] or entry.dest or source
    end
    if source then
        table.insert(mount_entries, source .. "|" .. dest)
    end
end
print(#mount_entries)
for _, entry in ipairs(mount_entries) do
    print(entry)
end
EOF
)
    local lua_exit_code=$?

    if [ $lua_exit_code -ne 0 ]; then
        echo ""
        echo "============================================"
        echo "Somethin' went wrong with the config files"
        echo "============================================"
        echo ""
        echo "$lua_output"
        echo ""
        echo "Now I want you to fix that and we'll try this again."
        exit 1
    fi

    # Parse the lua output
    {
        IFS='|' read -r cfg_source cfg_mounted cfg_showBanner
        read -r cfg_exclude
        read -r cfg_networkMode
        read -r cfg_allow_domains
        read -r cfg_allow_ips
        read -r cfg_allow_networks
        read -r cfg_block_domains
        read -r cfg_block_ips
        read -r cfg_block_networks
        read -r cfg_project
        read -r cfg_config_root
        read -r cfg_mode
        read -r cfg_autoMerge
        read -r cfg_isolated
        read -r cfg_docker_image
        read -r cfg_docker_container
        read -r cfg_display_line_count
        cfg_display_lines=()
        for ((i=0; i<cfg_display_line_count; i++)); do
            read -r line
            cfg_display_lines+=("$line")
        done
        read -r cfg_mount_count
        cfg_mounts=()
        for ((i=0; i<cfg_mount_count; i++)); do
            read -r line
            cfg_mounts+=("$line")
        done
    } <<< "$lua_output"

    # Replace EMPTY placeholder with empty string
    [ "$cfg_exclude" = "EMPTY" ] && cfg_exclude=""
    [ "$cfg_allow_domains" = "EMPTY" ] && cfg_allow_domains=""
    [ "$cfg_allow_ips" = "EMPTY" ] && cfg_allow_ips=""
    [ "$cfg_allow_networks" = "EMPTY" ] && cfg_allow_networks=""
    [ "$cfg_block_domains" = "EMPTY" ] && cfg_block_domains=""
    [ "$cfg_block_ips" = "EMPTY" ] && cfg_block_ips=""
    [ "$cfg_block_networks" = "EMPTY" ] && cfg_block_networks=""
}

# Initialize config from current directory
init_config() {
    check_lua

    original_user="${SUDO_USER:-$USER}"
    system_config="/etc/claude-cage.conf"
    user_config="/home/${original_user}/.config/claude-cage/config"

    # Parse --config flag
    explicit_config=""
    config_next=false
    for arg in "$@"; do
        if [ "$config_next" = true ]; then
            explicit_config="$arg"
            config_next=false
        elif [ "$arg" = "--config" ]; then
            config_next=true
        fi
    done

    # Determine config file location
    if [ -n "$explicit_config" ]; then
        if [ ! -f "$explicit_config" ]; then
            echo "Sorry friend, that config file '$explicit_config' ain't there."
            exit 1
        fi
        local_config="$explicit_config"
        config_root=$(dirname "$(realpath "$explicit_config")")
    else
        config_root=$(pwd)
        local_config="$config_root/.claude-cage"
        if [ ! -f "$local_config" ]; then
            echo "Can't find a '.claude-cage' config in the current directory."
            exit 1
        fi
    fi

    config_root_real=$(realpath "$config_root")
    derived_project=$(basename "$config_root_real")

    parse_config "$system_config" "$user_config" "$local_config" \
                 "$derived_project" "$config_root_real"
}
