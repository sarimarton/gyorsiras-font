name: Auto-dev

on:
  issues:
    types: [labeled]
  issue_comment:
    types: [created]
  schedule:
    - cron: '0 */2 * * *'   # Every 2 hours
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number (empty = scan all ai-labeled issues)"
        required: false
        type: string
      skip_usage_check:
        description: "Skip the Claude usage threshold check"
        required: false
        type: boolean
        default: false

concurrency:
  group: auto-dev
  cancel-in-progress: false

env:
  MARKER_PREFIX: "auto-dev"
  MAX_ISSUES_PER_RUN: 3

permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read

# ─────────────────────────────────────────────────────────────
# State machine (hierarchical labels — 'ai' always present):
#   [ai]                      → Claude evaluates the issue
#   [ai] + [ai:clarifying]   → Question posted, waiting for answer
#   [ai] + [ai:ready]        → Context clear, PR can be opened
#   [ai] + [ai:in-progress]  → Draft PR open, todos in progress
#   [ai] + [ai:done]         → All todos complete, review requested
#   [ai] + [ai:blocked]      → Too complex / unclear, needs human
#
# Model overrides (optional, on any issue/PR):
#   [opus]   → Use Claude Opus for next iteration
#   [haiku]  → Use Claude Haiku for next iteration
# ─────────────────────────────────────────────────────────────

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
  # Job 2: Collect issues to process
  # ════════════════════════════════════════════════════════════
  list-issues:
    needs: check-usage
    if: needs.check-usage.outputs.ok == 'true'
    runs-on: [self-hosted]
    outputs:
      matrix: ${{ steps.get-issues.outputs.matrix }}
      has_issues: ${{ steps.get-issues.outputs.has_issues }}
    steps:
      - name: Load max issues from global config
        id: repo-config
        run: |
          GLOBAL_CONFIG="$HOME/.config/claude-toolkit/global.json"
          MAX=$(jq -r '.max_issues_per_run // empty' "$GLOBAL_CONFIG" 2>/dev/null | head -n 1)
          echo "max_issues=${MAX:-${{ env.MAX_ISSUES_PER_RUN }}}" >> $GITHUB_OUTPUT

      - name: Get issues to process
        id: get-issues
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          # ── Single issue mode (event-driven) ──
          if [[ "${{ github.event_name }}" == "issues" ]]; then
            ISSUE_NUMBER="${{ github.event.issue.number }}"
            echo "has_issues=true" >> $GITHUB_OUTPUT
            echo "matrix=$(jq -nc --argjson n "$ISSUE_NUMBER" '{include: [{number: $n}]}')" >> $GITHUB_OUTPUT
            exit 0
          fi

          if [[ "${{ github.event_name }}" == "issue_comment" ]]; then
            ISSUE_NUMBER="${{ github.event.issue.number }}"
            echo "has_issues=true" >> $GITHUB_OUTPUT
            echo "matrix=$(jq -nc --argjson n "$ISSUE_NUMBER" '{include: [{number: $n}]}')" >> $GITHUB_OUTPUT
            exit 0
          fi

          if [[ -n "${{ inputs.issue_number }}" ]]; then
            NUM="${{ inputs.issue_number }}"
            echo "has_issues=true" >> $GITHUB_OUTPUT
            echo "matrix=$(jq -nc --argjson n "$NUM" '{include: [{number: $n}]}')" >> $GITHUB_OUTPUT
            exit 0
          fi

          # ── Batch mode: prioritized ai-labeled issues ──
          ALL_ISSUES=$(gh issue list \
            --state open \
            --json number,labels \
            --limit 100 \
            | jq -c '[.[] | select(.labels | map(.name) | any(test("^ai($|:)")))]')

          TOTAL=$(echo "$ALL_ISSUES" | jq 'length')
          echo "Found $TOTAL issue(s) with ai* labels"

          issues=$(echo "$ALL_ISSUES" | jq -c --argjson max "${{ steps.repo-config.outputs.max_issues }}" '
            [.[] | {
              number,
              priority: (
                if (.labels | map(.name) | any(. == "ai:in-progress")) then 1
                elif (.labels | map(.name) | any(. == "ai:ready")) then 2
                elif (.labels | map(.name) | any(. == "ai:clarifying")) then 3
                elif (.labels | map(.name) | any(. == "ai:blocked" or . == "ai:done")) then 99
                else 4
                end
              )
            }]
            | [.[] | select(.priority < 99)]
            | sort_by(.priority)
            | .[0:$max]
            | [.[] | {number}]
          ')

          count=$(echo "$issues" | jq 'length')
          echo "Selected $count issue(s)"

          if [ "$count" -gt 0 ]; then
            echo "has_issues=true" >> $GITHUB_OUTPUT
            echo "matrix=$(echo "$issues" | jq -c '{include: .}')" >> $GITHUB_OUTPUT
          else
            echo "has_issues=false" >> $GITHUB_OUTPUT
          fi

  # ════════════════════════════════════════════════════════════
  # Job 3: Process each issue (one state transition per run)
  # ════════════════════════════════════════════════════════════
  process:
    needs: list-issues
    if: needs.list-issues.outputs.has_issues == 'true'
    runs-on: [self-hosted]
    strategy:
      matrix: ${{ fromJson(needs.list-issues.outputs.matrix) }}
      fail-fast: false
      max-parallel: 1

    env:
      ISSUE_NUMBER: ${{ matrix.number }}
      WORK_DIR: /tmp/auto-dev-${{ matrix.number }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Configure git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Ensure labels exist
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          gh label create "ai"             --color "1d76db" --description "Auto-dev: pool identifier"   --force
          gh label create "ai:clarifying"  --color "fbca04" --description "Auto-dev: question posted"   --force
          gh label create "ai:ready"       --color "0e8a16" --description "Auto-dev: ready for PR"      --force
          gh label create "ai:in-progress" --color "d93f0b" --description "Auto-dev: implementation"    --force
          gh label create "ai:done"        --color "5319e7" --description "Auto-dev: done, review"      --force
          gh label create "ai:blocked"     --color "e4e669" --description "Auto-dev: blocked"           --force
          gh label create "ai:busy"        --color "cccccc" --description "Auto-dev: cycle running"     --force
          gh label create "ai:epic"        --color "e99695" --description "Auto-dev: epic/kickoff"      --force
          gh label create "opus"           --color "7057ff" --description "Auto-dev: use Opus model"    --force
          gh label create "haiku"          --color "006b75" --description "Auto-dev: use Haiku model"   --force

      - name: Load repo config
        id: repo-config
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          RAW=$(gh api "repos/$GH_REPO/actions/variables/AUTO_DEV_CONFIG" 2>/dev/null | jq -r '.value' 2>/dev/null | head -n 1 || true)
          [[ -z "$RAW" ]] && RAW='{}'
          AUTONOMY=$(echo "$RAW" | jq -r '.autonomy // "high"' | head -n 1)
          case "$AUTONOMY" in
            low)  CI=true; CP=false; PC=false ;;
            *)    AUTONOMY=high; CI=true; CP=true; PC=true ;;
          esac
          printf 'autonomy=%s\n'      "$AUTONOMY" >> "$GITHUB_OUTPUT"
          printf 'create_issues=%s\n' "$CI"       >> "$GITHUB_OUTPUT"
          printf 'create_prs=%s\n'    "$CP"       >> "$GITHUB_OUTPUT"
          printf 'push_commits=%s\n'  "$PC"       >> "$GITHUB_OUTPUT"

      - name: Determine current state
        id: state
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          mkdir -p "$WORK_DIR"

          ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body,labels,comments)
          echo "$ISSUE_JSON" > "$WORK_DIR/issue.json"

          ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
          LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")')

          echo "Issue #${ISSUE_NUMBER}: $ISSUE_TITLE"
          echo "Labels: $LABELS"

          # Check for stale busy label (crash recovery)
          if echo "$LABELS" | grep -q "ai:busy"; then
            gh issue comment "$ISSUE_NUMBER" --body "⚠️ **Auto-dev** — Previous cycle left a \`ai:busy\` label (possible crash). Manual review required before continuing."
            gh issue edit "$ISSUE_NUMBER" --remove-label "ai:busy"
            echo "state=skip" >> $GITHUB_OUTPUT
            exit 0
          fi

          if echo "$LABELS" | grep -q "ai:blocked"; then STATE="blocked"
          elif echo "$LABELS" | grep -q "ai:epic"; then STATE="skip"
          elif echo "$LABELS" | grep -q "ai:done"; then STATE="done"
          elif echo "$LABELS" | grep -q "ai:in-progress"; then STATE="in-progress"
          elif echo "$LABELS" | grep -q "ai:ready"; then STATE="ready"
          elif echo "$LABELS" | grep -q "ai:clarifying"; then STATE="clarifying"
          elif echo "$LABELS" | grep -q "\bai\b"; then STATE="new"
          else STATE="skip"
          fi

          # Model selection from labels
          if echo "$LABELS" | grep -q "\bopus\b"; then MODEL="claude-opus-4-7"
          elif echo "$LABELS" | grep -q "\bhaiku\b"; then MODEL="claude-haiku-4-5-20251001"
          else MODEL="claude-sonnet-4-6"
          fi

          # Safe branch name from title
          SAFE_TITLE=$(echo "$ISSUE_TITLE" \
            | sed "y/áéíóöőúüűÁÉÍÓÖŐÚÜŰ/aeiooouuuAEIOOOUUU/" \
            | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
            | cut -c1-50)

          # Find existing linked PR
          PR_NUMBER=""
          PR_CANDIDATE=$(echo "$ISSUE_JSON" | jq -r '
            [.comments[] | select(.body | test("<!-- auto-dev:pr:[0-9]+ -->"))
             | .body | match("<!-- auto-dev:pr:([0-9]+) -->") | .captures[0].string
            ] | last // empty')

          if [ -n "$PR_CANDIDATE" ]; then
            PR_STATE=$(gh pr view "$PR_CANDIDATE" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
            [[ "$PR_STATE" == "OPEN" ]] && PR_NUMBER="$PR_CANDIDATE"
          fi

          echo "state=$STATE"           >> $GITHUB_OUTPUT
          echo "model=$MODEL"           >> $GITHUB_OUTPUT
          echo "title=$ISSUE_TITLE"     >> $GITHUB_OUTPUT
          echo "safe_title=$SAFE_TITLE" >> $GITHUB_OUTPUT
          echo "pr_number=$PR_NUMBER"   >> $GITHUB_OUTPUT
          echo "branch=task/ai-${ISSUE_NUMBER}-${SAFE_TITLE}" >> $GITHUB_OUTPUT

      # ────────────────────────────────────────────────────────
      # STATE: new → evaluate issue (clarify / ready / blocked)
      # ────────────────────────────────────────────────────────
      - name: "new → acquire busy lock"
        if: steps.state.outputs.state == 'new'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: gh issue edit "$ISSUE_NUMBER" --add-label "ai:busy"

      - name: "new → evaluate with Claude"
        if: steps.state.outputs.state == 'new'
        id: evaluate
        timeout-minutes: 15
        env:
          GH_TOKEN: ${{ github.token }}
          MODEL: ${{ steps.state.outputs.model }}
        run: |
          ISSUE_BODY=$(jq -r '.body // ""' "$WORK_DIR/issue.json")
          ISSUE_TITLE="${{ steps.state.outputs.title }}"
          COMMENTS=$(jq -r '[.comments[] | "**\(.author.login)** (\(.createdAt)):\n\(.body)"] | join("\n\n---\n\n")' "$WORK_DIR/issue.json")

          {
            echo "You are an AI developer evaluating a GitHub issue."
            echo ""
            echo "REQUIRED STEPS (in order):"
            echo "1. Read CLAUDE.md in the repo root if it exists."
            echo "2. Find and read the files, components, and modules mentioned in the issue (use available tools)."
            echo "3. Based on what you read, decide:"
            echo "   - Does the issue describe the overall project goal or system vision (kickoff/epic)? -> EPIC"
            echo "   - Do you have questions that can't be answered from the code? -> CLARIFY"
            echo "   - Clearly implementable based on the codebase? -> READY"
            echo "   - Too complex / risky / ambiguous intent? -> BLOCKED"
            echo ""
            echo "RULES:"
            echo "- If the issue title/body describes the whole project purpose, a roadmap, or a vision without a concrete actionable task, choose EPIC."
            echo "- For EPIC: identify 1-2 small, concrete first steps (Low Hanging Fruit) that can be implemented independently."
            echo "- Prefer CLARIFY over guessing. If the issue has any ambiguity, ask."
            echo "- When asking questions, include code context and your recommendation."
            echo "- Ask at most 2-3 questions, the most important ones."
            echo "- If a question is trivial and has an obvious good answer, decide yourself."
            echo "- If verifying the implementation requires non-trivial setup (visual/audio output, hardware, complex integration, or no obvious automated test), include a question about the expected testing approach in your CLARIFY decision."
            echo "- Do NOT choose READY without reading the relevant code first."
            echo "- Output ONLY valid JSON, no other text:"
            echo ""
            echo 'If EPIC:    {"decision": "epic", "comment": "Why this is an epic", "lhf": [{"title": "Short task title", "body": "Task description with context"}]}'
            echo 'If CLARIFY: {"decision": "clarify", "questions": "Your questions in Markdown with code references"}'
            echo 'If READY:   {"decision": "ready", "summary": "One-line issue summary", "approach": "Planned approach in 2-3 sentences with concrete file references"}'
            echo 'If BLOCKED: {"decision": "blocked", "reason": "Why you cannot proceed"}'
            echo ""
            printf -- '--- ISSUE #%s: %s ---\n\n' "$ISSUE_NUMBER" "$ISSUE_TITLE"
            printf '%s\n' "$ISSUE_BODY"
            printf '\n--- COMMENTS ---\n\n'
            printf '%s\n' "$COMMENTS"
          } > "$WORK_DIR/evaluate-prompt.txt"

          SCHEMA='{"type":"object","properties":{"decision":{"type":"string","enum":["epic","clarify","ready","blocked"]},"comment":{"type":"string"},"lhf":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title","body"]}},"questions":{"type":"string"},"summary":{"type":"string"},"approach":{"type":"string"},"reason":{"type":"string"}},"required":["decision"]}'
          RESULT=$(claude --dangerously-skip-permissions --output-format json --json-schema "$SCHEMA" -p "$(cat "$WORK_DIR/evaluate-prompt.txt")" 2>"$WORK_DIR/evaluate-stderr.txt") || true
          echo "$RESULT" > "$WORK_DIR/evaluate-result.json"

          DECISION=$(jq -r '.structured_output.decision // "error"' "$WORK_DIR/evaluate-result.json" 2>/dev/null || echo "error")
          case "$DECISION" in
            epic|clarify|ready|blocked) ;;
            *) DECISION="error" ;;
          esac
          echo "decision=$DECISION" >> $GITHUB_OUTPUT

      - name: "new → post clarifying question"
        if: steps.state.outputs.state == 'new' && steps.evaluate.outputs.decision == 'clarify'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          QUESTIONS=$(jq -r '.structured_output.questions // "Could not extract questions."' "$WORK_DIR/evaluate-result.json" 2>/dev/null)
          ROUND=$(jq '[.comments[] | select(.body | test("<!-- auto-dev:question -->"))] | length' "$WORK_DIR/issue.json")
          {
            echo "🤖 **Auto-dev** — Question (round $((ROUND + 1)))"
            echo ""
            echo "$QUESTIONS"
            echo ""
            echo "<!-- auto-dev:question -->"
          } > "$WORK_DIR/comment.md"
          gh issue comment "$ISSUE_NUMBER" --body-file "$WORK_DIR/comment.md"
          gh issue edit "$ISSUE_NUMBER" \
            --remove-label "ai:blocked" --remove-label "ai:ready" --remove-label "ai:in-progress" --remove-label "ai:done" \
            --add-label "ai:clarifying" 2>/dev/null || gh issue edit "$ISSUE_NUMBER" --add-label "ai:clarifying"

      - name: "new → mark ready"
        if: steps.state.outputs.state == 'new' && steps.evaluate.outputs.decision == 'ready'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          SUMMARY=$(jq -r '.structured_output.summary // "N/A"' "$WORK_DIR/evaluate-result.json" 2>/dev/null)
          APPROACH=$(jq -r '.structured_output.approach // "N/A"' "$WORK_DIR/evaluate-result.json" 2>/dev/null)
          {
            echo "🤖 **Auto-dev** — Ready"
            echo ""
            echo "**Summary:** $SUMMARY"
            echo ""
            echo "**Approach:** $APPROACH"
            echo ""
            echo "Waiting for your approval to open a PR. Add **\`ai:ready\`** label to confirm, or comment with adjustments."
            echo ""
            echo "<!-- auto-dev:ready -->"
          } > "$WORK_DIR/comment.md"
          gh issue comment "$ISSUE_NUMBER" --body-file "$WORK_DIR/comment.md"
          gh issue edit "$ISSUE_NUMBER" \
            --remove-label "ai:clarifying" --remove-label "ai:blocked" \
            --add-label "ai:ready" 2>/dev/null || gh issue edit "$ISSUE_NUMBER" --add-label "ai:ready"

      - name: "new → handle epic"
        if: steps.state.outputs.state == 'new' && steps.evaluate.outputs.decision == 'epic'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          COMMENT=$(jq -r '.structured_output.comment // "This issue describes an epic-level goal."' "$WORK_DIR/evaluate-result.json" 2>/dev/null)
          LHF=$(jq -c '.structured_output.lhf // []' "$WORK_DIR/evaluate-result.json" 2>/dev/null)

          SUB_ISSUES=""
          if [[ "${{ steps.repo-config.outputs.create_issues }}" != "false" ]]; then
            while IFS= read -r item; do
              [[ -z "$item" ]] && continue
              TITLE=$(echo "$item" | jq -r '.title')
              BODY=$(echo "$item" | jq -r '.body')
              NEW_URL=$(gh issue create --title "$TITLE" --body "$BODY" --label "ai" 2>/dev/null || true)
              [[ -n "$NEW_URL" ]] && SUB_ISSUES="${SUB_ISSUES}"$'\n'"- ${NEW_URL}"
            done < <(echo "$LHF" | jq -c '.[]' 2>/dev/null)
          fi

          {
            echo "🤖 **Auto-dev** — Epic detected"
            echo ""
            echo "$COMMENT"
            if [[ -n "$SUB_ISSUES" ]]; then
              echo ""
              echo "**Created LHF sub-issues:**"
              echo "$SUB_ISSUES"
            fi
            echo ""
            echo "Continue the discussion here. New sub-issues will be picked up automatically."
            echo ""
            echo "<!-- auto-dev:epic -->"
          } > "$WORK_DIR/comment.md"
          gh issue comment "$ISSUE_NUMBER" --body-file "$WORK_DIR/comment.md"
          gh issue edit "$ISSUE_NUMBER" --add-label "ai:epic" 2>/dev/null || true

      - name: "new → mark blocked"
        if: steps.state.outputs.state == 'new' && (steps.evaluate.outputs.decision == 'blocked' || steps.evaluate.outputs.decision == 'error')
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          REASON=$(jq -r '.structured_output.reason // "Evaluation failed or returned unexpected output."' "$WORK_DIR/evaluate-result.json" 2>/dev/null)
          {
            echo "🤖 **Auto-dev** — Blocked"
            echo ""
            echo "$REASON"
            echo ""
            echo "<!-- auto-dev:blocked -->"
          } > "$WORK_DIR/comment.md"
          gh issue comment "$ISSUE_NUMBER" --body-file "$WORK_DIR/comment.md"
          gh issue edit "$ISSUE_NUMBER" --add-label "ai:blocked" 2>/dev/null || true

      - name: "new → release busy lock"
        if: always() && steps.state.outputs.state == 'new'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: gh issue edit "$ISSUE_NUMBER" --remove-label "ai:busy" 2>/dev/null || true

      # ────────────────────────────────────────────────────────
      # STATE: clarifying → re-evaluate after owner's reply
      # ────────────────────────────────────────────────────────
      - name: "clarifying → re-evaluate"
        if: steps.state.outputs.state == 'clarifying' && github.event_name == 'issue_comment'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          # Remove ai:clarifying and reset to bare 'ai' so next run re-evaluates
          gh issue edit "$ISSUE_NUMBER" --remove-label "ai:clarifying" 2>/dev/null || true

      # ────────────────────────────────────────────────────────
      # STATE: ready → open draft PR with todo list
      # ────────────────────────────────────────────────────────
      - name: "ready → acquire busy lock"
        if: steps.state.outputs.state == 'ready' && steps.state.outputs.pr_number == ''
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: gh issue edit "$ISSUE_NUMBER" --add-label "ai:busy"

      - name: "ready → plan todos with Claude"
        if: steps.state.outputs.state == 'ready' && steps.state.outputs.pr_number == ''
        id: plan
        timeout-minutes: 15
        env:
          GH_TOKEN: ${{ github.token }}
          MODEL: ${{ steps.state.outputs.model }}
        run: |
          ISSUE_BODY=$(jq -r '.body // ""' "$WORK_DIR/issue.json")
          ISSUE_TITLE="${{ steps.state.outputs.title }}"
          COMMENTS=$(jq -r '[.comments[] | "**\(.author.login)** (\(.createdAt)):\n\(.body)"] | join("\n\n---\n\n")' "$WORK_DIR/issue.json")

          {
            echo "You are an AI developer creating a task breakdown for a GitHub issue."
            echo ""
            echo "Read the codebase to understand the context, then output a JSON task list."
            echo ""
            echo "RULES:"
            echo "- Each task must be completable in ONE iteration (10-20 minutes of Claude work, one logical change)."
            echo "- Tasks must be ordered correctly (dependencies first)."
            echo "- Be specific: include file paths and what exactly changes."
            echo "- Always add at least one testing task as the LAST task."
            echo "  - If automated/headless testing is possible, describe it precisely: what command to run, what to assert."
            echo "  - If only manual testing is possible, add a task in this exact format: 'Manual validation: [exactly what to do and what to look for]'"
            echo '- Output ONLY valid JSON: {"tasks": ["task description 1", "task description 2", ...]}'
            echo ""
            printf -- '--- ISSUE #%s: %s ---\n\n' "$ISSUE_NUMBER" "$ISSUE_TITLE"
            printf '%s\n' "$ISSUE_BODY"
            printf '\n--- DISCUSSION ---\n\n'
            printf '%s\n' "$COMMENTS"
          } > "$WORK_DIR/plan-prompt.txt"

          SCHEMA='{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"string"}}},"required":["tasks"]}'
          RESULT=$(claude --dangerously-skip-permissions --output-format json --json-schema "$SCHEMA" -p "$(cat "$WORK_DIR/plan-prompt.txt")" 2>"$WORK_DIR/plan-stderr.txt") || true
          echo "$RESULT" > "$WORK_DIR/plan-result.json"

          TASKS=$(jq -c '.structured_output.tasks // []' "$WORK_DIR/plan-result.json" 2>/dev/null || echo "[]")
          echo "tasks=$TASKS" >> $GITHUB_OUTPUT

      - name: "ready → create branch and draft PR"
        if: steps.state.outputs.state == 'ready' && steps.state.outputs.pr_number == '' && steps.plan.outputs.tasks != '[]' && steps.repo-config.outputs.create_prs != 'false'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          BRANCH="${{ steps.state.outputs.branch }}"
          git checkout -b "$BRANCH"
          git push -u origin "$BRANCH"

          # Build task list markdown
          TASKS='${{ steps.plan.outputs.tasks }}'
          TASK_LIST=$(echo "$TASKS" | jq -r '.[] | "- [ ] \(.)"')

          {
            echo "Closes #${ISSUE_NUMBER}"
            echo ""
            echo "## Tasks"
            echo ""
            echo "$TASK_LIST"
            echo ""
            echo "<!-- auto-dev:issue:${ISSUE_NUMBER} -->"
          } > "$WORK_DIR/pr-body.md"

          PR_URL=$(gh pr create \
            --title "${{ steps.state.outputs.title }}" \
            --body-file "$WORK_DIR/pr-body.md" \
            --base main \
            --head "$BRANCH" \
            --draft)

          PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

          # Link PR back to issue
          gh issue comment "$ISSUE_NUMBER" --body "$(printf '%s\n%s\n' "🤖 **Auto-dev** — Draft PR opened: #${PR_NUMBER}" "<!-- auto-dev:pr:${PR_NUMBER} -->")"

          gh issue edit "$ISSUE_NUMBER" \
            --remove-label "ai:ready" \
            --add-label "ai:in-progress" 2>/dev/null || true

      - name: "ready → release busy lock"
        if: always() && steps.state.outputs.state == 'ready'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: gh issue edit "$ISSUE_NUMBER" --remove-label "ai:busy" 2>/dev/null || true

      # ────────────────────────────────────────────────────────
      # STATE: in-progress → execute next todo
      # ────────────────────────────────────────────────────────
      - name: "in-progress → acquire busy lock"
        if: steps.state.outputs.state == 'in-progress'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          PR_NUM="${{ steps.state.outputs.pr_number }}"
          [[ -n "$PR_NUM" ]] && gh pr edit "$PR_NUM" --add-label "ai:busy" 2>/dev/null || true

      - name: "in-progress → find and execute next todo"
        if: steps.state.outputs.state == 'in-progress' && steps.state.outputs.pr_number != ''
        id: implement
        timeout-minutes: 30
        env:
          GH_TOKEN: ${{ github.token }}
          MODEL: ${{ steps.state.outputs.model }}
          PR_NUMBER: ${{ steps.state.outputs.pr_number }}
        run: |
          PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q '.body')

          # Find next unchecked todo
          NEXT_TODO=$(echo "$PR_BODY" | grep -m1 '^\- \[ \]' | sed 's/^- \[ \] //' || true)

          if [[ -z "$NEXT_TODO" ]]; then
            echo "No unchecked todos remaining — marking PR ready for review"
            echo "outcome=all_done" >> $GITHUB_OUTPUT
            exit 0
          fi

          echo "Next todo: $NEXT_TODO"
          echo "todo=$NEXT_TODO" >> $GITHUB_OUTPUT

          # Checkout PR branch
          PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName -q '.headRefName')
          git checkout "$PR_BRANCH"

          {
            echo "You are an AI developer implementing a specific task from a pull request."
            echo ""
            printf 'TASK: %s\n' "$NEXT_TODO"
            echo ""
            echo "RULES:"
            echo "- Implement ONLY this specific task. Do not do more."
            echo "- Read relevant files before editing."
            echo "- If the TASK starts with 'Manual validation:', do NOT implement anything."
            echo "  Instead output: {\"status\": \"question\", \"text\": \"Please perform manual validation: <task>\", \"context\": \"<what was implemented so far>\"}"
            echo "- After implementing, output ONLY valid JSON:"
            echo ""
            echo 'If completed: {"status": "completed", "summary": "What you changed and why"}'
            echo 'If blocked:   {"status": "blocked", "reason": "What is blocking you", "suggestion": "What info you need"}'
            echo 'If question:  {"status": "question", "text": "Your question", "context": "Relevant code context"}'
          } > "$WORK_DIR/implement-prompt.txt"

          SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["completed","blocked","question"]},"summary":{"type":"string"},"reason":{"type":"string"},"suggestion":{"type":"string"},"text":{"type":"string"},"context":{"type":"string"}},"required":["status"]}'
          RESULT=$(claude --dangerously-skip-permissions --output-format json --json-schema "$SCHEMA" -p "$(cat "$WORK_DIR/implement-prompt.txt")" 2>"$WORK_DIR/implement-stderr.txt") || true
          echo "$RESULT" > "$WORK_DIR/implement-result.json"

          STATUS=$(jq -r '.structured_output.status // "error"' "$WORK_DIR/implement-result.json" 2>/dev/null || echo "error")
          case "$STATUS" in
            completed|blocked|question) ;;
            *) STATUS="error" ;;
          esac
          echo "outcome=$STATUS" >> $GITHUB_OUTPUT

          if [[ "$STATUS" == "completed" ]]; then
            # Commit changes
            git add -A
            if ! git diff --cached --quiet; then
              git commit -m "$(echo "$NEXT_TODO" | cut -c1-72)"
              if [[ "${{ steps.repo-config.outputs.push_commits }}" != "false" ]]; then
                git push
              fi
            fi
            # Check off the todo in PR description
            UPDATED_BODY=$(echo "$PR_BODY" | sed "0,/- \[ \] $(echo "$NEXT_TODO" | sed 's/[[\.*^$()+?{}|]/\\&/g')/{s/- \[ \] /- [x] /}")
            gh pr edit "$PR_NUMBER" --body "$UPDATED_BODY"
          fi

      - name: "in-progress → handle completed"
        if: steps.state.outputs.state == 'in-progress' && steps.implement.outputs.outcome == 'completed'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.state.outputs.pr_number }}
        run: |
          SUMMARY=$(jq -r '.structured_output.summary // "Task completed."' "$WORK_DIR/implement-result.json" 2>/dev/null)
          TODO="${{ steps.implement.outputs.todo }}"

          # Check if all todos are now done
          PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q '.body')
          REMAINING=$(echo "$PR_BODY" | grep -c '^\- \[ \]' || true)
          MANUAL_REMAINING=$(echo "$PR_BODY" | grep -c '^\- \[ \] Manual validation:' || true)

          if [[ "$REMAINING" -eq 0 ]]; then
            gh pr edit "$PR_NUMBER" --ready-for-review 2>/dev/null || true
            gh pr comment "$PR_NUMBER" --body "🤖 **Auto-dev** — All tasks complete. Ready for review."
            gh issue edit "$ISSUE_NUMBER" \
              --remove-label "ai:in-progress" \
              --add-label "ai:done" 2>/dev/null || true
          elif [[ "$REMAINING" -eq "$MANUAL_REMAINING" ]]; then
            # Only manual validation tasks remain — ask human
            MANUAL_LIST=$(echo "$PR_BODY" | grep '^\- \[ \] Manual validation:' | sed 's/^- \[ \] /• /' | tr '\n' '\n')
            gh pr comment "$PR_NUMBER" --body "$(printf '🤖 **Auto-dev** — Implementation complete. Manual validation required before this PR can be marked done:\n\n%s\n\nPlease test and check off each item.' "$MANUAL_LIST")"
            gh pr edit "$PR_NUMBER" --add-label "ai:blocked" 2>/dev/null || true
            gh issue edit "$ISSUE_NUMBER" --add-label "ai:blocked" 2>/dev/null || true
          else
            gh pr comment "$PR_NUMBER" --body "$(printf '%s\n%s\n%s\n' "🤖 **Auto-dev** — ✓ \`$TODO\`" "$SUMMARY" "($REMAINING task(s) remaining)")"
          fi

      - name: "in-progress → handle blocked/question"
        if: steps.state.outputs.state == 'in-progress' && (steps.implement.outputs.outcome == 'blocked' || steps.implement.outputs.outcome == 'question')
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.state.outputs.pr_number }}
        run: |
          OUTCOME="${{ steps.implement.outputs.outcome }}"
          if [[ "$OUTCOME" == "blocked" ]]; then
            REASON=$(jq -r '.structured_output.reason // "Blocked."' "$WORK_DIR/implement-result.json" 2>/dev/null)
            SUGGESTION=$(jq -r '.structured_output.suggestion // ""' "$WORK_DIR/implement-result.json" 2>/dev/null)
            BODY="🤖 **Auto-dev** — ⊘ Blocked: $REASON"
            [[ -n "$SUGGESTION" ]] && BODY=$(printf '%s\n%s' "$BODY" "Suggestion: $SUGGESTION")
            gh pr comment "$PR_NUMBER" --body "$BODY"
          else
            QUESTION=$(jq -r '.structured_output.text // "Question."' "$WORK_DIR/implement-result.json" 2>/dev/null)
            CONTEXT=$(jq -r '.structured_output.context // ""' "$WORK_DIR/implement-result.json" 2>/dev/null)
            BODY="🤖 **Auto-dev** — ❓ $QUESTION"
            [[ -n "$CONTEXT" ]] && BODY=$(printf '%s\n%s' "$BODY" "Context: $CONTEXT")
            gh pr comment "$PR_NUMBER" --body "$BODY"
          fi
          gh pr edit "$PR_NUMBER" --add-label "ai:blocked" 2>/dev/null || true
          gh issue edit "$ISSUE_NUMBER" --add-label "ai:blocked" 2>/dev/null || true

      - name: "in-progress → release busy lock"
        if: always() && steps.state.outputs.state == 'in-progress'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          PR_NUM="${{ steps.state.outputs.pr_number }}"
          [[ -n "$PR_NUM" ]] && gh pr edit "$PR_NUM" --remove-label "ai:busy" 2>/dev/null || true

      # ────────────────────────────────────────────────────────
      # Activity log (always runs)
      # ────────────────────────────────────────────────────────
      - name: Write activity log
        if: always() && steps.state.outputs.state != 'skip'
        env:
          GH_REPO: ${{ github.repository }}
        run: |
          STATE="${{ steps.state.outputs.state }}"
          MODEL="${{ steps.state.outputs.model }}"
          PR_NUM="${{ steps.state.outputs.pr_number }}"
          TODO="${{ steps.implement.outputs.todo || '' }}"
          OUTCOME="${{ steps.implement.outputs.outcome || steps.evaluate.outputs.decision || steps.plan.outputs.tasks != '[]' && 'pr_created' || 'skipped' }}"
          TS=$(date +%s)
          DURATION=$(( TS - $(date -d @"${ACTIONS_STEP_DEBUG_START:-$TS}" +%s 2>/dev/null || echo "$TS") ))

          PCT_AFTER=$(jq -r '.pct // ""' /tmp/claude-usage.json 2>/dev/null || echo "")

          STATE_DIR="$HOME/Documents/state/claude-toolkit/auto-dev"
          mkdir -p "$STATE_DIR"

          ENTRY=$(jq -nc \
            --argjson ts "$TS" \
            --arg repo "${{ env.GH_REPO }}" \
            --arg issue "${{ env.GH_REPO }}#${{ env.ISSUE_NUMBER }}" \
            --arg model "$MODEL" \
            --arg state "$STATE" \
            --arg outcome "$OUTCOME" \
            '{ts: $ts, repo: $repo, issue: $issue, model: $model, state: $state, outcome: $outcome}')
          [[ -n "$PR_NUM" ]] && ENTRY=$(echo "$ENTRY" | jq --arg v "${{ env.GH_REPO }}#$PR_NUM" '. + {pr: $v}')
          [[ -n "$TODO" ]]    && ENTRY=$(echo "$ENTRY" | jq --arg v "$TODO"                     '. + {todo: $v}')
          [[ -n "$PCT_AFTER" ]] && ENTRY=$(echo "$ENTRY" | jq --argjson v "$PCT_AFTER"          '. + {usage_pct_after: $v}')
          echo "$ENTRY" >> "$STATE_DIR/activity.jsonl"

      - name: Update repo status summary
        if: always() && steps.state.outputs.state != 'skip'
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          STATE_DIR="$HOME/Documents/state/claude-toolkit/auto-dev"
          REPO_SLUG=$(echo "$GH_REPO" | tr '/' '-')

          ISSUE_STATES=$(gh issue list --state open --label ai --json number,labels --limit 100 2>/dev/null | jq -c '
            {
              total: length,
              new:         [.[] | select(.labels | map(.name) | (any(. == "ai") and (any(startswith("ai:")) | not)))] | length,
              clarifying:  [.[] | select(.labels | map(.name) | any(. == "ai:clarifying"))]  | length,
              ready:       [.[] | select(.labels | map(.name) | any(. == "ai:ready"))]        | length,
              in_progress: [.[] | select(.labels | map(.name) | any(. == "ai:in-progress"))]  | length,
              done:        [.[] | select(.labels | map(.name) | any(. == "ai:done"))]          | length,
              blocked:     [.[] | select(.labels | map(.name) | any(. == "ai:blocked"))]       | length,
              epic:        [.[] | select(.labels | map(.name) | any(. == "ai:epic"))]          | length
            }
          ' 2>/dev/null || echo '{"total":0}')

          AUTONOMY="${{ steps.repo-config.outputs.autonomy }}"
          jq -n \
            --argjson states "$ISSUE_STATES" \
            --argjson ts "$(date +%s)" \
            --arg repo "$GH_REPO" \
            --arg autonomy "${AUTONOMY:-high}" \
            '{ts: $ts, repo: $repo, autonomy: $autonomy, issues: $states}' > "$STATE_DIR/$REPO_SLUG-status.json"
