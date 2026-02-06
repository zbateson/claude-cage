# ============================================================================
# Shared mount logic for bwrap and docker
# ============================================================================

# Enumerate project directories for mounting
# Populates global arrays: CAGE_WORK_PROJECTS and CAGE_INTERMEDIARY_PROJECTS
# Each entry is "source_path|container_path"
#
# Arguments:
#   $1 - branch_work_root (per-branch: branches/<branch>/work)
#   $2 - intermediary_root (shared: intermediary/)
#   $3 - work_dir (current project)
#   $4 - intermediary_dir (current project bare repo, empty for non-git mode)
#   $5 - project_path (original path)
enumerate_projects() {
    local branch_work_root="$1"
    local intermediary_root="$2"
    local work_dir="$3"
    local intermediary_dir="$4"
    local project_path="$5"

    # Reset global arrays
    CAGE_WORK_PROJECTS=()
    CAGE_INTERMEDIARY_PROJECTS=()

    # Non-git mode or isolated mode: don't enumerate
    if [ -z "$intermediary_dir" ] || [ "$cfg_isolated" = "true" ]; then
        return
    fi

    # Always include the current project (needed for dry-run when dirs don't exist yet)
    CAGE_WORK_PROJECTS+=("$work_dir|$project_path")
    CAGE_INTERMEDIARY_PROJECTS+=("$intermediary_dir|$project_path")

    # Find any other project directories (those with .git) in branch work root
    while IFS= read -r -d '' git_dir; do
        local proj_dir="${git_dir%/.git}"
        local orig_path="${proj_dir#"$branch_work_root"}"
        # Skip if this is the current project (already added)
        [ "$orig_path" = "$project_path" ] && continue
        CAGE_WORK_PROJECTS+=("$proj_dir|$orig_path")
    done < <(find "$branch_work_root" -name ".git" -type d -print0 2>/dev/null)

    # Find other bare intermediaries in the shared intermediary root
    # Bare repos have a HEAD file directly (no .git subdirectory)
    while IFS= read -r head_file; do
        local bare_dir="${head_file%/HEAD}"
        local orig_path="${bare_dir#"$intermediary_root"}"
        [ "$orig_path" = "$project_path" ] && continue
        CAGE_INTERMEDIARY_PROJECTS+=("$bare_dir|$orig_path")
    done < <(find "$intermediary_root" -name "HEAD" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        # Only include if it looks like a bare repo (has objects/ dir)
        local d="${f%/HEAD}"
        [ -d "$d/objects" ] && printf '%s\n' "$f"
    done)
}

# Build mount specifications for the sandbox
# Populates global array: CAGE_MOUNTS
# Each entry is "type|source|dest|mode"
# Types: bind, tmpfs, proc, dev, dev-bind, pipe
# Mode: rw (default for bind), ro
#
# Arguments:
#   $1 - intermediary_dir (empty for non-git mode)
#   $2 - work_dir
#   $3 - project_path
#   $4 - pipe_path
#   $5 - user_home (for tilde expansion in additional mounts)
build_mount_specs() {
    local intermediary_dir="$1"
    local work_dir="$2"
    local project_path="$3"
    local pipe_path="$4"
    local user_home="$5"

    # Reset global array
    CAGE_MOUNTS=()

    # Additional mounts from config (come first so work dir can overlay)
    for mount_entry in "${cfg_mounts[@]}"; do
        IFS='|' read -r mount_source mount_dest mount_mode <<< "$mount_entry"
        # Expand tilde to user home
        mount_source="${mount_source/#\~/$user_home}"
        mount_dest="${mount_dest/#\~/$user_home}"
        if [ "$mount_mode" = "rw" ]; then
            CAGE_MOUNTS+=("bind|$mount_source|$mount_dest|rw")
        else
            CAGE_MOUNTS+=("bind|$mount_source|$mount_dest|ro")
        fi
    done

    # Temp filesystems
    CAGE_MOUNTS+=("tmpfs||/tmp|")
    CAGE_MOUNTS+=("tmpfs||/run|")

    # Mount strategy depends on mode
    if [ -z "$intermediary_dir" ]; then
        # Non-git mode: mount source directory directly (read-write)
        CAGE_MOUNTS+=("bind|$work_dir|$project_path|rw")
    elif [ "$cfg_isolated" != "true" ]; then
        # Non-isolated git mode: mount each project at its original path
        # Bare intermediaries mounted at /run<intermediary_dir> (matches work dir's git remote)
        for entry in "${CAGE_INTERMEDIARY_PROJECTS[@]}"; do
            IFS='|' read -r proj_dir orig_path <<< "$entry"
            CAGE_MOUNTS+=("bind|$proj_dir|/run$proj_dir|rw")
        done
        for entry in "${CAGE_WORK_PROJECTS[@]}"; do
            IFS='|' read -r proj_dir orig_path <<< "$entry"
            CAGE_MOUNTS+=("bind|$proj_dir|$orig_path|rw")
        done
    else
        # Isolated git mode: mount only the specific project
        CAGE_MOUNTS+=("bind|$intermediary_dir|/run$intermediary_dir|rw")
        CAGE_MOUNTS+=("bind|$work_dir|$project_path|rw")
    fi

    # Mount pipe for git hook communication (if it exists and we have an intermediary)
    if [ -n "$intermediary_dir" ] && [ -p "$pipe_path" ]; then
        CAGE_MOUNTS+=("pipe|$pipe_path|/tmp/claude-cage/pipe|rw")
    fi
}

# Convert mount spec to bwrap argument
# Arguments:
#   $1 - mount spec (type|source|dest|mode)
#   $2 - try flag: "try" to use -try variants, empty for required mounts
# Outputs bwrap arguments (may be multiple for some types)
mount_spec_to_bwrap() {
    local spec="$1"
    local try_flag="$2"
    IFS='|' read -r type source dest mode <<< "$spec"

    case "$type" in
        bind)
            if [ "$mode" = "ro" ]; then
                if [ "$try_flag" = "try" ]; then
                    echo "--ro-bind-try" "$source" "$dest"
                else
                    echo "--ro-bind" "$source" "$dest"
                fi
            else
                if [ "$try_flag" = "try" ]; then
                    echo "--bind-try" "$source" "$dest"
                else
                    echo "--bind" "$source" "$dest"
                fi
            fi
            ;;
        tmpfs)
            echo "--tmpfs" "$dest"
            ;;
        proc)
            echo "--proc" "$dest"
            ;;
        dev)
            echo "--dev" "$dest"
            ;;
        dev-bind)
            if [ "$try_flag" = "try" ]; then
                echo "--dev-bind-try" "$source" "$dest"
            else
                echo "--dev-bind" "$source" "$dest"
            fi
            ;;
        pipe)
            echo "--bind" "$source" "$dest"
            ;;
    esac
}

# Convert mount spec to docker -v argument
# Arguments:
#   $1 - mount spec (type|source|dest|mode)
# Outputs docker volume argument or empty if not applicable
mount_spec_to_docker() {
    local spec="$1"
    IFS='|' read -r type source dest mode <<< "$spec"

    case "$type" in
        bind|pipe)
            # Docker needs the source to exist
            if [ -e "$source" ] || [ -p "$source" ]; then
                if [ "$mode" = "ro" ]; then
                    echo "-v" "$source:$dest:ro"
                else
                    echo "-v" "$source:$dest"
                fi
            fi
            ;;
        tmpfs|proc|dev|dev-bind)
            # Docker handles these internally via its container image
            ;;
    esac
}
