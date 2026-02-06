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

    # Convert glob patterns to awk-compatible regex patterns.
    # Each pattern becomes a line: "P:<regex>" (prefix) or "G:<regex>" (glob).
    local regex_patterns=""
    local pat
    for pat in "${PATTERNS[@]}"; do
        # Escape regex special characters (except * and ?)
        # Use multiple s/// commands because bracket expressions with
        # backslashes and brackets are unreliable across sed implementations.
        local regex
        regex=$(printf '%s' "$pat" | sed \
            -e 's/\\/\\\\/g' \
            -e 's/\./\\./g' \
            -e 's/+/\\+/g' \
            -e 's/(/\\(/g' \
            -e 's/)/\\)/g' \
            -e 's/{/\\{/g' \
            -e 's/}/\\}/g' \
            -e 's/|/\\|/g' \
            -e 's/\^/\\^/g' \
            -e 's/\$/\\$/g' \
            -e 's/\[/\\[/g' \
            -e 's/\]/\\]/g')
        # Convert ** to placeholder, then * to .*, then restore placeholder.
        # This prevents the * inside .* from being double-converted.
        regex="${regex//\*\*/__DSTAR__}"
        regex="${regex//\*/.*}"
        regex="${regex//__DSTAR__/.*}"
        # Convert ? to .
        regex="${regex//\?/.}"

        if [[ "$pat" == */ ]]; then
            # Directory prefix: match path starting with this prefix
            regex_patterns+="P:^${regex}"$'\n'
        else
            # Glob: exact match OR files within matching directory
            regex_patterns+="G:^${regex}(/.*)?$"$'\n'
        fi
    done

    # Stage input into a seekable temp file (two-pass processing)
    local TMPSTREAM
    TMPSTREAM=$(mktemp)

    # Ensure cleanup of temp file
    # shellcheck disable=SC2064
    trap "rm -f '$TMPSTREAM'" RETURN

    cat > "$TMPSTREAM"

    # Pass 1 (awk): Identify blob marks to strip and excluded paths.
    #
    # A mark is stripped only if every M line referencing it is for an excluded
    # path. If the same blob is referenced by both an excluded and a kept path,
    # the blob is preserved.
    #
    # LC_ALL=C for binary-safe byte counting in data sections.
    local analysis
    analysis=$(LC_ALL=C _FES_PATTERNS="$regex_patterns" awk '
BEGIN {
    patterns = ENVIRON["_FES_PATTERNS"]
    n = split(patterns, pat_arr, "\n")
    pat_count = 0
    for (i = 1; i <= n; i++) {
        if (pat_arr[i] == "") continue
        pat_count++
        pat_types[pat_count] = substr(pat_arr[i], 1, 1)
        pat_regexes[pat_count] = substr(pat_arr[i], 3)
    }
    state = "normal"
    remaining = 0
}

function should_exclude(path) {
    # Strip surrounding quotes (fast-export quotes paths with spaces)
    if (substr(path, 1, 1) == "\"")
        path = substr(path, 2, length(path) - 2)
    for (i = 1; i <= pat_count; i++) {
        if (path ~ pat_regexes[i]) return 1
    }
    return 0
}

# Skip over data sections to avoid matching binary content
state == "skip_data" {
    remaining -= (length($0) + 1)
    if (remaining <= 0) state = "normal"
    next
}

state == "normal" && /^data [0-9]+$/ {
    remaining = $2 + 0
    if (remaining > 0) state = "skip_data"
    next
}

state == "normal" && /^M [0-9]+ :[0-9]+ / {
    mark = $3
    path = $0; sub(/^M [0-9]+ :[0-9]+ /, "", path)
    if (should_exclude(path)) {
        mark_excl[mark] = 1
        excl_paths[path] = 1
    } else {
        mark_kept[mark] = 1
    }
}

state == "normal" && /^D / {
    path = $0; sub(/^D /, "", path)
    if (should_exclude(path)) {
        excl_paths[path] = 1
    }
}

END {
    for (m in mark_excl) {
        if (!(m in mark_kept)) printf "S:%s\n", m
    }
    for (p in excl_paths) {
        printf "E:%s\n", p
    }
}
' "$TMPSTREAM")

    # Parse analysis output into space/newline-separated strings for pass 2
    local strip_marks_str="" excluded_paths_str=""
    while IFS= read -r aline; do
        case "$aline" in
            S:*) strip_marks_str+="${aline#S:} " ;;
            E:*) excluded_paths_str+="${aline#E:}"$'\n' ;;
        esac
    done <<< "$analysis"

    # Pass 2 (awk): Filter the stream.
    #
    # Stateful line-by-line processing: tracking blob sections,
    # skipping data payloads by byte count, removing excluded M/D lines,
    # and collapsing consecutive blank lines left behind.
    #
    # LC_ALL=C ensures length() returns bytes (not multibyte characters)
    # which is critical for correctly counting data section payloads
    # that may contain binary content (images, etc.).
    LC_ALL=C awk -v strip_marks="$strip_marks_str" -v excluded_paths="$excluded_paths_str" '
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

# Pass through data payload verbatim (kept blobs, commit messages, etc.)
# No blank-line collapsing or M/D checks inside data sections.
state == "pass_data" {
    remaining -= (length($0) + 1)
    print
    if (remaining <= 0) state = "normal"
    next
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

    # Data section (commit messages, tag messages, kept blob data)
    # Enter pass_data to avoid corrupting binary content
    if ($0 ~ /^data [0-9]+$/) {
        remaining = $2 + 0
        prev_blank = 0
        print
        if (remaining > 0) state = "pass_data"
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
