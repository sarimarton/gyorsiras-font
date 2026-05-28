name: Auto-dev PM

on:
  schedule:
    - cron: '0 */6 * * *'   # Every 6 hours
  workflow_dispatch:
    inputs:
      user_message:
        description: "Message or instruction to the PM agent (optional)"
        required: false
        type: string
      skip_usage_check:
        description: "Skip the Claude usage threshold check"
        required: false
        type: boolean
        default: false

concurrency:
  group: auto-dev-pm
  cancel-in-progress: false

permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read

jobs:
  # ════════════════════════════════════════════════════════════
  # Job 1: Check Claude usage budget
  # ════════════════════════════════════════════════════════════
  check-usage:
    runs-on: [self-hosted]
    outputs:
      ok: ${{ steps.check.outputs.ok }}
    steps:
      - name: Check Claude tier usage bucket
        id: check
        run: |
          if [[ "${{ inputs.skip_usage_check }}" == "true" ]]; then
            echo "skip_usage_check requested — bypassing threshold"
            echo "ok=true" >> $GITHUB_OUTPUT
            exit 0
          fi

          GLOBAL_CONFIG="$HOME/.config/claude-toolkit/global.json"
          BAILOUT_PCT=$(jq -r '.bailout_pct // empty' "$GLOBAL_CONFIG" 2>/dev/null | head -n 1)
          BAILOUT_PCT="${BAILOUT_PCT:-50}"

          USAGE_FILE="/tmp/claude-usage.json"
          if [[ ! -f "$USAGE_FILE" ]]; then
            echo "Usage file not found — assuming bucket available"
            echo "ok=true" >> $GITHUB_OUTPUT
            exit 0
          fi

          PCT=$(python3 -c "import json; d=json.load(open('$USAGE_FILE')); print(d.get('pct', 0))" 2>/dev/null || echo "0")
          echo "Current usage: ${PCT}%  (threshold: ${BAILOUT_PCT}%)"

          if (( PCT >= BAILOUT_PCT )); then
            echo "Usage too high (${PCT}% >= ${BAILOUT_PCT}%) — skipping this run"
            echo "ok=false" >> $GITHUB_OUTPUT
          else
            echo "ok=true" >> $GITHUB_OUTPUT
          fi

  # ════════════════════════════════════════════════════════════
  # Job 2: PM agent run
  # ════════════════════════════════════════════════════════════
  pm:
    needs: check-usage
    if: needs.check-usage.outputs.ok == 'true'
    runs-on: [self-hosted]

    env:
      WORK_DIR: /tmp/auto-dev-pm

    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Configure git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Extend PATH for self-hosted runner
        run: echo "$HOME/.local/bin" >> $GITHUB_PATH

      - name: Ensure PM label exists
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          gh label create "ai"       --color "1d76db" --description "Auto-dev: pool identifier"   --force
          gh label create "ai:epic"  --color "e99695" --description "Auto-dev: epic/kickoff"      --force
          gh label create "ai:ready" --color "0e8a16" --description "Auto-dev: ready for PR"      --force

      - name: Determine cursor
        id: cursor
        env:
          GH_REPO: ${{ github.repository }}
        run: |
          STATE_DIR="$HOME/Documents/state/claude-toolkit/auto-dev"
          mkdir -p "$STATE_DIR"
          REPO_SLUG="${GH_REPO//\//-}"
          CURSOR_FILE="$STATE_DIR/${REPO_SLUG}-pm-cursor.txt"

          # Capture run start BEFORE fetching, so concurrent comments aren't lost
          RUN_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

          if [[ -f "$CURSOR_FILE" ]]; then
            CURSOR=$(cat "$CURSOR_FILE")
          else
            # Initial backfill: 30 days
            CURSOR=$(date -u -v-30d +"%Y-%m-%dT%H:%M:%SZ")
          fi

          echo "cursor=$CURSOR"           >> $GITHUB_OUTPUT
          echo "run_start=$RUN_START"     >> $GITHUB_OUTPUT
          echo "cursor_file=$CURSOR_FILE" >> $GITHUB_OUTPUT
          echo "Cursor: $CURSOR  →  Run start: $RUN_START"

      - name: Collect repo state
        id: collect
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          CURSOR: ${{ steps.cursor.outputs.cursor }}
        run: |
          mkdir -p "$WORK_DIR"

          # Open issues — metadata only (comments fetched separately via cursor)
          gh issue list \
            --state open \
            --json number,title,body,labels,createdAt,updatedAt \
            --limit 100 \
            > "$WORK_DIR/issues.json"

          # Open PRs — metadata only
          gh pr list \
            --state open \
            --json number,title,body,labels,createdAt,updatedAt,headRefName \
            --limit 50 \
            > "$WORK_DIR/prs.json"

          # New issue comments since cursor (issue conversation comments, not review comments)
          gh api "repos/$GH_REPO/issues/comments?since=$CURSOR&per_page=100" \
            | jq -c '[.[] | {
                issue_number: (.issue_url | capture("/issues/(?<n>[0-9]+)") | .n | tonumber),
                author: .user.login,
                created_at: .created_at,
                body: .body
              }]' \
            > "$WORK_DIR/new-issue-comments.json"

          # New PR review comments since cursor
          gh api "repos/$GH_REPO/pulls/comments?since=$CURSOR&per_page=100" \
            | jq -c '[.[] | {
                pr_number: (.pull_request_url | capture("/pulls/(?<n>[0-9]+)") | .n | tonumber),
                author: .user.login,
                created_at: .created_at,
                path: .path,
                body: .body
              }]' \
            > "$WORK_DIR/new-pr-comments.json"

          # Recent activity (last 20 entries for this repo)
          STATE_DIR="$HOME/Documents/state/claude-toolkit/auto-dev"
          ACTIVITY_LOG="$STATE_DIR/activity.jsonl"
          RECENT_ACTIVITY=""
          if [[ -f "$ACTIVITY_LOG" ]]; then
            RECENT_ACTIVITY=$(grep "\"$GH_REPO\"" "$ACTIVITY_LOG" 2>/dev/null | tail -20 || true)
          fi
          printf '%s\n' "$RECENT_ACTIVITY" > "$WORK_DIR/activity.txt"

          ISSUE_COUNT=$(jq 'length' "$WORK_DIR/issues.json")
          PR_COUNT=$(jq 'length' "$WORK_DIR/prs.json")
          NEW_IC=$(jq 'length' "$WORK_DIR/new-issue-comments.json")
          NEW_PC=$(jq 'length' "$WORK_DIR/new-pr-comments.json")
          echo "Collected $ISSUE_COUNT open issues, $PR_COUNT open PRs, $NEW_IC new issue comments, $NEW_PC new PR comments"

      - name: Run PM agent with Claude
        id: pm_agent
        timeout-minutes: 20
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          USER_MESSAGE: ${{ inputs.user_message }}
        run: |
          ISSUES=$(cat "$WORK_DIR/issues.json")
          PRS=$(cat "$WORK_DIR/prs.json")
          NEW_ISSUE_COMMENTS=$(cat "$WORK_DIR/new-issue-comments.json")
          NEW_PR_COMMENTS=$(cat "$WORK_DIR/new-pr-comments.json")
          ACTIVITY=$(cat "$WORK_DIR/activity.txt")

          ARCH_CONTEXT=""
          [[ -f "ARCHITECTURE.md" ]] && ARCH_CONTEXT=$(cat ARCHITECTURE.md)
          README_CONTEXT=""
          [[ -f "README.md" ]] && README_CONTEXT=$(cat README.md)

          {
            echo "You are the **PM agent** for this GitHub repository."
            echo "Your role: high-level project management — backlog health, communication, and documentation."
            echo "You do NOT implement code. The auto-dev workflow handles implementation."
            echo ""
            echo "## Your responsibilities"
            echo ""
            echo "1. **Backlog health** — Review all open issues and PRs. Identify:"
            echo "   - Issues that are stuck (blocked, no activity for days, unclear)"
            echo "   - Issues that need splitting (too large for one PR)"
            echo "   - Missing sub-tasks that should be created"
            echo "   - Issues that can be closed (already done via a PR)"
            echo ""
            echo "2. **Course correction** — Read the NEW comments (since last PM run) below."
            echo "   - These are comments you have NOT yet seen — deterministically filtered by timestamp cursor."
            echo "   - If the repo owner (non-bot) left feedback, questions, or concerns, act on them."
            echo "   - Respond to questions, adjust labels, create clarification issues as needed."
            echo "   - Bot/PM comments are marked 🤖 — skip those, they are your own past output."
            echo ""
            echo "3. **Documentation & housekeeping** — You are a contributor for cross-cutting, non-feature work."
            echo "   - README, ARCHITECTURE, CONTRIBUTING, docs/**.md, and non-workflow .github/ config are YOURS."
            echo "   - Commit these DIRECTLY to main via 'commit_to_main' (no PR) — they don't need a feature branch."
            echo "   - These are exactly the things that don't belong in a feature PR: general docs, project vision,"
            echo "     devops/config, story-less housekeeping. Owning them here keeps feature PRs focused and avoids"
            echo "     README merge conflicts between parallel PRs."
            echo "   - If a feature PR is adding a project-wide README/vision doc, comment to redirect it (that work"
            echo "     is yours, not the PR's)."
            echo "   - Write a README if it is missing or a stub; base it on ARCHITECTURE.md, open issues, and the"
            echo "     codebase. Only write docs that add real value (skip if already substantive)."
            echo ""
            echo "4. **User message** — If a user_message was provided, treat it as a priority instruction."
            echo "   It may ask you to create issues, reprioritize, comment on a PR, or anything else."
            echo ""
            echo "## Actions you can take"
            echo ""
            echo "Return a JSON object with an 'actions' array. Each action has a 'type' and type-specific fields:"
            echo ""
            echo "Each action must have a 'rationale' field: 1-2 sentences in Hungarian explaining WHY."
            echo ""
            echo '- Create issue:   {"type":"create_issue","title":"...","body":"...","labels":["ai"],"rationale":"..."}'
            echo '- Comment issue:  {"type":"comment_issue","number":123,"body":"...","rationale":"..."}'
            echo '- Comment PR:     {"type":"comment_pr","number":123,"body":"...","rationale":"..."}'
            echo '- Add label:      {"type":"add_label","target":"issue","number":123,"label":"ai:blocked","rationale":"..."}'
            echo '- Remove label:   {"type":"remove_label","target":"issue","number":123,"label":"ai:ready","rationale":"..."}'
            echo '- Commit to main: {"type":"commit_to_main","files":[{"path":"README.md","content":"full file content"}],"message":"docs: ...","rationale":"..."}'
            echo '- No action:      {"type":"noop","rationale":"Everything looks healthy"}'
            echo ""
            echo "Also include at the top level:"
            echo '- "summary": one-line summary in Hungarian (max 80 chars) — shown in menubar.'
            echo '- "report": markdown report in Hungarian — shown in GitHub Actions step summary.'
            echo "   Include: what you considered, what you decided to do and why, what you intentionally"
            echo "   skipped (e.g. 'majdnem kommenteltem #12-re, de a user kérdése még friss, hagyom'),"
            echo "   any concerns or things to watch."
            echo ""
            echo "RULES:"
            echo "- Take the minimum necessary actions. Don't create issues for things already covered."
            echo "- Always include a 'noop' if you have no meaningful action to take."
            echo "- Comments must be written in the same language as the issue/PR they respond to."
            echo "- For 'commit_to_main': only allowed paths are README.md, ARCHITECTURE.md, CONTRIBUTING.md,"
            echo "  docs/**.md, and non-workflow .github/ files. NEVER commit code or .github/workflows/ here."
            echo "- For 'create_issue': always include the 'ai' label so auto-dev picks it up."
            echo "- Do not create issues that duplicate existing open issues."
            echo ""
            if [[ -n "$USER_MESSAGE" ]]; then
              echo "## User instruction (PRIORITY)"
              echo ""
              printf '%s\n' "$USER_MESSAGE"
              echo ""
            fi
            echo "## Current repo state"
            echo ""
            if [[ -n "$ARCH_CONTEXT" ]]; then
              echo "### ARCHITECTURE.md"
              echo ""
              printf '%s\n' "$ARCH_CONTEXT"
              echo ""
            fi
            echo "### README.md"
            echo ""
            if [[ -n "$README_CONTEXT" ]]; then
              printf '%s\n' "$README_CONTEXT"
            else
              echo "(missing)"
            fi
            echo ""
            echo "### Open issues (metadata, no comments)"
            echo ""
            printf '%s\n' "$ISSUES"
            echo ""
            echo "### Open PRs (metadata, no comments)"
            echo ""
            printf '%s\n' "$PRS"
            echo ""
            echo "### NEW issue comments since last PM run (act on these)"
            echo ""
            printf '%s\n' "$NEW_ISSUE_COMMENTS"
            echo ""
            echo "### NEW PR review comments since last PM run (act on these)"
            echo ""
            printf '%s\n' "$NEW_PR_COMMENTS"
            echo ""
            echo "### Recent activity log"
            echo ""
            if [[ -n "$ACTIVITY" ]]; then
              printf '%s\n' "$ACTIVITY"
            else
              echo "(no activity yet)"
            fi
          } > "$WORK_DIR/pm-prompt.txt"

          SCHEMA='{
            "type": "object",
            "properties": {
              "summary": {"type":"string"},
              "report":  {"type":"string"},
              "actions": {
                "type": "array",
                "items": {
                  "type": "object",
                  "properties": {
                    "type": {"type":"string","enum":["create_issue","comment_issue","comment_pr","add_label","remove_label","commit_to_main","noop"]},
                    "title":     {"type":"string"},
                    "body":      {"type":"string"},
                    "files":     {"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
                    "message":   {"type":"string"},
                    "labels":    {"type":"array","items":{"type":"string"}},
                    "number":    {"type":"integer"},
                    "target":    {"type":"string","enum":["issue","pr"]},
                    "label":     {"type":"string"},
                    "rationale": {"type":"string"}
                  },
                  "required": ["type","rationale"]
                }
              }
            },
            "required": ["summary","report","actions"]
          }'

          RESULT=$(claude --dangerously-skip-permissions --model claude-opus-4-7 --output-format json --json-schema "$SCHEMA" -p "$(cat "$WORK_DIR/pm-prompt.txt")" 2>"$WORK_DIR/pm-stderr.txt") || true
          echo "$RESULT" > "$WORK_DIR/pm-result.json"

          ACTION_COUNT=$(jq '.structured_output.actions | length' "$WORK_DIR/pm-result.json" 2>/dev/null || echo "0")
          echo "PM agent returned $ACTION_COUNT action(s)"
          echo "action_count=$ACTION_COUNT" >> $GITHUB_OUTPUT

      - name: Execute PM actions
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          ACTIONS=$(jq -c '.structured_output.actions // []' "$WORK_DIR/pm-result.json" 2>/dev/null || echo "[]")
          ACTION_COUNT=$(echo "$ACTIONS" | jq 'length')
          echo "Executing $ACTION_COUNT action(s)..."

          for i in $(seq 0 $((ACTION_COUNT - 1))); do
            ACTION=$(echo "$ACTIONS" | jq -c ".[$i]")
            TYPE=$(echo "$ACTION" | jq -r '.type')
            echo "Action $((i+1))/$ACTION_COUNT: $TYPE"

            case "$TYPE" in

              create_issue)
                TITLE=$(echo "$ACTION" | jq -r '.title // "Untitled"')
                BODY=$(echo "$ACTION"  | jq -r '.body // ""')
                LABELS=$(echo "$ACTION" | jq -r '(.labels // ["ai"]) | join(",")')
                gh issue create \
                  --title "$TITLE" \
                  --body "$(printf '%s\n\n%s' "$BODY" '<!-- auto-dev:pm -->')" \
                  --label "$LABELS" \
                  && echo "  Created issue: $TITLE"
                ;;

              comment_issue)
                NUM=$(echo "$ACTION" | jq -r '.number')
                BODY=$(echo "$ACTION" | jq -r '.body // ""')
                gh issue comment "$NUM" \
                  --body "$(printf '%s\n\n%s' "$BODY" '<!-- auto-dev:pm -->')" \
                  && echo "  Commented on issue #$NUM"
                ;;

              comment_pr)
                NUM=$(echo "$ACTION" | jq -r '.number')
                BODY=$(echo "$ACTION" | jq -r '.body // ""')
                gh pr comment "$NUM" \
                  --body "$(printf '%s\n\n%s' "$BODY" '<!-- auto-dev:pm -->')" \
                  && echo "  Commented on PR #$NUM"
                ;;

              add_label)
                NUM=$(echo "$ACTION"    | jq -r '.number')
                TARGET=$(echo "$ACTION" | jq -r '.target // "issue"')
                LABEL=$(echo "$ACTION"  | jq -r '.label')
                if [[ "$TARGET" == "pr" ]]; then
                  gh pr edit "$NUM" --add-label "$LABEL" && echo "  Added label '$LABEL' to PR #$NUM"
                else
                  gh issue edit "$NUM" --add-label "$LABEL" && echo "  Added label '$LABEL' to issue #$NUM"
                fi
                ;;

              remove_label)
                NUM=$(echo "$ACTION"    | jq -r '.number')
                TARGET=$(echo "$ACTION" | jq -r '.target // "issue"')
                LABEL=$(echo "$ACTION"  | jq -r '.label')
                if [[ "$TARGET" == "pr" ]]; then
                  gh pr edit "$NUM" --remove-label "$LABEL" && echo "  Removed label '$LABEL' from PR #$NUM"
                else
                  gh issue edit "$NUM" --remove-label "$LABEL" && echo "  Removed label '$LABEL' from issue #$NUM"
                fi
                ;;

              commit_to_main)
                MSG=$(echo "$ACTION" | jq -r '.message // "docs: update"')
                FILES=$(echo "$ACTION" | jq -c '.files // []')
                FILE_COUNT=$(echo "$FILES" | jq 'length')
                staged=0
                for j in $(seq 0 $((FILE_COUNT - 1))); do
                  F=$(echo "$FILES" | jq -c ".[$j]")
                  P=$(echo "$F" | jq -r '.path')
                  C=$(echo "$F" | jq -r '.content')
                  # Reject path traversal / absolute paths outright.
                  if [[ "$P" == *".."* || "$P" == /* ]]; then
                    echo "  ✗ rejected (traversal/absolute): $P"; continue
                  fi
                  # Allowlist: top-level docs, docs/**.md, non-workflow .github/ config.
                  if [[ "$P" =~ ^(README|ARCHITECTURE|CONTRIBUTING)\.md$ ]] \
                     || [[ "$P" =~ ^docs/.*\.md$ ]] \
                     || { [[ "$P" =~ ^\.github/ ]] && [[ ! "$P" =~ ^\.github/workflows/ ]]; }; then
                    mkdir -p "$(dirname "$P")"
                    printf '%s\n' "$C" > "$P"
                    git add "$P" && staged=$((staged + 1)) && echo "  staged: $P"
                  else
                    echo "  ✗ rejected (not in allowlist): $P"
                  fi
                done
                if [[ "$staged" -gt 0 ]]; then
                  git commit -m "$MSG [auto-dev-pm]"
                  git push && echo "  committed $staged file(s) directly to main"
                fi
                ;;

              noop)
                R=$(echo "$ACTION" | jq -r '.rationale // "No action needed"')
                echo "  No-op: $R"
                ;;

              *)
                echo "  Unknown action type: $TYPE — skipping"
                ;;
            esac
          done

          echo "PM actions complete."

      - name: Write step summary and activity log
        if: always() && steps.pm_agent.outcome == 'success'
        env:
          GH_REPO: ${{ github.repository }}
        run: |
          SUMMARY=$(jq -r '.structured_output.summary // "(no summary)"' "$WORK_DIR/pm-result.json" 2>/dev/null)
          REPORT=$(jq -r '.structured_output.report // "(no report)"' "$WORK_DIR/pm-result.json" 2>/dev/null)
          ACTIONS=$(jq -c '.structured_output.actions // []' "$WORK_DIR/pm-result.json" 2>/dev/null || echo "[]")
          ACTION_COUNT=$(echo "$ACTIONS" | jq 'length')

          # ── GitHub Actions step summary ───────────────────
          {
            echo "# 🤖 PM Agent — $(date -u +"%Y-%m-%d %H:%M UTC")"
            echo ""
            echo "**$SUMMARY**"
            echo ""
            echo "## Report"
            echo ""
            printf '%s\n' "$REPORT"
            echo ""
            echo "## Actions ($ACTION_COUNT)"
            echo ""
            for i in $(seq 0 $((ACTION_COUNT - 1))); do
              A=$(echo "$ACTIONS" | jq -c ".[$i]")
              T=$(echo "$A" | jq -r '.type')
              R=$(echo "$A" | jq -r '.rationale // ""')
              case "$T" in
                create_issue)  DETAIL=$(echo "$A" | jq -r '.title // ""') ;;
                comment_issue) DETAIL="#$(echo "$A" | jq -r '.number')" ;;
                comment_pr)    DETAIL="PR #$(echo "$A" | jq -r '.number')" ;;
                add_label|remove_label) DETAIL="$(echo "$A" | jq -r '.target')#$(echo "$A" | jq -r '.number') — $(echo "$A" | jq -r '.label')" ;;
                commit_to_main) DETAIL=$(echo "$A" | jq -r '[.files[]?.path] | join(", ")') ;;
                noop)          DETAIL="" ;;
                *)             DETAIL="(unknown)" ;;
              esac
              echo "- **$T** $DETAIL"
              [[ -n "$R" ]] && echo "  - _${R}_"
            done
          } >> "$GITHUB_STEP_SUMMARY"

          # ── activity.jsonl for menubar ────────────────────
          STATE_DIR="$HOME/Documents/state/claude-toolkit/auto-dev"
          mkdir -p "$STATE_DIR"
          TS=$(date +%s)
          jq -nc \
            --arg ts "$TS" \
            --arg repo "$GH_REPO" \
            --arg summary "$SUMMARY" \
            --argjson count "$ACTION_COUNT" \
            '{ts: ($ts|tonumber), repo: $repo, agent: "pm", actions: $count, summary: $summary}' \
            >> "$STATE_DIR/activity.jsonl"

      - name: Save cursor
        if: success()
        env:
          CURSOR_FILE: ${{ steps.cursor.outputs.cursor_file }}
          RUN_START: ${{ steps.cursor.outputs.run_start }}
        run: |
          echo "$RUN_START" > "$CURSOR_FILE"
          echo "Updated PM cursor to $RUN_START"
