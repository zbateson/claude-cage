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

# Extract includeIf config paths that match the current directory
# Parses system and user config files for includeIf entries, resolves ~ in paths,
# and outputs matching config file paths (one per line)
# Args: $1 = current directory (resolved), $2... = config files to scan
resolve_include_if() {
    local current_dir="$1"
    shift
    local scan_files_str=""
    for f in "$@"; do
        [ -f "$f" ] || continue
        if [ -n "$scan_files_str" ]; then
            scan_files_str="$scan_files_str|$f"
        else
            scan_files_str="$f"
        fi
    done
    [ -z "$scan_files_str" ] && return

    lua - "$current_dir" "$scan_files_str" <<'LUAEOF' 2>/dev/null
local cwd = arg[1] or ""
local files_str = arg[2] or ""
local home = os.getenv("HOME") or ""

local function expand_tilde(path)
    return path:gsub("^~", home)
end

local include_configs = {}

local function handler(tbl)
    if tbl.includeIf and type(tbl.includeIf) == "table" then
        for _, rule in ipairs(tbl.includeIf) do
            local dir = rule.dir
            local config = rule.config
            if dir and config then
                dir = expand_tilde(dir)
                config = expand_tilde(config)
                -- Normalize: ensure dir ends with /
                if not dir:match("/$") then dir = dir .. "/" end
                local cwd_check = cwd .. "/"
                if cwd_check:sub(1, #dir) == dir then
                    table.insert(include_configs, config)
                end
            end
        end
    end
end

local safe_env = {
    claude_cage = handler,
    pairs = pairs, ipairs = ipairs,
    type = type, tostring = tostring, tonumber = tonumber,
}

for filepath in string.gmatch(files_str, "[^|]+") do
    local f = io.open(filepath, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local chunk = load(content, "@" .. filepath, "t", safe_env)
        if chunk then pcall(chunk) end
    end
end

for _, path in ipairs(include_configs) do
    print(path)
end
LUAEOF
}

# Parse config files using Lua
# Args: $1 = derived_project, $2 = config_root_real, $3... = config file paths
# Sets all cfg_* variables
parse_config() {
    local derived_project="$1"
    local config_root_real="$2"
    shift 2
    local config_files_str=""
    for cfg in "$@"; do
        if [ -n "$config_files_str" ]; then
            config_files_str="$config_files_str|$cfg"
        else
            config_files_str="$cfg"
        fi
    done

    local lua_output
    lua_output=$(lua - "$derived_project" "$config_root_real" "$config_files_str" <<'LUAEOF' 2>&1
local derived_project = arg[1] or ""
local config_root = arg[2] or ""
local config_files_str = arg[3] or ""

-- Split config files string into table
local config_files = {}
for path in string.gmatch(config_files_str, "[^|]+") do
    table.insert(config_files, path)
end

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
        elseif k == "carry" and type(v) == "table" then
            result.carry = result.carry or {}
            for _, item in ipairs(v) do
                table.insert(result.carry, item)
            end
        elseif k == "additionalMounts" and type(v) == "table" then
            result.additionalMounts = result.additionalMounts or {}
            for _, item in ipairs(v) do
                table.insert(result.additionalMounts, item)
            end
        elseif k == "docker" and type(v) == "table" then
            result.docker = result.docker or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.docker[subkey] = result.docker[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.docker[subkey], item)
                    end
                else
                    result.docker[subkey] = subval
                end
            end
        elseif k == "bwrap" and type(v) == "table" then
            result.bwrap = result.bwrap or {}
            for subkey, subval in pairs(v) do
                if type(subval) == "table" then
                    result.bwrap[subkey] = result.bwrap[subkey] or {}
                    for _, item in ipairs(subval) do
                        table.insert(result.bwrap[subkey], item)
                    end
                else
                    result.bwrap[subkey] = subval
                end
            end
        elseif k == "git" and type(v) == "table" then
            result.git = result.git or {}
            for subkey, subval in pairs(v) do
                result.git[subkey] = subval
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

-- Track excludes by source for display (dynamic based on loaded files)
local sources = {}

local function get_source_name(filepath)
    if filepath:match("/etc/claude%-cage%.conf$") then
        return "system"
    elseif filepath:match("%.config/claude%-cage/config$") then
        return "user"
    else
        -- For includeIf and local configs, show the parent directory name
        local basename = filepath:match("([^/]+)/[^/]+$") or filepath
        return basename
    end
end

local function track_excludes(filepath, cfg)
    if cfg.exclude and type(cfg.exclude) == "table" then
        local name = get_source_name(filepath)
        if not sources[filepath] then
            sources[filepath] = { name = name, path = filepath, excludes = {} }
        end
        for _, item in ipairs(cfg.exclude) do
            table.insert(sources[filepath].excludes, item)
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

-- Load configs in order (system, user, includeIf matches, local)
for _, filepath in ipairs(config_files) do
    local f = io.open(filepath, "r")
    if f then
        f:close()
        local before_count = #configs
        local success, err = safe_load_config(filepath, claude_cage)
        if not success then
            io.stderr:write("Error loading config: " .. filepath .. "\n" .. tostring(err) .. "\n")
            os.exit(1)
        end
        for i = before_count + 1, #configs do
            track_excludes(filepath, configs[i])
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

-- Set defaults (source is always config_root/CWD)
local source = config_root
local showBanner = config.showBanner
if showBanner == nil then showBanner = true end
local networkMode = config.networkMode or "disabled"
local mode = config.mode or "bwrap"
local autoSync = config.autoSync
if autoSync == nil then autoSync = true end
local syncActiveBranch = config.syncActiveBranch
if syncActiveBranch == nil then syncActiveBranch = false end
local bringDirty = config.bringDirty
if bringDirty == nil then bringDirty = false end
local isolated = config.isolated
if isolated == nil then isolated = false end
local hideConfirmationPrompt = config.hideConfirmationPrompt
if hideConfirmationPrompt == nil then hideConfirmationPrompt = false end
local createCagedDir = config.createCagedDir
if createCagedDir == nil then createCagedDir = false end

-- Non-git directory support (nil = unset, true = allow, false = disallow)
local allowNonGit = config.allowNonGit
-- Keep as nil if not set (special handling for "unset" state)

-- Direct mount mode - mount source directly without git clone/sync
local directMount = config.directMount
if directMount == nil then directMount = false end

-- Git options
local git = config.git or {}
local git_blockForceAdd = git.blockForceAdd
if git_blockForceAdd == nil then git_blockForceAdd = true end
local git_historyDepth = git.historyDepth
if git_historyDepth == nil then git_historyDepth = 50 end
local git_defaultBranch = git.defaultBranch or "auto"
local git_scoped = git.scoped
if git_scoped == nil then git_scoped = false end

-- Docker options
local docker = config.docker or {}
local docker_image = docker.image or "node:lts-slim"
local docker_packages = docker.packages

-- Launch command (what to run inside sandbox)
local launch = config.launch or "claude"

-- Get exclude list
local exclude = config.exclude or {}

-- Network rules
local allow = config.allow or {}
local block = config.block or {}

local function array_to_string(arr)
    if not arr or #arr == 0 then return "EMPTY" end
    return table.concat(arr, "|")
end

-- Output (pipe-delimited) - removed mounted from first line
print(source .. "|" .. tostring(showBanner))
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
print(tostring(autoSync))
print(tostring(syncActiveBranch))
print(tostring(bringDirty))
print(tostring(isolated))
print(docker_image)
print(launch)
print(tostring(hideConfirmationPrompt))
print(tostring(createCagedDir))
-- allowNonGit: nil = "unset", true = "true", false = "false"
if allowNonGit == nil then
    print("unset")
else
    print(tostring(allowNonGit))
end
print(tostring(directMount))
-- docker.packages: nil = use defaults, empty table = no packages, otherwise list
if docker_packages == nil then
    print("curl|iputils-ping")
elseif #docker_packages == 0 then
    print("EMPTY")
else
    print(array_to_string(docker_packages))
end

print(tostring(git_blockForceAdd))
print(tostring(git_historyDepth))
print(git_defaultBranch)
print(tostring(git_scoped))
-- Process carry entries (like additionalMounts: string or table)
local carry = config.carry or {}
local carry_entries = {}
for _, entry in ipairs(carry) do
    local src, dest
    if type(entry) == "string" then
        src = entry
        dest = entry
    elseif type(entry) == "table" then
        src = entry.source or entry[1]
        dest = entry["as"] or entry.dest or src
    end
    if src then
        table.insert(carry_entries, src .. "|" .. dest)
    end
end
print(#carry_entries)
for _, entry in ipairs(carry_entries) do
    print(entry)
end

-- Output excludes by source for display (in config file order)
local display_lines = {}
for _, filepath in ipairs(config_files) do
    if sources[filepath] and #sources[filepath].excludes > 0 then
        table.insert(display_lines, sources[filepath].name .. "|" .. table.concat(sources[filepath].excludes, ", "))
    end
end
print(#display_lines)
for _, line in ipairs(display_lines) do
    print(line)
end

-- Bwrap options
local bwrap = config.bwrap or {}
local bwrap_system_mounts = bwrap.systemMounts or {"/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin"}
local bwrap_mask_paths = bwrap.maskPaths or {
    "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/sudoers.d",
    "/etc/ssl/private", "/etc/pki/tls/private", "/etc/pki/nssdb",
    "/etc/letsencrypt", "/etc/security",
    "/etc/openvpn", "/etc/wireguard", "/etc/ipsec.d", "/etc/ipsec.secrets",
    "/etc/NetworkManager/system-connections", "/etc/wpa_supplicant", "/etc/ppp",
    "/etc/docker", "/etc/samba", "/etc/krb5.keytab", "/etc/machine-id",
}
print(#bwrap_system_mounts)
for _, entry in ipairs(bwrap_system_mounts) do print(entry) end
print(#bwrap_mask_paths)
for _, entry in ipairs(bwrap_mask_paths) do print(entry) end

-- Process additionalMounts
local mounts = config.additionalMounts or {}
local mount_entries = {}
for _, entry in ipairs(mounts) do
    local src, dest, mmode
    if type(entry) == "string" then
        src = entry
        dest = entry
        mmode = "ro"
    elseif type(entry) == "table" then
        src = entry.source or entry[1]
        dest = entry["as"] or entry.dest or src
        mmode = entry.mode or "ro"
    end
    if src then
        table.insert(mount_entries, src .. "|" .. dest .. "|" .. mmode)
    end
end
print(#mount_entries)
for _, entry in ipairs(mount_entries) do
    print(entry)
end
LUAEOF
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
        IFS='|' read -r cfg_source cfg_showBanner
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
        read -r cfg_autoSync
        read -r cfg_syncActiveBranch
        read -r cfg_bringDirty
        read -r cfg_isolated
        read -r cfg_docker_image
        read -r cfg_launch
        read -r cfg_hideConfirmationPrompt
        read -r cfg_createCagedDir
        read -r cfg_allowNonGit
        read -r cfg_directMount
        read -r cfg_docker_packages
        read -r cfg_git_blockForceAdd
        read -r cfg_git_historyDepth
        read -r cfg_git_defaultBranch
        read -r cfg_git_scoped
        read -r cfg_carry_count
        cfg_carry_entries=()
        for ((i=0; i<cfg_carry_count; i++)); do
            read -r line
            cfg_carry_entries+=("$line")
        done
        read -r cfg_display_line_count
        cfg_display_lines=()
        for ((i=0; i<cfg_display_line_count; i++)); do
            read -r line
            cfg_display_lines+=("$line")
        done
        read -r cfg_bwrap_system_mount_count
        cfg_bwrap_system_mounts=()
        for ((i=0; i<cfg_bwrap_system_mount_count; i++)); do
            read -r line
            cfg_bwrap_system_mounts+=("$line")
        done
        read -r cfg_bwrap_mask_path_count
        cfg_bwrap_mask_paths=()
        for ((i=0; i<cfg_bwrap_mask_path_count; i++)); do
            read -r line
            cfg_bwrap_mask_paths+=("$line")
        done
        read -r cfg_mount_count
        cfg_mounts=()
        for ((i=0; i<cfg_mount_count; i++)); do
            read -r line
            cfg_mounts+=("$line")
        done
    } <<< "$lua_output"

    # Replace EMPTY placeholder with empty string
    # Use || true to prevent set -e from triggering on false conditions
    [ "$cfg_exclude" = "EMPTY" ] && cfg_exclude="" || true
    [ "$cfg_allow_domains" = "EMPTY" ] && cfg_allow_domains="" || true
    [ "$cfg_allow_ips" = "EMPTY" ] && cfg_allow_ips="" || true
    [ "$cfg_allow_networks" = "EMPTY" ] && cfg_allow_networks="" || true
    [ "$cfg_block_domains" = "EMPTY" ] && cfg_block_domains="" || true
    [ "$cfg_block_ips" = "EMPTY" ] && cfg_block_ips="" || true
    [ "$cfg_block_networks" = "EMPTY" ] && cfg_block_networks="" || true
    [ "$cfg_docker_packages" = "EMPTY" ] && cfg_docker_packages="" || true

    # Build cfg_carry string from entries (^-separated, each entry is source|dest)
    cfg_carry=""
    if [ ${#cfg_carry_entries[@]} -gt 0 ]; then
        cfg_carry=$(IFS='^'; echo "${cfg_carry_entries[*]}")
    fi
}

# Initialize config from current directory
init_config() {
    check_lua

    original_user="${SUDO_USER:-$USER}"
    system_config="/etc/claude-cage.conf"
    user_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-cage"
    user_config="$user_config_dir/config"

    # Config root is always CWD
    config_root=$(pwd)
    config_root_real=$(realpath "$config_root")
    derived_project=$(basename "$config_root_real")

    # Local config at git root (not CWD, not ancestors beyond git root)
    local_config=""
    local git_root
    git_root=$(git -C "$config_root_real" rev-parse --show-toplevel 2>/dev/null) || true
    if [ -n "$git_root" ] && [ -f "$git_root/.claude-cage" ]; then
        local_config="$git_root/.claude-cage"
    fi

    # Resolve includeIf entries from system and user configs
    include_if_configs=()
    while IFS= read -r cfg; do
        [ -n "$cfg" ] && include_if_configs+=("$cfg")
    done < <(resolve_include_if "$config_root_real" "$system_config" "$user_config")

    if [ -z "$local_config" ]; then
        # No local config at git root - check if any config exists at all
        if [ ! -f "$system_config" ] && [ ! -f "$user_config" ] && [ ${#include_if_configs[@]} -eq 0 ]; then
            # No config anywhere - run the builder (if interactive)
            if [ -t 0 ]; then
                config_builder_run
                exit $?
            else
                echo "No config found. Run interactively to set one up, or create:"
                echo "  ~/.config/claude-cage/config (user-level)"
                echo "  .claude-cage (project-level, at the git root)"
                exit 1
            fi
        fi
    fi

    # Build config file list in order: system, user, includeIf matches, local
    config_files=("$system_config" "$user_config")
    for cfg in "${include_if_configs[@]}"; do
        config_files+=("$cfg")
    done
    if [ -n "$local_config" ]; then
        config_files+=("$local_config")
    fi

    parse_config "$derived_project" "$config_root_real" "${config_files[@]}"
}
