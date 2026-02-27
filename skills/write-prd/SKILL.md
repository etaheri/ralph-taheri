# /write-prd — PRD Authoring

Guided creation of a Product Requirements Document. Explores the codebase, interviews the user, and produces a structured PRD.

Adapted from [mattpocock/skills/write-a-prd](https://github.com/mattpocock/skills/tree/main/write-a-prd).

## Instructions

### Step 1: Problem Description

Ask the user to describe the problem or feature they want to build. Get a detailed understanding of:
- What problem are we solving?
- Who is the target user?
- What does success look like?

### Step 2: Explore the Codebase

Before writing anything, explore the existing codebase to understand:
- **Tech stack** — frameworks, languages, build tools
- **Architecture** — how the app is structured (monolith, microservices, etc.)
- **Existing patterns** — how similar features are currently implemented
- **Data models** — relevant database schemas or data structures
- **Integration points** — APIs, services, or libraries involved

Share your findings with the user.

### Step 3: Design Interview

Ask clarifying questions to resolve design decisions. Focus on:
- **Scope boundaries** — what's in and out of scope?
- **User flows** — what are the key user journeys?
- **Edge cases** — what happens when things go wrong?
- **Technical constraints** — performance, security, compatibility requirements
- **Dependencies** — what external services or APIs are involved?

Ask 3-5 questions at a time. Iterate until the design is clear.

### Step 4: Identify Modules

Based on the exploration and interview, identify:
- **Modules to build** — new code that needs to be written
- **Modules to modify** — existing code that needs changes
- **Deep modules** — look for opportunities to create simple interfaces that hide complexity (per John Ousterhout's "A Philosophy of Software Design")

### Step 5: Write the PRD

Create a structured PRD with these sections:

```markdown
# <Feature Name> — PRD

## Problem Statement
What problem are we solving and why?

## Target Users
Who benefits from this?

## Goals
- Goal 1
- Goal 2

## Non-Goals
- Explicitly out of scope item 1
- Explicitly out of scope item 2

## Current State
What exists today? What's the starting point?

## Proposed Solution

### Overview
High-level description of the solution.

### User Flows
1. Flow 1: step-by-step
2. Flow 2: step-by-step

### Technical Design
Architecture, data models, APIs, etc.

### Modules
| Module | Type | Description |
|--------|------|-------------|
| module-name | New/Modify | What it does |

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Open Questions
- Question 1
- Question 2

## Dependencies
- External service/API 1
- Library/package 1
```

### Step 6: Review and Save

Present the PRD to the user for review. Iterate until approved.

Once approved, ask the user where to save it:
- **GitHub Issue** — create as a GitHub issue with the `prd` label
- **Linear Issue** — create as a Linear issue
- **Local file** — save to a markdown file

### Step 7: Next Steps

Suggest the user run `/seed-issues` or `./seed.sh` to break the PRD into implementable issues.

## Rules

- Always explore the codebase before writing the PRD
- Ask questions in batches of 3-5, not all at once
- Look for deep module opportunities (simple interfaces, hidden complexity)
- Keep the PRD focused — better to have a tight PRD than an exhaustive one
- Include explicit non-goals to prevent scope creep
- Make acceptance criteria specific and testable
