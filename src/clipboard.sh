# ============================================================================
# Clipboard go-between
# ============================================================================
# The cage never gets a display socket. Stand-in wl-copy/wl-paste scripts
# queue requests in a shared inbox; a host listener checks each one against
# clipboard.write/read and runs the real clipboard tools.
#
# Host layout under clipboard_base (per claude-cage process):
#   cage/     mounted read-only at CAGE_CLIPBOARD_DIR: bin/, replies/, busy
#   inbox/    mounted read-write at CAGE_CLIPBOARD_INBOX: tmp/, queue/
#   private/  never mounted; requests are copied here before being read
# Replies live in a read-only mount so the cage can't plant symlinks where
# the listener writes.

CAGE_CLIPBOARD_DIR="/run/claude-cage/clipboard"
CAGE_CLIPBOARD_INBOX="/run/claude-cage/clipboard-inbox"
CLIPBOARD_MAX_WRITE_BYTES=$((10 * 1024 * 1024))
CLIPBOARD_PROMPT_TIMEOUT=60
clipboard_base=""
CLIPBOARD_LISTENER_PID=""

detect_clipboard_backend() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1 \
        && command -v wl-paste >/dev/null 2>&1; then
        echo "wayland"
    elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
        echo "x11"
    elif [ "$(uname -s)" = "Darwin" ] && command -v pbcopy >/dev/null 2>&1; then
        echo "macos"
    fi
}

detect_clipboard_dialog() {
    if [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
        echo "osascript"
    elif command -v zenity >/dev/null 2>&1; then
        echo "zenity"
    elif command -v kdialog >/dev/null 2>&1; then
        echo "kdialog"
    fi
}

detect_clipboard_notifier() {
    if [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
        echo "osascript"
    elif command -v notify-send >/dev/null 2>&1; then
        echo "notify-send"
    fi
}

# Sets clipboard_write_mode/clipboard_read_mode to what this host can honour.
# Only settings the user wrote out get a warning when they're downgraded;
# defaults fall back quietly so headless and SSH starts stay clean.
resolve_clipboard_modes() {
    clipboard_write_mode="${cfg_clipboard_write:-notify}"
    clipboard_read_mode="${cfg_clipboard_read:-confirm}"
    clipboard_backend=$(detect_clipboard_backend)
    clipboard_dialog=$(detect_clipboard_dialog)
    clipboard_notifier=$(detect_clipboard_notifier)

    if [ -z "$clipboard_backend" ]; then
        if { [ "${cfg_clipboard_write_set:-}" = "explicit" ] && [ "$clipboard_write_mode" != "deny" ]; } ||
           { [ "${cfg_clipboard_read_set:-}" = "explicit" ] && [ "$clipboard_read_mode" != "deny" ]; }; then
            echo -e "${_yellow}Clipboard's set up, but there's no clipboard tool out here" \
                "(wl-copy/wl-paste, xclip or pbcopy). Cage stays cut off.${_reset}" >&2
        fi
        clipboard_write_mode="deny"
        clipboard_read_mode="deny"
        return 0
    fi

    if [ -z "$clipboard_dialog" ]; then
        if [ "$clipboard_read_mode" = "confirm" ]; then
            [ "${cfg_clipboard_read_set:-}" = "explicit" ] && \
                echo -e "${_yellow}clipboard.read = \"confirm\" needs zenity, kdialog or osascript" \
                    "to ask you. Without one, reads get denied.${_reset}" >&2
            clipboard_read_mode="deny"
        fi
        if [ "$clipboard_write_mode" = "confirm" ]; then
            [ "${cfg_clipboard_write_set:-}" = "explicit" ] && \
                echo -e "${_yellow}clipboard.write = \"confirm\" needs zenity, kdialog or osascript" \
                    "to ask you. Without one, copies get denied.${_reset}" >&2
            clipboard_write_mode="deny"
        fi
    fi

    if [ -z "$clipboard_notifier" ] && [ "$clipboard_write_mode" = "notify" ]; then
        [ "${cfg_clipboard_write_set:-}" = "explicit" ] && \
            echo -e "${_yellow}clipboard.write = \"notify\" needs notify-send or osascript." \
                "Copies'll go through without a heads-up.${_reset}" >&2
        clipboard_write_mode="allow"
    fi
    return 0
}

clipboard_enabled() {
    [ "${clipboard_write_mode:-deny}" != "deny" ] || [ "${clipboard_read_mode:-deny}" != "deny" ]
}

# Creates the go-between directories and stand-in scripts. Sets clipboard_base.
setup_clipboard_dir() {
    clipboard_base="$CLAUDE_CAGE_RUNTIME/clipboard/${CLAUDE_CAGE_SESSION:-direct}/$$"
    rm -rf "$clipboard_base"
    mkdir -p "$clipboard_base"/cage/bin "$clipboard_base"/cage/replies \
        "$clipboard_base"/inbox/tmp "$clipboard_base"/inbox/queue "$clipboard_base"/private
    chmod 700 "$clipboard_base"
    write_clipboard_shims "$clipboard_base/cage/bin"
}

cleanup_clipboard_dir() {
    [ -n "$clipboard_base" ] && rm -rf "$clipboard_base"
    return 0
}

# Writes the cage-side wl-copy and wl-paste. POSIX sh so they also run on
# minimal Docker images.
write_clipboard_shims() {
    local bin_dir="$1"
    cat > "$bin_dir/wl-copy" << SHIM_EOF
#!/bin/sh
# claude-cage stand-in for wl-copy: queues the copy for the host listener
inbox="\${CLAUDE_CAGE_CLIPBOARD_INBOX:-$CAGE_CLIPBOARD_INBOX}"
type=""
primary=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -p|--primary) primary=1 ;;
        -t|--type) type="\$2"; shift ;;
        --type=*) type="\${1#--type=}" ;;
        -n|--trim-newline|-o|--paste-once|-f|--foreground|-r|--regular) ;;
        -c|--clear) exit 0 ;;
        --) shift; break ;;
        -*) echo "wl-copy (claude-cage): unsupported option \$1" >&2; exit 1 ;;
        *) break ;;
    esac
    shift
done
# Primary selection isn't shared; callers that set both would otherwise
# double every copy
if [ -n "\$primary" ]; then
    [ \$# -eq 0 ] && cat > /dev/null
    exit 0
fi
id="\$(date +%s)-\$\$-\$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
req="\$inbox/tmp/\$id"
mkdir "\$req" || exit 1
printf 'copy' > "\$req/op"
printf '%s' "\$type" > "\$req/type"
if [ \$# -gt 0 ]; then
    printf '%s' "\$*" > "\$req/data"
else
    cat > "\$req/data"
fi
mv "\$req" "\$inbox/queue/\$id"
SHIM_EOF

    cat > "$bin_dir/wl-paste" << SHIM_EOF
#!/bin/sh
# claude-cage stand-in for wl-paste: asks the host listener and waits
dir="\${CLAUDE_CAGE_CLIPBOARD_DIR:-$CAGE_CLIPBOARD_DIR}"
inbox="\${CLAUDE_CAGE_CLIPBOARD_INBOX:-$CAGE_CLIPBOARD_INBOX}"
op="paste"
type=""
newline=1
while [ \$# -gt 0 ]; do
    case "\$1" in
        -l|--list-types) op="list" ;;
        -t|--type) type="\$2"; shift ;;
        --type=*) type="\${1#--type=}" ;;
        -n|--no-newline) newline="" ;;
        -p|--primary) echo "No selection" >&2; exit 1 ;;
        *) echo "wl-paste (claude-cage): unsupported option \$1" >&2; exit 1 ;;
    esac
    shift
done
id="\$(date +%s)-\$\$-\$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
req="\$inbox/tmp/\$id"
mkdir "\$req" || exit 1
printf '%s' "\$op" > "\$req/op"
printf '%s' "\$type" > "\$req/type"
mv "\$req" "\$inbox/queue/\$id"

# A listener that's alive picks requests up within a poll; one that's busy
# showing a prompt says so with the busy file
waited=0
while [ -e "\$inbox/queue/\$id" ]; do
    if [ -e "\$dir/busy" ]; then
        waited=0
    else
        waited=\$((waited + 1))
    fi
    if [ \$waited -gt 60 ]; then
        rm -rf "\$inbox/queue/\$id"
        echo "wl-paste (claude-cage): clipboard listener isn't answering" >&2
        exit 1
    fi
    sleep 0.05
done
waited=0
while [ ! -f "\$dir/replies/\$id/status" ]; do
    waited=\$((waited + 1))
    if [ \$waited -gt 3000 ]; then
        echo "wl-paste (claude-cage): no answer from the clipboard listener" >&2
        exit 1
    fi
    sleep 0.05
done
status=\$(cat "\$dir/replies/\$id/status")
if [ "\$status" != "ok" ]; then
    echo "No selection" >&2
    exit 1
fi
cat "\$dir/replies/\$id/data"
if [ -n "\$newline" ] && [ "\$op" = "paste" ]; then
    case "\$type" in
        ""|text/*|*STRING*|TEXT) echo ;;
    esac
fi
exit 0
SHIM_EOF
    chmod 755 "$bin_dir/wl-copy" "$bin_dir/wl-paste"
}

_clipboard_is_text_type() {
    case "$1" in
        ""|text/*|*STRING*|TEXT) return 0 ;;
    esac
    return 1
}

_clipboard_human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576)) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$((bytes / 1024)) KB"
    else
        echo "$bytes bytes"
    fi
}

# One-line description of clipboard content for prompts and notifications
_clipboard_describe() {
    local type="$1" file="$2" size text
    size=$(wc -c < "$file" | tr -d ' ')
    if [ "$size" -eq 0 ]; then
        echo "nothing"
        return 0
    fi
    if _clipboard_is_text_type "$type"; then
        text=$(head -c 400 "$file" | tr '\n\t\r' '   ' | tr -d '\000-\010\013-\037\177')
        if [ "${#text}" -gt 80 ] || [ "$size" -gt 400 ]; then
            text="${text:0:80}..."
        fi
        echo "\"$text\" ($(_clipboard_human_size "$size"))"
    else
        echo "${type}, $(_clipboard_human_size "$size")"
    fi
}

_clipboard_escape_markup() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Returns 0 only when the user picks Allow; closing or timing out denies
_clipboard_confirm() {
    local msg="$1" answer
    case "$clipboard_dialog" in
        zenity)
            zenity --question --no-markup --title "claude-cage" --text "$msg" \
                --ok-label "Allow" --cancel-label "Deny" --default-cancel \
                --timeout "$CLIPBOARD_PROMPT_TIMEOUT" >/dev/null 2>&1
            ;;
        kdialog)
            timeout "$CLIPBOARD_PROMPT_TIMEOUT" kdialog --title "claude-cage" \
                --yes-label "Allow" --no-label "Deny" \
                --yesno "$(_clipboard_escape_markup "$msg")" >/dev/null 2>&1
            ;;
        osascript)
            answer=$(osascript -e 'on run argv' \
                -e 'display dialog (item 1 of argv) with title "claude-cage" buttons {"Deny", "Allow"} default button "Deny" cancel button "Deny" giving up after (item 2 of argv as integer)' \
                -e 'return button returned of result' -e 'end run' \
                "$msg" "$CLIPBOARD_PROMPT_TIMEOUT" 2>/dev/null)
            [ "$answer" = "Allow" ]
            ;;
        *)
            return 1
            ;;
    esac
}

_clipboard_notify() {
    local msg="$1"
    case "$clipboard_notifier" in
        notify-send)
            notify-send --app-name=claude-cage "claude-cage" \
                "$(_clipboard_escape_markup "$msg")" >/dev/null 2>&1
            ;;
        osascript)
            osascript -e 'on run argv' \
                -e 'display notification (item 1 of argv) with title "claude-cage"' \
                -e 'end run' "$msg" >/dev/null 2>&1
            ;;
    esac
    return 0
}

_clipboard_backend_write() {
    local type="$1" file="$2"
    case "$clipboard_backend" in
        wayland)
            if [ -n "$type" ]; then
                wl-copy --type "$type" < "$file" >/dev/null 2>&1
            else
                wl-copy < "$file" >/dev/null 2>&1
            fi
            ;;
        x11)
            if [ -n "$type" ]; then
                xclip -selection clipboard -t "$type" -i "$file" >/dev/null 2>&1
            else
                xclip -selection clipboard -i "$file" >/dev/null 2>&1
            fi
            ;;
        macos)
            pbcopy < "$file" >/dev/null 2>&1
            ;;
    esac
}

_clipboard_backend_list() {
    case "$clipboard_backend" in
        wayland) wl-paste --list-types 2>/dev/null ;;
        x11) xclip -selection clipboard -t TARGETS -o 2>/dev/null ;;
        macos) [ -n "$(pbpaste 2>/dev/null | head -c 1)" ] && echo "text/plain" ;;
    esac
}

_clipboard_backend_read() {
    local type="$1" out="$2"
    case "$clipboard_backend" in
        wayland)
            if [ -n "$type" ]; then
                wl-paste --no-newline --type "$type" > "$out" 2>/dev/null
            else
                wl-paste --no-newline > "$out" 2>/dev/null
            fi
            ;;
        x11)
            if [ -n "$type" ]; then
                xclip -selection clipboard -t "$type" -o > "$out" 2>/dev/null
            else
                xclip -selection clipboard -o > "$out" 2>/dev/null
            fi
            ;;
        macos)
            _clipboard_is_text_type "$type" && pbpaste > "$out" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

_clipboard_reply() {
    local id="$1" status="$2" data_file="${3:-}"
    local staging="$clipboard_base/private/reply-$id"
    rm -rf "$staging"
    mkdir "$staging"
    if [ -n "$data_file" ]; then
        mv "$data_file" "$staging/data"
    else
        : > "$staging/data"
    fi
    printf '%s' "$status" > "$staging/status"
    rm -rf "$clipboard_base/cage/replies/$id"
    mv "$staging" "$clipboard_base/cage/replies/$id"
}

# Copies a request out of the inbox into private/ and checks the copy, so
# nothing the cage does afterwards (symlinks, FIFOs, swapped files) can
# point the listener at a host path. Prints the private copy's path.
_clipboard_take_request() {
    local req="$1" id="$2" dest="$clipboard_base/private/req-$id"
    rm -rf "$dest"
    cp -RP -- "$req" "$dest" 2>/dev/null
    rm -rf -- "$req"
    [ -d "$dest" ] && [ ! -L "$dest" ] || { rm -rf "$dest"; return 1; }
    if [ -n "$(find "$dest" -mindepth 1 ! -type f -print -quit 2>/dev/null)" ]; then
        rm -rf "$dest"
        return 1
    fi
    echo "$dest"
}

_clipboard_log() {
    append_session_log "[clipboard] $1"
}

# Handles one queued request. $3 = 1 when a prompt may be shown; returns 2
# when a prompt was shown so the caller can deny the requests behind it.
_clipboard_handle() {
    local req="$1" id="$2" may_prompt="$3" copy op="" type="" size desc out
    local type_re='^[A-Za-z0-9][A-Za-z0-9.+_-]*(/[A-Za-z0-9][A-Za-z0-9.+_=;-]*)?$'
    copy=$(_clipboard_take_request "$req" "$id") || return 0
    [ -f "$copy/op" ] && op=$(head -c 16 "$copy/op")
    [ -f "$copy/type" ] && type=$(head -c 128 "$copy/type")
    if [ -n "$type" ] && [[ ! "$type" =~ $type_re ]]; then
        _clipboard_log "rejected request with type '${type//[^[:print:]]/?}'"
        [ "$op" != "copy" ] && _clipboard_reply "$id" "error"
        rm -rf "$copy"
        return 0
    fi

    local rc=0
    case "$op" in
        copy)
            [ -f "$copy/data" ] || : > "$copy/data"
            size=$(wc -c < "$copy/data" | tr -d ' ')
            if [ "$size" -gt "$CLIPBOARD_MAX_WRITE_BYTES" ]; then
                _clipboard_log "copy refused: $size bytes is over the limit"
            elif [ "$clipboard_write_mode" = "deny" ]; then
                _clipboard_log "copy denied ($size bytes)"
            else
                desc=$(_clipboard_describe "$type" "$copy/data")
                if [ "$clipboard_write_mode" = "confirm" ]; then
                    if [ "$may_prompt" != 1 ]; then
                        _clipboard_log "copy denied: another prompt was open"
                    else
                        rc=2
                        if _clipboard_confirm "The $cfg_project cage wants to copy to your clipboard: $desc"; then
                            _clipboard_backend_write "$type" "$copy/data"
                            _clipboard_log "copy allowed after asking ($size bytes)"
                        else
                            _clipboard_log "copy denied after asking ($size bytes)"
                        fi
                    fi
                else
                    _clipboard_backend_write "$type" "$copy/data"
                    _clipboard_log "copy allowed ($size bytes)"
                    [ "$clipboard_write_mode" = "notify" ] && \
                        _clipboard_notify "The $cfg_project cage copied $desc"
                fi
            fi
            ;;
        list)
            if [ "$clipboard_read_mode" = "deny" ]; then
                _clipboard_reply "$id" "empty"
            else
                out="$clipboard_base/private/out-$id"
                _clipboard_backend_list > "$out"
                if [ -s "$out" ]; then
                    _clipboard_reply "$id" "ok" "$out"
                else
                    rm -f "$out"
                    _clipboard_reply "$id" "empty"
                fi
            fi
            ;;
        paste)
            if [ "$clipboard_read_mode" = "deny" ]; then
                _clipboard_log "read denied (${type:-text})"
                _clipboard_reply "$id" "denied"
            else
                out="$clipboard_base/private/out-$id"
                if ! _clipboard_backend_read "$type" "$out" || [ ! -s "$out" ]; then
                    rm -f "$out"
                    _clipboard_reply "$id" "empty"
                elif [ "$clipboard_read_mode" = "allow" ]; then
                    _clipboard_log "read allowed (${type:-text})"
                    _clipboard_reply "$id" "ok" "$out"
                elif [ "$may_prompt" != 1 ]; then
                    rm -f "$out"
                    _clipboard_log "read denied: another prompt was open"
                    _clipboard_reply "$id" "denied"
                else
                    rc=2
                    desc=$(_clipboard_describe "$type" "$out")
                    if _clipboard_confirm "The $cfg_project cage wants to read your clipboard: $desc"; then
                        _clipboard_log "read allowed after asking (${type:-text})"
                        _clipboard_reply "$id" "ok" "$out"
                    else
                        rm -f "$out"
                        _clipboard_log "read denied after asking (${type:-text})"
                        _clipboard_reply "$id" "denied"
                    fi
                fi
            fi
            ;;
        *)
            _clipboard_reply "$id" "error"
            ;;
    esac
    rm -rf "$copy"
    return $rc
}

# Works through the queue once. At most one prompt per pass; once one has
# been shown, anything else wanting a prompt is denied, including requests
# that arrived while it was open.
_clipboard_pass() {
    local may_prompt="$1" req id prompted=0 rc
    for req in "$clipboard_base"/inbox/queue/*; do
        [ -e "$req" ] || [ -L "$req" ] || continue
        id="${req##*/}"
        if [[ ! "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
            rm -rf -- "$req"
            continue
        fi
        : > "$clipboard_base/cage/busy"
        if [ "$may_prompt" = 1 ] && [ "$prompted" = 0 ]; then
            _clipboard_handle "$req" "$id" 1
        else
            _clipboard_handle "$req" "$id" 0
        fi
        rc=$?
        rm -f "$clipboard_base/cage/busy"
        [ "$rc" = 2 ] && prompted=1
    done
    [ "$prompted" = 1 ] && return 2
    return 0
}

# Removes replies the cage has had a couple of minutes to collect
_clipboard_prune_replies() {
    find "$clipboard_base/cage/replies" -mindepth 1 -maxdepth 1 -mmin +2 \
        -exec rm -rf {} + 2>/dev/null
    return 0
}

start_clipboard_listener() {
    local parent_pid=$$
    (
        passes=0
        while kill -0 "$parent_pid" 2>/dev/null; do
            _clipboard_pass 1
            if [ $? = 2 ]; then
                _clipboard_pass 0
            fi
            passes=$((passes + 1))
            if [ $((passes % 100)) = 0 ]; then
                _clipboard_prune_replies
            fi
            sleep 0.1
        done
    ) &
    CLIPBOARD_LISTENER_PID=$!
}

stop_clipboard_listener() {
    if [ -n "$CLIPBOARD_LISTENER_PID" ] && kill -0 "$CLIPBOARD_LISTENER_PID" 2>/dev/null; then
        kill "$CLIPBOARD_LISTENER_PID" 2>/dev/null
        wait "$CLIPBOARD_LISTENER_PID" 2>/dev/null
    fi
    CLIPBOARD_LISTENER_PID=""
    return 0
}

# Prints a one-line summary of the effective clipboard modes
describe_clipboard_modes() {
    echo "copy=$clipboard_write_mode, paste=$clipboard_read_mode"
}
