#!/bin/bash

# Configuration
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYZER_PROMPT="$SKILL_DIR/prompts/analyze.txt"
BRIEFING_PROMPT="$SKILL_DIR/prompts/briefing.txt"

# Load env vars if present (e.g. TARGET_NUMBER)
if [ -f "$SKILL_DIR/.env" ]; then
  source "$SKILL_DIR/.env"
fi

# 1. Fetch Recent Saves (Last 24h)
echo "Fetching recent saves from Readwise..."
RECENT_JSON=$(curl -s -H "Authorization: Token $READWISE_TOKEN" "https://readwise.io/api/v3/list/?location=new&page_size=10")

# Check if empty or error
COUNT=$(echo "$RECENT_JSON" | jq '.results | length')
if [ "$COUNT" -eq "0" ] || [ -z "$COUNT" ]; then
  echo "No new articles found. Exiting."
  exit 0
fi

# Extract titles for analysis
TITLES=$(echo "$RECENT_JSON" | jq -r '.results[].title')

# Model selection (default to flash for speed, override with GEMINI_MODEL)
MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"

# 2. Analyze Topic
echo "Analyzing reading patterns (using $MODEL)..."
# Using gemini directly with a clean pipe
QUERY=$(echo -e "SYSTEM: $(cat "$ANALYZER_PROMPT")\n\nARTICLES:\n$TITLES" | gemini -m "$MODEL" -o text 2>/dev/null | tail -n 1 | tr -d '\n')

# If the query is empty or failed, fallback
if [ -z "$QUERY" ]; then
  QUERY="AI and Productivity"
fi
echo "Topic focus: $QUERY"

# 3. Search Archive
echo "Searching archive for context on: $QUERY"
# Fetching 20 items to balance context density and execution speed
ARCHIVE_JSON=$(curl -s -H "Authorization: Token $READWISE_TOKEN" "https://readwise.io/api/v3/list/?q=${QUERY// /%20}&page_size=20")

# 4. Generate Briefing
echo "Synthesizing deep-dive briefing..."
CONTEXT_DATA="TOPIC: $QUERY

RECENT_SAVES (Last 24h):
$(echo "$RECENT_JSON" | jq -r '.results[] | "Title: \(.title)\nAuthor: \(.author)\nType: \(.category)\nSaved: \(.saved_at)\nSummary: \(.summary)\n"')

ARCHIVE_HITS (Historical context):
$(echo "$ARCHIVE_JSON" | jq -r '.results[] | "Title: \(.title)\nAuthor: \(.author)\nType: \(.category)\nSaved: \(.saved_at)\nSummary: \(.summary)\nURL: \(.url)\n"')

GOAL: Provide at least 5 deep dive connections from the archive, ordered by save date."

# Capture multi-line response
# We find where the actual content starts (skipping initialization logs)
BRIEF=$(gemini -m "$MODEL" -o text 2>/dev/null <<EOF
SYSTEM: $(cat "$BRIEFING_PROMPT")

CONTEXT:
$CONTEXT_DATA
EOF
)

# 5. Output
if [ -n "$BRIEF" ]; then
  # If TARGET_NUMBER is set, send via WhatsApp (legacy support)
  if [ -n "$TARGET_NUMBER" ]; then
    echo "Delivering to WhatsApp..."
    clawdbot message send --target "$TARGET_NUMBER" --message "$BRIEF"
  else
    # Otherwise, just print to stdout for the agent to capture
    echo "$BRIEF"
  fi
else
  echo "Error: Briefing generation failed (empty response)."
  exit 1
fi
