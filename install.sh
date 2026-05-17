#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/hooks/dmux-event.sh"
BRIDGE="$SCRIPT_DIR/hooks/dmux-codex-bridge.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
GEMINI_SETTINGS="$HOME/.gemini/settings.json"
STATE_DIR="$HOME/.dmux/state"
PREV_NOTIFY_FILE="$STATE_DIR/previous-codex-notify.txt"
DMUX_SUBSTR="dmux-event.sh"

MODE="${1:-install}"
case "$MODE" in
    install|--install) MODE=install ;;
    uninstall|--uninstall) MODE=uninstall ;;
    *)
        printf '\nUsage: %s [install | --uninstall]\n\n' "$0" >&2
        exit 2
        ;;
esac

c_bold=$'\033[1m'; c_ok=$'\033[32m'; c_skip=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()    { printf '%s\n' "$*"; }
ok()     { printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$*"; }
skip()   { printf '  %s-%s %s\n' "$c_skip" "$c_off" "$*"; }
note()   { printf '  %s%s%s\n' "$c_dim" "$*" "$c_off"; }
header() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }

chmod +x "$HOOK" "$BRIDGE" 2>/dev/null || true

header "🔔 DMUX ${MODE}"

if ! command -v jq >/dev/null 2>&1; then
    printf '  %s!%s jq is required for safe config merging. Install it first:\n' "$c_skip" "$c_off"
    printf '      apt install jq   # or:   brew install jq   # or:   pacman -S jq\n\n'
    exit 1
fi

if [ "$MODE" = "install" ]; then
    if [ -z "${WARP_CLI_AGENT_PROTOCOL_VERSION:-}" ] || [ -z "${WARP_CLIENT_VERSION:-}" ]; then
        printf '  %s!%s WARP_CLI_AGENT_PROTOCOL_VERSION / WARP_CLIENT_VERSION are not set.\n' "$c_skip" "$c_off"
        printf '      Make sure you are running this installer INSIDE Warp Terminal.\n'
        printf '      The hooks will silently no-op in any other terminal.\n\n'
    fi
fi

backup_once() {
    local file="$1"
    [ -f "$file" ] || return 0
    local bak="${file}.bak-dmux-$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$bak"
    note "    backup → $bak"
}

merge_json_hooks() {
    local file="$1" event_name="$2" command="$3" matcher="${4:-}"
    [ -f "$file" ] || echo '{}' > "$file"
    local tmp; tmp="$(mktemp)"
    if [ -n "$matcher" ]; then
        jq --arg event "$event_name" --arg cmd "$command" --arg matcher "$matcher" '
            .hooks //= {} |
            .hooks[$event] //= [] |
            if (.hooks[$event] | map(.hooks // [] | map(.command // "")) | flatten | any(. == $cmd))
            then .
            else .hooks[$event] += [{matcher:$matcher, hooks:[{type:"command", command:$cmd}]}]
            end
        ' "$file" > "$tmp"
    else
        jq --arg event "$event_name" --arg cmd "$command" '
            .hooks //= {} |
            .hooks[$event] //= [] |
            if (.hooks[$event] | map(.hooks // [] | map(.command // "")) | flatten | any(. == $cmd))
            then .
            else .hooks[$event] += [{hooks:[{type:"command", command:$cmd}]}]
            end
        ' "$file" > "$tmp"
    fi
    mv "$tmp" "$file"
}

strip_json_hooks() {
    local file="$1" command_substr="$2"
    [ -f "$file" ] || return 0
    local tmp; tmp="$(mktemp)"
    jq --arg sub "$command_substr" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(
                        .hooks |= (map(select((.command // "") | contains($sub) | not)))
                    ) | map(select((.hooks // []) | length > 0))
                )
            ) | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

set_codex_notify() {
    local target="$1"
    backup_once "$CODEX_CONFIG"
    mkdir -p "$STATE_DIR"
    if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG" 2>/dev/null; then
        local current
        current="$(grep -E '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG" | head -1)"
        if echo "$current" | grep -q "$BRIDGE"; then
            skip "codex notify already points at the DMUX bridge"
            return 0
        fi
        if [ ! -f "$PREV_NOTIFY_FILE" ]; then
            printf '%s\n' "$current" > "$PREV_NOTIFY_FILE"
        fi
        ok "codex notify exists — saved for restore on uninstall"
        note "    previous: $current"
        local inner
        inner="$(echo "$current" | sed -E 's/^[^=]*=[[:space:]]*\[(.*)\][[:space:]]*$/\1/' | tr -d '"' | sed 's/,//g')"
        local inner_path
        inner_path="$(echo "$inner" | awk '{for(i=1;i<=NF;i++){if($i~/\//){print $i;exit}}}')"
        sed -i -E 's|^[[:space:]]*notify[[:space:]]*=.*|notify = ["'"$target"'"]|' "$CODEX_CONFIG"
        if [ -n "$inner_path" ] && [ -f "$inner_path" ]; then
            note "    chain via: export DMUX_CODEX_INNER=$inner_path"
        fi
    else
        printf '__NO_PREVIOUS_NOTIFY__\n' > "$PREV_NOTIFY_FILE"
        echo "notify = [\"$target\"]" >> "$CODEX_CONFIG"
        ok "added codex notify directive"
    fi
}

unset_codex_notify() {
    [ -f "$CODEX_CONFIG" ] || return 0
    grep -q "$BRIDGE" "$CODEX_CONFIG" || return 0
    backup_once "$CODEX_CONFIG"
    if [ -f "$PREV_NOTIFY_FILE" ] && [ "$(head -1 "$PREV_NOTIFY_FILE")" != "__NO_PREVIOUS_NOTIFY__" ]; then
        local prev
        prev="$(head -1 "$PREV_NOTIFY_FILE")"
        local prev_escaped
        prev_escaped="$(printf '%s' "$prev" | sed 's|[\&/]|\\&|g')"
        sed -i -E "s|^[[:space:]]*notify[[:space:]]*=.*|$prev_escaped|" "$CODEX_CONFIG"
        ok "restored codex notify to previous value"
    else
        sed -i -E '\|^[[:space:]]*notify[[:space:]]*=.*dmux-codex-bridge\.sh.*|d' "$CODEX_CONFIG"
        ok "removed DMUX codex notify directive"
    fi
    rm -f "$PREV_NOTIFY_FILE"
}

detect() {
    local label="$1" path="$2" bin="$3"
    [ -e "$path" ] || command -v "$bin" >/dev/null 2>&1
}

WIRE_CLAUDE=false; WIRE_CODEX=false; WIRE_OPENCODE=false; WIRE_GEMINI=false
detect "Claude Code" "$HOME/.claude"        claude    && WIRE_CLAUDE=true
detect "Codex CLI"   "$HOME/.codex"         codex     && WIRE_CODEX=true
detect "OpenCode"    "$HOME/.config/opencode" opencode && WIRE_OPENCODE=true
detect "Gemini CLI"  "$HOME/.gemini"        gemini    && WIRE_GEMINI=true

header "Detected agents"
$WIRE_CLAUDE   && ok "Claude Code"  || skip "Claude Code (not installed)"
$WIRE_CODEX    && ok "Codex CLI"    || skip "Codex CLI (not installed)"
$WIRE_OPENCODE && ok "OpenCode"     || skip "OpenCode (not installed)"
$WIRE_GEMINI   && ok "Gemini CLI"   || skip "Gemini CLI (not installed)"

if ! ($WIRE_CLAUDE || $WIRE_CODEX || $WIRE_OPENCODE || $WIRE_GEMINI); then
    printf '\nNo supported agents found. Install one of: claude / codex / opencode / gemini.\n\n' >&2
    exit 1
fi

if [ "$MODE" = "install" ]; then
    printf '\n  %s? %sProceed with %sinstall%s for the agents above? [Y/n] ' "$c_bold" "$c_off" "$c_bold" "$c_off"
else
    printf '\n  %s? %sProceed with %suninstall%s for the agents above? [Y/n] ' "$c_bold" "$c_off" "$c_bold" "$c_off"
fi
read -r ANS || ANS=""
case "${ANS:-Y}" in
    n|N|no|No|NO) say "Aborted."; exit 0 ;;
esac

if [ "$MODE" = "install" ]; then
    header "Wiring agents"
    if $WIRE_CLAUDE; then
        backup_once "$CLAUDE_SETTINGS"
        merge_json_hooks "$CLAUDE_SETTINGS" SessionStart      "\$HOME/.dmux/dmux-event.sh session_start claude"      ""
        merge_json_hooks "$CLAUDE_SETTINGS" Stop              "\$HOME/.dmux/dmux-event.sh stop claude"               ""
        merge_json_hooks "$CLAUDE_SETTINGS" Notification      "\$HOME/.dmux/dmux-event.sh idle_prompt claude"        ""
        merge_json_hooks "$CLAUDE_SETTINGS" PermissionRequest "\$HOME/.dmux/dmux-event.sh permission_request claude" ""
        ok "Claude Code wired"
    fi
    if $WIRE_CODEX; then
        backup_once "$CODEX_HOOKS"
        merge_json_hooks "$CODEX_HOOKS" SessionStart      "\$HOME/.dmux/dmux-event.sh session_start codex"      "startup|resume"
        merge_json_hooks "$CODEX_HOOKS" PermissionRequest "\$HOME/.dmux/dmux-event.sh permission_request codex" ""
        ok "Codex hooks.json wired"
        set_codex_notify "$BRIDGE"
    fi
    if $WIRE_OPENCODE; then
        mkdir -p "$(dirname "$OPENCODE_CONFIG")"
        backup_once "$OPENCODE_CONFIG"
        merge_json_hooks "$OPENCODE_CONFIG" SessionStart "\$HOME/.dmux/dmux-event.sh session_start opencode" ""
        merge_json_hooks "$OPENCODE_CONFIG" Stop         "\$HOME/.dmux/dmux-event.sh stop opencode"          ""
        ok "OpenCode wired"
    fi
    if $WIRE_GEMINI; then
        backup_once "$GEMINI_SETTINGS"
        merge_json_hooks "$GEMINI_SETTINGS" session_start      "\$HOME/.dmux/dmux-event.sh session_start gemini"      ""
        merge_json_hooks "$GEMINI_SETTINGS" stop               "\$HOME/.dmux/dmux-event.sh stop gemini"               ""
        merge_json_hooks "$GEMINI_SETTINGS" user_prompt_submit "\$HOME/.dmux/dmux-event.sh prompt_submit gemini"      ""
        ok "Gemini CLI wired"
    fi

    header "Done"
    say "  Restart your agent sessions to pick up the new hooks."
    say ""
    say "  Smoke test:"
    printf '    %s%s stop claude <<< '"'"'{}'"'"'%s\n' "$c_dim" "$HOOK" "$c_off"
    printf '    %stail -1 \$HOME/.dmux/dmux.log%s\n\n'   "$c_dim"        "$c_off"
else
    header "Removing DMUX hooks"
    if $WIRE_CLAUDE   && [ -f "$CLAUDE_SETTINGS" ];   then backup_once "$CLAUDE_SETTINGS";   strip_json_hooks "$CLAUDE_SETTINGS"   "$DMUX_SUBSTR"; ok "Claude Code unwired";       fi
    if $WIRE_CODEX    && [ -f "$CODEX_HOOKS" ];       then backup_once "$CODEX_HOOKS";       strip_json_hooks "$CODEX_HOOKS"       "$DMUX_SUBSTR"; ok "Codex hooks.json unwired";  fi
    if $WIRE_CODEX; then unset_codex_notify; fi
    if $WIRE_OPENCODE && [ -f "$OPENCODE_CONFIG" ];   then backup_once "$OPENCODE_CONFIG";   strip_json_hooks "$OPENCODE_CONFIG"   "$DMUX_SUBSTR"; ok "OpenCode unwired";          fi
    if $WIRE_GEMINI   && [ -f "$GEMINI_SETTINGS" ];   then backup_once "$GEMINI_SETTINGS";   strip_json_hooks "$GEMINI_SETTINGS"   "$DMUX_SUBSTR"; ok "Gemini CLI unwired";        fi
    say ""
    say "  All DMUX wiring removed. Your other hooks are preserved."
    say "  This repo can be safely deleted: rm -rf $SCRIPT_DIR"
    say ""
fi
