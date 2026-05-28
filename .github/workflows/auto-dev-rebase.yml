name: Auto-rebase

on:
  schedule:
    - cron: "0 1 * * *"
  issue_comment:
    types: [created]
  workflow_dispatch:
    inputs:
      pr_number:
        description: "PR szám (ha üres: minden open PR, kivéve no-auto-rebase label)"
        required: false
        type: string
      instructions:
        description: "Instrukció a conflict feloldásához (korábbi bail-out-ra válaszul)"
        required: false
        type: string

concurrency:
  group: auto-rebase
  cancel-in-progress: false

jobs:
  list-prs:
    # Run on: schedule, workflow_dispatch, OR "/rebase" command in PR comment
    if: |
      github.event_name != 'issue_comment' ||
      (github.event.issue.pull_request &&
       startsWith(github.event.comment.body, '/rebase'))
    runs-on: [self-hosted]
    outputs:
      matrix: ${{ steps.get-prs.outputs.matrix }}
      has_prs: ${{ steps.get-prs.outputs.has_prs }}
    permissions:
      pull-requests: read
    steps:
      - name: Get PRs to rebase
        id: get-prs
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          if [ "${{ github.event_name }}" == "issue_comment" ]; then
            # /rebase comment on a PR — rebase only that PR
            prs=$(gh pr view "${{ github.event.issue.number }}" --json number,headRefName | jq -c '[.]')
          elif [ -n "${{ inputs.pr_number }}" ]; then
            prs=$(gh pr view "${{ inputs.pr_number }}" --json number,headRefName | jq -c '[.]')
          else
            prs=$(gh pr list \
              --base main \
              --state open \
              --json number,headRefName,labels \
              | jq -c '[.[] | select(.labels | map(.name) | index("no-auto-rebase") | not) | del(.labels)]')
          fi

          count=$(echo "$prs" | jq 'length')

          if [ "$count" -gt 0 ]; then
            echo "has_prs=true" >> $GITHUB_OUTPUT
            echo "matrix=$(echo "$prs" | jq -c '{include: .}')" >> $GITHUB_OUTPUT
          else
            echo "has_prs=false" >> $GITHUB_OUTPUT
          fi

  rebase:
    needs: list-prs
    if: needs.list-prs.outputs.has_prs == 'true'
    runs-on: [self-hosted]
    strategy:
      matrix: ${{ fromJson(needs.list-prs.outputs.matrix) }}
      fail-fast: false

    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write

    env:
      WORK_DIR: /tmp/auto-rebase-${{ matrix.number }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v6
        with:
          fetch-depth: 0
          # NOTE: a default GITHUB_TOKEN-nel force-pushed rebase NEM triggerel új
          # workflow runt (GitHub anti-recursion policy), így a PR check-jei a rebase
          # után nem futnak újra automatikusan — manuális re-run kellhet. Ha ez zavaró,
          # állíts be egy PAT-ot secretként és add meg itt `token:`-ként.

      - name: Set HOME env
        run: echo "HOME=$HOME" >> $GITHUB_ENV

      - name: Configure git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Fetch and checkout PR branch
        id: setup
        run: |
          mkdir -p "$WORK_DIR"
          git fetch origin main "${{ matrix.headRefName }}"
          git checkout "${{ matrix.headRefName }}"
          echo "head_sha=$(git rev-parse HEAD)" >> $GITHUB_OUTPUT

      - name: Check for bail-out marker
        if: inputs.instructions == ''
        id: bail-check
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          blocked_sha=$(gh pr view "${{ matrix.number }}" --json comments \
            --jq '
              [.comments[]
               | select(.body | test("<!-- auto-rebase-blocked:[a-f0-9]+ -->"))
               | .body
               | match("<!-- auto-rebase-blocked:([a-f0-9]+) -->")
               | .captures[0].string
              ] | last // empty')

          if [ -z "$blocked_sha" ]; then
            echo "blocked=false" >> $GITHUB_OUTPUT
          elif [ "$blocked_sha" = "${{ steps.setup.outputs.head_sha }}" ]; then
            echo "blocked=true" >> $GITHUB_OUTPUT
          else
            echo "blocked=false" >> $GITHUB_OUTPUT
          fi

      - name: Check if behind main
        if: steps.bail-check.outputs.blocked != 'true'
        id: check
        run: |
          if git merge-base --is-ancestor origin/main HEAD; then
            echo "status=up-to-date" >> $GITHUB_OUTPUT
          else
            echo "status=behind" >> $GITHUB_OUTPUT
          fi

      - name: Attempt clean rebase
        if: steps.bail-check.outputs.blocked != 'true' && steps.check.outputs.status == 'behind'
        id: rebase
        run: |
          if git rebase origin/main; then
            echo "result=clean" >> $GITHUB_OUTPUT
          else
            git rebase --abort
            echo "result=dirty" >> $GITHUB_OUTPUT
          fi

      - name: Push clean rebase
        if: steps.rebase.outputs.result == 'clean'
        run: git push --force-with-lease origin "${{ matrix.headRefName }}"

      - name: Backup branch before Claude rebase
        if: steps.rebase.outputs.result == 'dirty'
        id: backup
        run: |
          branch="${{ matrix.headRefName }}"
          prefix="auto-rebase-bkup/${branch}"
          # Find next sequence number
          remote_out=$(git ls-remote --heads origin "${prefix}/*")
          if [ -z "$remote_out" ]; then
            existing=0
          else
            existing=$(echo "$remote_out" | wc -l | tr -d ' ')
          fi
          seq=$((existing + 1))
          backup_branch="${prefix}/${seq}"
          git push origin "HEAD:refs/heads/${backup_branch}"
          echo "branch=${backup_branch}" >> $GITHUB_OUTPUT

      - name: Claude-assisted rebase
        if: steps.rebase.outputs.result == 'dirty'
        timeout-minutes: 20
        continue-on-error: true
        env:
          DISPATCH_INSTRUCTIONS: ${{ inputs.instructions }}
          GH_TOKEN: ${{ github.token }}
        run: |
          cat <<'PROMPT' > $WORK_DIR/rebase-prompt.txt
          You are performing an automated rebase of the current branch onto origin/main.

          A simple `git rebase origin/main` was already attempted and failed due to
          merge conflicts (it has been aborted). Your task is to complete the rebase,
          resolving all conflicts intelligently.

          Instructions:
          0. Before starting the rebase, gather context to understand intent:
             - Run `gh pr view ${{ matrix.number }} --json title,body` to read the PR description
             - Run `git log --oneline origin/main..HEAD` to see the PR branch's commit history
             - Run `git log --oneline HEAD..origin/main` to see what landed on main since divergence
             Keep this context in mind throughout the conflict resolution process.
          1. Run `git rebase origin/main`
          2. For each conflict that arises:
             a. Read the conflicted files to understand both sides
             b. Resolve the conflict: remove ALL conflict markers and produce correct merged code
             c. When there is a genuine semantic conflict, prefer the PR branch's changes,
                but incorporate main's non-conflicting updates
             d. Stage resolved files with `git add`
             e. Continue the rebase with `GIT_EDITOR=true git rebase --continue`
          3. Repeat step 2 until the rebase completes

          IMPORTANT - Confidence threshold:
          If you encounter a conflict where both sides have made meaningful, incompatible
          changes to the same logic and you are uncertain about the correct resolution:
          1. Gather additional context before giving up:
             - Read the full files (not just the conflict hunks) for broader understanding
             - Check `git log -p` for the relevant commits to understand WHY each change was made
             - Review PR comments: `gh pr view ${{ matrix.number }} --json comments --jq '.comments[].body'`
          2. Only if, after gathering all available context, you still CANNOT confidently
             determine the correct resolution (e.g., two different implementations of the
             same function, divergent architectural decisions, conflicting business logic),
             bail out:
             a. Run `git rebase --abort`
             b. Output a report explaining what context you gathered, what you found
                ambiguous, and what specific guidance from the developer would help
          Do NOT guess when the intent is unclear — it is better to bail out than to
          silently produce an incorrect merge.

          After the rebase is fully complete (or after bailing out), output a concise
          Markdown report IN HUNGARIAN (with English technical terms, e.g. conflict,
          rebase, merge):
          - Minden conflict-os fájlhoz: a fájlnév és egy egysoros leírás a conflict-ról
            és annak feloldásáról (vagy bail-out esetén: miért nem volt meghatározható
            a szándék)
          - Bármilyen észrevétel, amit a PR szerzőjének érdemes átnéznie
          PROMPT

          if [ -n "$DISPATCH_INSTRUCTIONS" ]; then
            printf '\n' >> $WORK_DIR/rebase-prompt.txt
            printf 'DEVELOPER INSTRUCTIONS (a fejlesztő válasza egy korábbi bail-out-ra):\n' >> $WORK_DIR/rebase-prompt.txt
            printf '%s\n' "$DISPATCH_INSTRUCTIONS" >> $WORK_DIR/rebase-prompt.txt
            printf '\n' >> $WORK_DIR/rebase-prompt.txt
            printf 'The developer has reviewed the previous bail-out report and is providing\n' >> $WORK_DIR/rebase-prompt.txt
            printf 'explicit guidance. Follow their intent — these instructions take priority\n' >> $WORK_DIR/rebase-prompt.txt
            printf 'over the general confidence threshold.\n' >> $WORK_DIR/rebase-prompt.txt
          fi

          cat $WORK_DIR/rebase-prompt.txt | ${{ env.HOME }}/.local/bin/claude -p \
            --model opus \
            --allowedTools 'Bash,Read,Edit,Write,Glob,Grep' \
            > $WORK_DIR/rebase-report.txt

      - name: Verify rebase success
        if: always() && steps.rebase.outputs.result == 'dirty'
        id: verify
        run: |
          if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
            git rebase --abort 2>/dev/null || true
            echo "success=false" >> $GITHUB_OUTPUT
          elif ! git merge-base --is-ancestor origin/main HEAD; then
            echo "success=false" >> $GITHUB_OUTPUT
          else
            echo "success=true" >> $GITHUB_OUTPUT
          fi

      - name: Push Claude-resolved rebase
        if: steps.verify.outputs.success == 'true'
        run: git push --force-with-lease origin "${{ matrix.headRefName }}"

      - name: Remove conflict label
        if: steps.verify.outputs.success == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh pr edit "${{ matrix.number }}" --remove-label "conflict" 2>/dev/null || true

      - name: Report - conflict resolved
        if: steps.verify.outputs.success == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          {
            echo "♻️ **Auto-rebase**: conflict-ok Claude-dal feloldva."
            echo ""
            echo "📦 Backup: [\`${{ steps.backup.outputs.branch }}\`](${{ github.server_url }}/${{ github.repository }}/tree/${{ steps.backup.outputs.branch }})"
            echo ""
            echo "<details>"
            echo "<summary>Rebase riport</summary>"
            echo ""
            cat $WORK_DIR/rebase-report.txt
            echo ""
            echo "</details>"
          } > $WORK_DIR/pr-comment.md
          gh pr comment "${{ matrix.number }}" --body-file $WORK_DIR/pr-comment.md

      - name: Report - conflict resolution failed
        if: always() && steps.rebase.outputs.result == 'dirty' && steps.verify.outputs.success != 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          {
            echo "⚠️ **Auto-rebase**: a conflict-ok automatikus feloldása nem sikerült. Manuális rebase szükséges."
            echo ""
            if [ -s $WORK_DIR/rebase-report.txt ]; then
              echo "<details>"
              echo "<summary>Claude riport</summary>"
              echo ""
              cat $WORK_DIR/rebase-report.txt
              echo ""
              echo "</details>"
              echo ""
            fi
            echo "> A következő auto-rebase futás blokkolva lesz ezen a PR-on, amíg új commit nem érkezik."
            echo "> Vagy futtasd újra a workflow-t \`instructions\` paraméterrel a bail-out feloldásához."
            echo ""
            echo "<!-- auto-rebase-blocked:${{ steps.setup.outputs.head_sha }} -->"
          } > $WORK_DIR/pr-comment.md
          gh pr comment "${{ matrix.number }}" --body-file $WORK_DIR/pr-comment.md

      - name: Cleanup backup branch on failure
        if: always() && steps.rebase.outputs.result == 'dirty' && steps.verify.outputs.success != 'true' && steps.backup.outputs.branch != ''
        run: git push origin --delete "${{ steps.backup.outputs.branch }}" 2>/dev/null || true
