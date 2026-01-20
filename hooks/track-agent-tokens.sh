#!/bin/bash
# Track sub-agent tokens from Task tool results
# Writes to ~/.claude/agent-tokens.json for statusline to read

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id')

# Extract totalTokens from tool_response
total_tokens=$(echo "$input" | jq -r '.tool_response.totalTokens // 0')

if [ "$total_tokens" = "0" ] || [ "$total_tokens" = "null" ]; then
    exit 0
fi

# Update agent tokens file
tokens_file="$HOME/.claude/agent-tokens.json"
lockfile="$HOME/.claude/agent-tokens.lock"

(
    flock -x 200

    if [ ! -f "$tokens_file" ]; then
        echo '{}' > "$tokens_file"
    fi

    data=$(cat "$tokens_file")
    current=$(echo "$data" | jq -r ".\"$session_id\" // 0")
    new_total=$((current + total_tokens))

    echo "$data" | jq --arg sid "$session_id" --argjson tokens "$new_total" \
        '.[$sid] = $tokens' > "$tokens_file"

) 200>"$lockfile"
