# /seed-issues — Interactive PRD to Issues

Break a Product Requirements Document into vertical-slice issues with dependency mapping. This is the interactive version of `seed.sh`.

Adapted from [mattpocock/skills/prd-to-issues](https://github.com/mattpocock/skills/tree/main/prd-to-issues).

## Instructions

### Step 1: Get the PRD

Ask the user for the PRD source:
- A file path to a markdown PRD
- A GitHub issue number containing the PRD
- A Linear issue identifier containing the PRD

Read the PRD content.

### Step 2: Choose Backend

Ask the user which backend to use:
- `github` — GitHub Issues (requires `gh` CLI)
- `linear` — Linear (requires `LINEAR_API_KEY` and team key)

### Step 3: Explore the Codebase

Before breaking down the PRD, explore the existing codebase to understand:
- Current architecture and tech stack
- Existing patterns and conventions
- What already exists vs. what needs to be built
- Integration points and boundaries

### Step 4: Create Vertical Slices

Break the PRD into **vertical slices** (tracer bullets):

1. **Start with a walking skeleton** — the thinnest possible end-to-end slice that proves the architecture works
2. **Add functionality in thin slices** — each slice cuts through ALL layers (UI → API → DB), not just one
3. **Each slice is independently demoable** — you can show it to a stakeholder and they see something working
4. **Map dependencies explicitly** — if slice B needs slice A done first, note it

For each slice, create an issue with:

```markdown
## What to build
Concise description of this vertical slice — the end-to-end behavior, not layer-by-layer.

## Acceptance criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Typecheck passes

## Blocked by
- #<issue-number> (or "None - can start immediately")
```

### Step 5: Review with User

Present the breakdown to the user:
- Show each issue with title, description, acceptance criteria
- Show the dependency graph
- Show estimated priority (P0-P3)

Ask for feedback and iterate until the user approves.

### Step 6: Create Issues

Once approved, create the issues in the selected backend:

**For GitHub:**
```bash
gh issue create --title "<title>" --body "<body>" --label "ralph-taheri" --label "P<n>"
```

**For Linear:**
Use the Linear GraphQL API to create issues with the `ralph-taheri` label, appropriate priority, and dependency relations.

Create issues in dependency order (blockers first) so real issue numbers are available for "Blocked by" references.

### Step 7: Summary

Show the user:
- All created issues with numbers/identifiers
- The dependency graph
- How to run the agent loop: `./ralph-taheri.sh --backend <backend> <count>`

## Rules

- Always use **vertical slices**, never horizontal slices
- Each slice must be independently verifiable
- Keep it to 4-12 issues for most PRDs
- Every issue must have at least 2 acceptance criteria
- Include "Typecheck passes" where applicable
- Start with the thinnest possible walking skeleton
- The last slice should be "polish and integration testing"
