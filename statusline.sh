#!/bin/bash

# Lifetime cost tracking
# ====================
# Cost data stored in: ~/.claude/lifetime-cost.json
# To reset: rm ~/.claude/lifetime-cost.json
# To view: cat ~/.claude/lifetime-cost.json | jq
#
# Session timing & burn rate
# ==========================
# Session timing stored in: ~/.claude/session-timing.json
# Tracks session start time to calculate cost per minute (burn rate)
# Tracks both session burn rate and lifetime average burn rate
# To reset: rm ~/.claude/session-timing.json ~/.claude/lifetime-cost.json

# Read JSON input from stdin
input=$(cat)

# Extract basic info
model=$(echo "$input" | jq -r '.model.display_name')
model_id=$(echo "$input" | jq -r '.model.id')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
session_id=$(echo "$input" | jq -r '.session_id')

# Get git branch and changes if in a git repo
git_info=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        # Get lines of code changes using git diff --stat
        diff_stat=$(git -C "$cwd" --no-optional-locks diff --stat 2>/dev/null | tail -1)

        # Parse insertions and deletions from the last line
        # Format: " X files changed, Y insertions(+), Z deletions(-)"
        insertions=$(echo "$diff_stat" | grep -o '[0-9]\+ insertion' | grep -o '[0-9]\+')
        deletions=$(echo "$diff_stat" | grep -o '[0-9]\+ deletion' | grep -o '[0-9]\+')

        # Build changes info (only show if there are changes)
        changes=""
        change_parts=""
        [ -n "$insertions" ] && change_parts="${change_parts} +${insertions}"
        [ -n "$deletions" ] && change_parts="${change_parts} -${deletions}"
        [ -n "$change_parts" ] && changes="$change_parts"

        git_info="$(printf '\033[1;38;5;255;48;5;22m') 🌿 ${branch}${changes} $(printf '\033[0m')"
    fi
fi

# Calculate cost based on model pricing (per million tokens)
# Pricing as of January 2025
get_price() {
    local model_id="$1"
    local token_type="$2"  # input or output

    case "$model_id" in
        claude-opus-4-5*)
            [ "$token_type" = "input" ] && echo "15.00" || echo "75.00"
            ;;
        claude-sonnet-4-5*)
            [ "$token_type" = "input" ] && echo "3.00" || echo "15.00"
            ;;
        claude-3-5-sonnet*)
            [ "$token_type" = "input" ] && echo "3.00" || echo "15.00"
            ;;
        claude-3-5-haiku*)
            [ "$token_type" = "input" ] && echo "0.80" || echo "4.00"
            ;;
        claude-3-opus*)
            [ "$token_type" = "input" ] && echo "15.00" || echo "75.00"
            ;;
        claude-3-sonnet*)
            [ "$token_type" = "input" ] && echo "3.00" || echo "15.00"
            ;;
        claude-3-haiku*)
            [ "$token_type" = "input" ] && echo "0.25" || echo "1.25"
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Update lifetime cost and minutes tracking
update_lifetime_cost() {
    local session_cost="$1"
    local session_id="$2"
    local session_minutes="$3"
    local lifetime_file="$HOME/.claude/lifetime-cost.json"
    local lockfile="$HOME/.claude/lifetime-cost.lock"

    # Ensure directory exists
    mkdir -p "$HOME/.claude"

    # Use flock for safe concurrent access
    (
        flock -x 200

        # Initialize file if doesn't exist
        if [ ! -f "$lifetime_file" ]; then
            echo '{"total_cost":0,"total_minutes":0,"sessions":{}}' > "$lifetime_file"
        fi

        # Read current data
        local data=$(cat "$lifetime_file")
        local prev_session_data=$(echo "$data" | jq -r ".sessions[\"$session_id\"] // {}")
        local prev_session_cost=$(echo "$prev_session_data" | jq -r ".cost // 0")
        local prev_session_minutes=$(echo "$prev_session_data" | jq -r ".minutes // 0")

        # Only update if session cost or minutes increased (avoid double-counting on refresh)
        if (( $(echo "$session_cost > $prev_session_cost" | bc -l) )) || \
           (( $(echo "$session_minutes > $prev_session_minutes" | bc -l) )); then
            local cost_delta=$(echo "$session_cost - $prev_session_cost" | bc)
            local minutes_delta=$(echo "$session_minutes - $prev_session_minutes" | bc)
            local new_total_cost=$(echo "$data" | jq -r ".total_cost + $cost_delta")
            local new_total_minutes=$(echo "$data" | jq -r ".total_minutes + $minutes_delta")

            # Update JSON with new values
            echo "$data" | jq \
                --arg sid "$session_id" \
                --argjson scost "$session_cost" \
                --argjson smins "$session_minutes" \
                --argjson tcost "$new_total_cost" \
                --argjson tmins "$new_total_minutes" \
                '.sessions[$sid] = {cost: $scost, minutes: $smins} | .total_cost = $tcost | .total_minutes = $tmins' \
                > "$lifetime_file"
        fi

    ) 200>"$lockfile"
}

# Track session start time and calculate burn rate
track_session_timing() {
    local session_id="$1"
    local session_file="$HOME/.claude/session-timing.json"
    local lockfile="$HOME/.claude/session-timing.lock"

    mkdir -p "$HOME/.claude"

    (
        flock -x 200

        if [ ! -f "$session_file" ]; then
            echo '{}' > "$session_file"
        fi

        local data=$(cat "$session_file")
        local start_time=$(echo "$data" | jq -r ".\"$session_id\" // empty")

        if [ -z "$start_time" ]; then
            # First time seeing this session, record start time
            local now=$(date +%s)
            echo "$data" | jq --arg sid "$session_id" --argjson time "$now" \
                '.[$sid] = $time' > "$session_file"
            echo "0"  # Return 0 for first call
        else
            # Calculate elapsed minutes
            local now=$(date +%s)
            local elapsed_seconds=$((now - start_time))
            local elapsed_minutes=$(echo "scale=2; $elapsed_seconds / 60" | bc)
            echo "$elapsed_minutes"
        fi

    ) 200>"$lockfile"
}

# Calculate context window percentage and cost
context_info=""
cost_info=""
total_tokens=$(echo "$input" | jq '.context_window.total_input_tokens + .context_window.total_output_tokens')

if [ "$total_tokens" != "null" ] && [ "$total_tokens" -gt 0 ]; then
    # Get pricing
    input_price=$(get_price "$model_id" "input")
    output_price=$(get_price "$model_id" "output")

    # Calculate total cost
    total_input=$(echo "$input" | jq '.context_window.total_input_tokens')
    total_output=$(echo "$input" | jq '.context_window.total_output_tokens')

    # Cost = (tokens / 1,000,000) * price_per_million
    input_cost=$(echo "scale=4; $total_input / 1000000 * $input_price" | bc)
    output_cost=$(echo "scale=4; $total_output / 1000000 * $output_price" | bc)
    total_cost=$(echo "scale=4; $input_cost + $output_cost" | bc)

    # Get elapsed minutes for this session
    elapsed_minutes=$(track_session_timing "$session_id")

    # Update lifetime cost and minutes tracking
    update_lifetime_cost "$total_cost" "$session_id" "$elapsed_minutes"

    # Get lifetime totals
    lifetime_file="$HOME/.claude/lifetime-cost.json"
    if [ -f "$lifetime_file" ]; then
        lifetime_data=$(cat "$lifetime_file")
        lifetime_total=$(echo "$lifetime_data" | jq -r '.total_cost')
        lifetime_minutes=$(echo "$lifetime_data" | jq -r '.total_minutes')
    else
        lifetime_total="0"
        lifetime_minutes="0"
    fi

    # Format session cost (show cents if under $1, dollars otherwise)
    if (( $(echo "$total_cost < 0.01" | bc -l) )); then
        cost_display="<1¢"
    elif (( $(echo "$total_cost < 1" | bc -l) )); then
        cents=$(printf "%.0f" $(echo "$total_cost * 100" | bc))
        cost_display="${cents}¢"
    else
        cost_display=$(printf "\$%.2f" "$total_cost")
    fi

    # Format lifetime cost
    if (( $(echo "$lifetime_total < 0.01" | bc -l) )); then
        lifetime_display="<1¢"
    elif (( $(echo "$lifetime_total < 1" | bc -l) )); then
        cents=$(printf "%.0f" $(echo "$lifetime_total * 100" | bc))
        lifetime_display="${cents}¢"
    else
        lifetime_display=$(printf "\$%.2f" "$lifetime_total")
    fi

    # Calculate burn rates (session and lifetime average)
    burn_rate_info=""
    if [ -n "$elapsed_minutes" ] && (( $(echo "$elapsed_minutes > 0" | bc -l) )); then
        # Session burn rate
        session_burn_rate=$(echo "scale=4; $total_cost / $elapsed_minutes" | bc)

        # Format session burn rate
        if (( $(echo "$session_burn_rate < 0.01" | bc -l) )); then
            session_burn_display="<1¢"
        elif (( $(echo "$session_burn_rate < 1" | bc -l) )); then
            burn_cents=$(printf "%.1f" $(echo "$session_burn_rate * 100" | bc))
            session_burn_display="${burn_cents}¢"
        else
            session_burn_display=$(printf "\$%.1f" "$session_burn_rate")
        fi

        # Lifetime average burn rate
        lifetime_burn_display=""
        if [ -n "$lifetime_minutes" ] && (( $(echo "$lifetime_minutes > 0" | bc -l) )); then
            lifetime_burn_rate=$(echo "scale=4; $lifetime_total / $lifetime_minutes" | bc)

            # Format lifetime burn rate
            if (( $(echo "$lifetime_burn_rate < 0.01" | bc -l) )); then
                lifetime_burn_display="<1¢"
            elif (( $(echo "$lifetime_burn_rate < 1" | bc -l) )); then
                burn_cents=$(printf "%.1f" $(echo "$lifetime_burn_rate * 100" | bc))
                lifetime_burn_display="${burn_cents}¢"
            else
                lifetime_burn_display=$(printf "\$%.1f" "$lifetime_burn_rate")
            fi

            # Display format: 🔥 S:2.3¢/m L:1.5¢/m
            burn_rate_info="$(printf '\033[1;38;5;255;48;5;52m') 🔥 S:${session_burn_display}/m L:${lifetime_burn_display}/m $(printf '\033[0m')"
        else
            # No lifetime data yet, show session only
            burn_rate_info="$(printf '\033[1;38;5;255;48;5;52m') 🔥 ${session_burn_display}/m $(printf '\033[0m')"
        fi
    fi

    cost_info="$(printf '\033[1;38;5;255;48;5;53m') 💰 ${cost_display} (↑${lifetime_display}) $(printf '\033[0m')${burn_rate_info}"
fi

# Calculate context window percentage
usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" != "null" ]; then
    current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    size=$(echo "$input" | jq '.context_window.context_window_size')
    if [ "$size" -gt 0 ]; then
        pct=$((current * 100 / size))
        context_info="$(printf '\033[1;38;5;255;48;5;58m') 🔋 ${pct}% $(printf '\033[0m')"
    fi
fi

# Build status line: git branch +added ~modified -deleted | model | context% | cost
printf "%s$(printf '\033[1;38;5;255;48;5;24m') 🤖 %s $(printf '\033[0m')%s%s" "$git_info" "$model" "$context_info" "$cost_info"
