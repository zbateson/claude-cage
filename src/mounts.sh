# ============================================================================
# Shared mount logic for bwrap and docker
# ============================================================================

# Enumerate project directories for mounting
# Scans session work root for .git dirs to discover cross-project work dirs.
# Populates global arrays: CAGE_WORK_PROJECTS and CAGE_INTERMEDIARY_PROJECTS
# Each entry is "source_path|container_path"
#
# Arguments:
#   $1 - session_work_root (per-session: sessions/<session_id>/work)
#   $2 - intermediary_root (shared: intermediary/)
#   $3 - work_dir (current project)
#   $4 - intermediary_dir (current project bare repo, empty for non-git mode)
#   $5 - project_path (original path)
enumerate_projects() {
    local session_work_root="$1"
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

    # Determine mount destination for current project.
    # When scoped, mount at git root so the user sees empty parent dirs above
    # the scope with no .git — the work dir (with .git) lives at scope_path
    # inside the mount.  Mount source is the git-root-level parent directory
    # (automatically created by git clone when creating the nested work dir).
    local mount_dest="$project_path"
    local mount_src="$work_dir"
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        local sp
        sp=$(cat "$scope_path_file")
        if [ -n "$sp" ]; then
            local git_root_file
            git_root_file=$(get_git_root_file "$intermediary_dir")
            if [ -f "$git_root_file" ]; then
                local gr
                gr=$(cat "$git_root_file")
                mount_dest="$gr"
                mount_src="$session_work_root$gr"
            fi
        fi
    fi

    # Always include the current project (needed for dry-run when dirs don't exist yet)
    CAGE_WORK_PROJECTS+=("$mount_src|$mount_dest")
    CAGE_INTERMEDIARY_PROJECTS+=("$intermediary_dir|$mount_dest")

    # Track seen mount destinations to avoid duplicates (two scopes for same git root)
    local -A seen_mount_dests=()
    seen_mount_dests["$mount_dest"]=1

    # Find other projects by scanning session work root for .git dirs
    [ -d "$session_work_root" ] || return 0
    while IFS= read -r git_dir; do
        local other_work="${git_dir%/.git}"
        # Derive source path by stripping session_work_root prefix
        local orig_path="${other_work#"$session_work_root"}"
        [ "$orig_path" = "$project_path" ] && continue

        # Get the intermediary dir from work dir's remote.origin.url
        local remote_url
        remote_url=$(git -C "$other_work" config --get remote.origin.url 2>/dev/null) || continue
        # Strip /run prefix (intermediaries are mounted at /run<intermediary_path>)
        local other_bare="${remote_url#/run}"

        # Read scope metadata from the work dir
        local other_sp=""
        [ -f "$other_work/.git/claude-cage-scope-path" ] && \
            other_sp=$(cat "$other_work/.git/claude-cage-scope-path")

        # Determine mount destination (scope-aware: mount at git root)
        local other_mount_dest="$orig_path"
        local other_mount_src="$session_work_root$orig_path"
        if [ -n "$other_sp" ]; then
            local other_gr=""
            if [ -d "$other_bare" ]; then
                local other_gr_file="$other_bare/claude-cage-git-root"
                [ -f "$other_gr_file" ] && other_gr=$(cat "$other_gr_file")
            fi
            if [ -n "$other_gr" ]; then
                other_mount_dest="$other_gr"
                other_mount_src="$session_work_root$other_gr"
            fi
        fi

        # Skip if we'd duplicate a mount destination
        if [ -n "${seen_mount_dests[$other_mount_dest]+_}" ]; then
            continue
        fi
        seen_mount_dests["$other_mount_dest"]=1

        CAGE_WORK_PROJECTS+=("$other_mount_src|$other_mount_dest")
        if [ -d "$other_bare/objects" ]; then
            CAGE_INTERMEDIARY_PROJECTS+=("$other_bare|$other_mount_dest")
        fi
    done < <(find "$session_work_root" -name ".git" -type d 2>/dev/null)
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
        # For scoped projects, mount at git root (work dir is nested inside)
        local _iso_src="$work_dir"
        local _iso_dest="$project_path"
        local _iso_sp_file
        _iso_sp_file=$(get_scope_path_file "$intermediary_dir")
        if [ -f "$_iso_sp_file" ]; then
            local _iso_sp
            _iso_sp=$(cat "$_iso_sp_file")
            if [ -n "$_iso_sp" ]; then
                local _iso_gr
                _iso_gr=$(cat "$(get_git_root_file "$intermediary_dir")" 2>/dev/null)
                if [ -n "$_iso_gr" ]; then
                    _iso_dest="$_iso_gr"
                    _iso_src="${work_dir%"/$_iso_sp"}"
                fi
            fi
        fi
        CAGE_MOUNTS+=("bind|$_iso_src|$_iso_dest|rw")
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
