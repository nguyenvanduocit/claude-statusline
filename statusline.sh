#!/bin/bash

# Claude Code Statusline - Optimized version
# Single jq call for parsing, awk for math (no bc spawning)

input=$(cat)

# Extract ALL needed values in single jq call (tab-separated)
IFS=$'\t' read -r model session_id total_cost total_input output_tokens cache_read current_ctx ctx_size < <(
    echo "$input" | jq -r '[
        .model.display_name,
        .session_id,
        (.cost.total_cost_usd // 0),
        (.context_window.total_input_tokens // 0),
        (.context_window.total_output_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        ((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0)),
        (.context_window.context_window_size // 200000)
    ] | @tsv'
)

# Format tokens (K for thousands) - pure bash
format_tokens() {
    local t=$1
    if [ "$t" -ge 1000 ] 2>/dev/null; then
        echo "$((t/1000))k"
    else
        echo "$t"
    fi
}

# Format cost - pure bash/awk
format_cost() {
    local cost=$1
    awk -v c="$cost" 'BEGIN {
        if (c < 0.01) print "<1¢"
        else if (c < 1) printf "%.0f¢", c * 100
        else printf "$%.2f", c
    }'
}

# Session timing
timing_file="$HOME/.claude/session-timing.json"
elapsed_minutes=0
start_time=""

if [ -f "$timing_file" ]; then
    start_time=$(jq -r ".\"$session_id\" // empty" "$timing_file" 2>/dev/null)
    if [ -n "$start_time" ]; then
        now=$(date +%s)
        elapsed_minutes=$(awk -v s="$start_time" -v n="$now" 'BEGIN { printf "%.2f", (n-s)/60 }')
    fi
fi

# Initialize timing if needed (in background)
if [ ! -f "$timing_file" ] || [ -z "$start_time" ]; then
    (
        [ ! -f "$timing_file" ] && echo '{}' > "$timing_file"
        now=$(date +%s)
        tmp=$(mktemp)
        jq --arg sid "$session_id" --argjson time "$now" '.[$sid] //= $time' "$timing_file" > "$tmp" 2>/dev/null && mv "$tmp" "$timing_file"
    ) &
fi

# Cost info
cost_info=""
if awk -v c="$total_cost" 'BEGIN { exit (c > 0) ? 0 : 1 }'; then
    cost_display=$(format_cost "$total_cost")

    # Lifetime data - single jq call
    lifetime_file="$HOME/.claude/lifetime-cost.json"
    lifetime_total=0
    lifetime_minutes=0
    if [ -f "$lifetime_file" ]; then
        read -r lifetime_total lifetime_minutes < <(jq -r '[.total_cost // 0, .total_minutes // 0] | @tsv' "$lifetime_file" 2>/dev/null)
    fi
    [ -z "$lifetime_total" ] && lifetime_total=0
    [ -z "$lifetime_minutes" ] && lifetime_minutes=0
    lifetime_display=$(format_cost "$lifetime_total")

    # Update lifetime (background)
    (
        [ ! -f "$lifetime_file" ] && echo '{"total_cost":0,"total_minutes":0,"sessions":{}}' > "$lifetime_file"
        em=${elapsed_minutes:-0}
        tmp=$(mktemp)
        jq --arg sid "$session_id" --argjson scost "$total_cost" --argjson smins "$em" '
            .sessions[$sid] as $prev |
            if ($scost > ($prev.cost // 0)) or ($smins > ($prev.minutes // 0)) then
                .total_cost += ($scost - ($prev.cost // 0)) |
                .total_minutes += ($smins - ($prev.minutes // 0)) |
                .sessions[$sid] = {cost: $scost, minutes: $smins}
            else . end
        ' "$lifetime_file" > "$tmp" 2>/dev/null && mv "$tmp" "$lifetime_file"
    ) &

    # Burn rate
    burn_info=""
    if awk -v m="$elapsed_minutes" 'BEGIN { exit (m > 0) ? 0 : 1 }'; then
        session_burn=$(awk -v c="$total_cost" -v m="$elapsed_minutes" 'BEGIN { printf "%.1f", (c/m)*100 }')
        session_burn_display="${session_burn}¢"

        if awk -v m="$lifetime_minutes" 'BEGIN { exit (m > 0) ? 0 : 1 }'; then
            lifetime_burn=$(awk -v c="$lifetime_total" -v m="$lifetime_minutes" 'BEGIN { printf "%.1f", (c/m)*100 }')
            burn_info=$'\033[1;38;5;255;48;5;52m'" 🔥 S:${session_burn_display}/m L:${lifetime_burn}¢/m "$'\033[0m'
        else
            burn_info=$'\033[1;38;5;255;48;5;52m'" 🔥 ${session_burn_display}/m "$'\033[0m'
        fi
    fi

    cost_info=$'\033[1;38;5;255;48;5;53m'" 💰 S:${cost_display} L:${lifetime_display} "$'\033[0m'"${burn_info}"
fi

# Agent tokens - single jq call
agent_tokens=0
agent_file="$HOME/.claude/agent-tokens.json"
[ -f "$agent_file" ] && agent_tokens=$(jq -r ".\"$session_id\" // 0" "$agent_file" 2>/dev/null)
[ -z "$agent_tokens" ] && agent_tokens=0

# Context info
context_info=""
if [ "$ctx_size" -gt 0 ] 2>/dev/null; then
    pct=$((current_ctx * 100 / ctx_size))

    input_display=$(format_tokens "$total_input")
    output_display=$(format_tokens "$output_tokens")
    cache_display=$(format_tokens "$cache_read")

    token_info="↑${input_display} ↓${output_display}"
    [ "$cache_read" -gt 0 ] 2>/dev/null && token_info="${token_info} ⚡${cache_display}"
    [ "$agent_tokens" -gt 0 ] 2>/dev/null && token_info="${token_info} 🤖$(format_tokens "$agent_tokens")"

    context_info=$'\033[1;38;5;255;48;5;58m'" 🧠 ${pct}% (${token_info}) "$'\033[0m'
fi

# Output
printf $'\033[1;38;5;255;48;5;24m'" 🤖 %s "$'\033[0m'"%s%s" "$model" "$context_info" "$cost_info"
