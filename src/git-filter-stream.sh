# ============================================================================
# Fast-export stream filter (exclude paths from git fast-export output)
# ============================================================================

# Filter a git fast-export stream to exclude specified paths
#
# Strips blob data and M/D lines for excluded paths while preserving all
# commits (including commits that become empty after filtering). This ensures
# a 1:1 commit mapping between source and filtered repos.
#
# No excluded file content ever enters the destination object store.
#
# Usage:
#   git fast-export <range> | filter_fast_export_stream <pattern>...
#
# Patterns:
#   path/to/file     - exact file match
#   directory/        - directory prefix match (trailing /)
#   *.ext             - glob match (bash glob -- * matches across /)
#
filter_fast_export_stream() {
    local PATTERNS=("$@")

    if [ ${#PATTERNS[@]} -eq 0 ]; then
        # No patterns - pass through unchanged
        cat
        return
    fi

    # should_exclude <path>
    # Returns 0 (true) if the path matches any exclusion pattern.
    # Handles quoted paths from fast-export (e.g. "src/has spaces.txt").
    _fes_should_exclude() {
        local path="$1"

        # Strip surrounding quotes (fast-export quotes paths with spaces/special chars)
        if [[ "$path" =~ ^\"(.*)\"$ ]]; then
            path="${BASH_REMATCH[1]}"
        fi

        local pat
        for pat in "${PATTERNS[@]}"; do
            if [[ "$pat" == */ ]]; then
                # Directory prefix match
                [[ "$path" == "${pat}"* || "$path" == "${pat%/}" ]] && return 0
            else
                # Glob match (bash [[ ]] glob -- * crosses directory separators)
                # shellcheck disable=SC2254
                [[ "$path" == $pat ]] && return 0
                # Also match files within matching directories
                # e.g. pattern **/__pycache__ should match src/__pycache__/module.pyc
                # shellcheck disable=SC2254
                [[ "$path" == $pat/* ]] && return 0
            fi
        done
        return 1
    }

    # Stage input into a seekable temp file (two-pass processing)
    local TMPSTREAM
    TMPSTREAM=$(mktemp)

    # Ensure cleanup of temp file
    # shellcheck disable=SC2064
    trap "rm -f '$TMPSTREAM'" RETURN

    cat > "$TMPSTREAM"

    # Pass 1: Identify blob marks to strip
    #
    # A mark is stripped only if every M line referencing it is for an excluded
    # path. If the same blob is referenced by both an excluded and a kept path,
    # the blob is preserved.
    local -A MARK_EXCLUDED
    local -A MARK_KEPT

    while IFS= read -r line; do
        if [[ "$line" =~ ^M\ [0-9]+\ (:[0-9]+)\ (.+)$ ]]; then
            local mark="${BASH_REMATCH[1]}"
            local path="${BASH_REMATCH[2]}"
            if _fes_should_exclude "$path"; then
                MARK_EXCLUDED["$mark"]=1
            else
                MARK_KEPT["$mark"]=1
            fi
        fi
    done < "$TMPSTREAM"

    local -A STRIP_MARKS
    local mark
    for mark in "${!MARK_EXCLUDED[@]}"; do
        if [[ -z "${MARK_KEPT[$mark]+_}" ]]; then
            STRIP_MARKS["$mark"]=1
        fi
    done

    # Pass 1b: Collect all excluded paths for awk lookup
    local -A EXCLUDED_PATHS

    while IFS= read -r line; do
        if [[ "$line" =~ ^M\ [0-9]+\ :[0-9]+\ (.+)$ ]]; then
            local path="${BASH_REMATCH[1]}"
            _fes_should_exclude "$path" && EXCLUDED_PATHS["$path"]=1
        elif [[ "$line" =~ ^D\ (.+)$ ]]; then
            local path="${BASH_REMATCH[1]}"
            _fes_should_exclude "$path" && EXCLUDED_PATHS["$path"]=1
        fi
    done < "$TMPSTREAM"

    # Build space-separated strings for awk
    local strip_marks_str=""
    for mark in "${!STRIP_MARKS[@]}"; do
        strip_marks_str="${strip_marks_str}${mark} "
    done

    local excluded_paths_str=""
    local p
    for p in "${!EXCLUDED_PATHS[@]}"; do
        excluded_paths_str="${excluded_paths_str}${p}"$'\n'
    done

    # Pass 2: Filter the stream via awk
    #
    # Awk handles stateful line-by-line processing: tracking blob sections,
    # skipping data payloads by byte count, removing excluded M/D lines,
    # and collapsing consecutive blank lines left behind.
    awk -v strip_marks="$strip_marks_str" -v excluded_paths="$excluded_paths_str" '
BEGIN {
    n = split(strip_marks, marks_arr, " ")
    for (i = 1; i <= n; i++) {
        if (marks_arr[i] != "") strip[marks_arr[i]] = 1
    }
    n = split(excluded_paths, paths_arr, "\n")
    for (i = 1; i <= n; i++) {
        if (paths_arr[i] != "") excluded[paths_arr[i]] = 1
    }
    state = "normal"
    remaining = 0
    prev_blank = 0
    pending_blob = ""
}

# Skip data payload of a stripped blob (byte-counted)
state == "skip_data" {
    remaining -= (length($0) + 1)
    if (remaining <= 0) state = "normal"
    next
}

# Read the "data <N>" line after a stripped blob+mark
state == "skip_blob" {
    if ($0 ~ /^data [0-9]+$/) {
        remaining = $2 + 0
        state = (remaining > 0) ? "skip_data" : "normal"
    } else {
        print $0
        state = "normal"
    }
    next
}

state == "normal" {
    # Blob start -- buffer and peek at mark
    if ($0 == "blob") {
        pending_blob = $0
        state = "pending_mark"
        next
    }

    # M line for excluded path
    if ($0 ~ /^M [0-9]+ :[0-9]+ /) {
        path = $0; sub(/^M [0-9]+ :[0-9]+ /, "", path)
        if (path in excluded) next
    }

    # D line for excluded path
    if ($0 ~ /^D /) {
        path = $0; sub(/^D /, "", path)
        if (path in excluded) next
    }

    # Collapse consecutive blank lines
    if ($0 == "") {
        if (prev_blank) next
        prev_blank = 1
    } else {
        prev_blank = 0
    }

    print
    next
}

# Check whether the blob mark is stripped
state == "pending_mark" {
    if ($0 ~ /^mark :[0-9]+$/) {
        mark = $2
        if (mark in strip) {
            state = "skip_blob"
            pending_blob = ""
            next
        }
    }
    # Not stripped -- emit buffered blob line and this line
    print pending_blob
    print
    pending_blob = ""
    state = "normal"
    prev_blank = 0
    next
}
' "$TMPSTREAM" | {
        # Strip leading blank line if present (artifact of skipping first blob)
        IFS= read -r first_line || return 0
        if [ -n "$first_line" ]; then
            printf '%s\n' "$first_line"
        fi
        cat
    }
}
