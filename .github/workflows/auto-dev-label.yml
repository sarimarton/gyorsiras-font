name: Auto-dev label

on:
  issues:
    types: [opened]

permissions:
  issues: write

jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - name: Add ai label to new issues
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh label create "ai" \
            --repo "${{ github.repository }}" \
            --color "1d76db" \
            --description "Auto-dev: pool identifier" \
            --force 2>/dev/null || true
          gh issue edit "${{ github.event.issue.number }}" \
            --repo "${{ github.repository }}" \
            --add-label "ai"
