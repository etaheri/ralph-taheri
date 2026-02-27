# ralph-taheri

An autonomous AI agent loop that uses **GitHub Issues** or **Linear** as the source of truth. It runs Claude Code in a loop — picking up the next issue, implementing it, optionally verifying with agent-browser, committing, and closing the issue — until all work is done.

## Attribution

This project builds on ideas and code from:

- **[snarktank/ralph](https://github.com/snarktank/ralph)** (MIT) — The autonomous agent loop pattern. ralph-taheri adapts the loop architecture and prompt structure, replacing `prd.json` with GitHub Issues / Linear.
- **[mattpocock/skills](https://github.com/mattpocock/skills)** — The `prd-to-issues` skill (vertical slice / tracer bullet breakdown, issue template with dependency tracking) and `write-a-prd` skill (PRD structure and interview process) inform the seed script and skill design.
- **[vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)** (Apache-2.0) — Browser verification in the loop.

## Quick Start

### Prerequisites

```bash
./setup.sh  # Check and install dependencies
```

### Using GitHub Issues

```bash
# 1. Create issues from a PRD
./seed.sh --backend github --prd examples/example-prd.md

# 2. Run the agent loop
./ralph-taheri.sh --backend github 10
```

### Using Linear

```bash
# Set your API key
export LINEAR_API_KEY="lin_api_..."
export LINEAR_TEAM_KEY="ENG"

# 1. Create issues from a PRD
./seed.sh --backend linear --prd examples/example-prd.md --team ENG

# 2. Run the agent loop
./ralph-taheri.sh --backend linear 10
```

### With Browser Verification

```bash
# Verify UI changes with agent-browser before closing issues
./ralph-taheri.sh --backend github --verify 10
```

## How It Works

1. **Query** the issue backend for the next open issue labeled `ralph-taheri`
2. **Mark** the issue as in-progress
3. **Spawn** a fresh Claude Code session with the issue details injected into the prompt
4. **Implement** the issue (Claude reads the codebase, writes code, runs tests)
5. **Verify** (optional) with agent-browser — screenshot, visual diff, element checks
6. **Commit** with a formatted message: `feat: #<issue-id> - <title>`
7. **Close** the issue with a summary comment
8. **Repeat** until no issues remain or max iterations reached

## Seed Script

The seed script (`seed.sh`) converts a PRD into issues using **vertical slices** (tracer bullets) — thin end-to-end cuts through all layers, not horizontal slices.

```bash
./seed.sh --backend github --prd path/to/prd.md
./seed.sh --backend linear --prd path/to/prd.md --team ENG
```

Each issue follows a consistent template with acceptance criteria, dependency tracking, and priority labels.

## Claude Code Skills

Install these skills in Claude Code for interactive use:

### `/seed-issues` — Interactive PRD to Issues

Interactively break a PRD into vertical-slice issues with dependency mapping. The interactive version of `seed.sh`.

### `/write-prd` — PRD Authoring

Guided PRD creation with codebase exploration and design decision interviews.

## Configuration

| Variable | Required | Description |
|---|---|---|
| `GITHUB_REPO` | GitHub backend | Repository in `owner/repo` format (auto-detected from git remote) |
| `LINEAR_API_KEY` | Linear backend | Linear API key (`lin_api_...`) |
| `LINEAR_TEAM_KEY` | Linear backend | Linear team key (e.g., `ENG`) |

## How It Differs from ralph

| Feature | ralph | ralph-taheri |
|---|---|---|
| Task source | `prd.json` file | GitHub Issues or Linear |
| Task format | JSON tasks array | Issue with acceptance criteria |
| Collaboration | Single user | Team via issue tracker |
| Verification | Manual | Optional agent-browser gate |
| Task creation | Manual JSON editing | `seed.sh` or `/seed-issues` skill |
| Priority | Array order | Issue labels / Linear priority |

## Project Structure

```
ralph-taheri/
├── README.md              # This file
├── LICENSE                # MIT with attribution
├── ralph-taheri.sh        # Main loop script
├── CLAUDE.md              # Prompt template for Claude Code
├── seed.sh                # PRD → Issues converter
├── setup.sh               # Dependency checker/installer
├── lib/
│   ├── github.sh          # GitHub Issues backend
│   ├── linear.sh          # Linear API backend
│   └── verify.sh          # agent-browser verification
├── skills/
│   ├── seed-issues/
│   │   └── SKILL.md       # Interactive PRD → Issues skill
│   └── write-prd/
│       └── SKILL.md       # PRD authoring skill
├── examples/
│   └── example-prd.md     # Example PRD
└── progress.txt           # Runtime learnings log (auto-created)
```

## License

MIT — see [LICENSE](LICENSE) for details and attribution.
