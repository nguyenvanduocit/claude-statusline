# Claude Code Statusline

A custom statusline for Claude Code with cost tracking, burn rate monitoring, and git integration.

![statusline](https://img.shields.io/badge/Claude_Code-Statusline-blue)

## Features

- **Cost Tracking** - Real-time session cost calculation based on model pricing
- **Lifetime Stats** - Tracks total spending across all sessions
- **Burn Rate** - Shows cost per minute (session and lifetime average)
- **Git Integration** - Displays current branch with insertions/deletions
- **Context Usage** - Shows context window percentage

## Preview

```
🌿 main +15 -3  🤖 Opus  🔋 45%  💰 $1.25 (↑$15.50)  🔥 S:2.3¢/m L:1.5¢/m
```

## Installation

1. Download the script:

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/nguyenvanduocit/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

3. Restart Claude Code

## Data Files

The statusline creates these files in `~/.claude/`:

- `lifetime-cost.json` - Tracks total cost across all sessions
- `session-timing.json` - Tracks session start times for burn rate calculation

To reset stats:

```bash
rm ~/.claude/lifetime-cost.json ~/.claude/session-timing.json
```

## Model Pricing (January 2025)

| Model      | Input (per 1M) | Output (per 1M) |
| ---------- | -------------- | --------------- |
| Opus 4.5   | $15.00         | $75.00          |
| Sonnet 4.5 | $3.00          | $15.00          |
| Sonnet 3.5 | $3.00          | $15.00          |
| Haiku 3.5  | $0.80          | $4.00           |

## Dependencies

- `jq` - JSON processor
- `bc` - Calculator
- `git` - For branch/diff info

## License

MIT
