# AGENTS.md

## Goal

Build and maintain this application with minimal, targeted changes.

For Android text-pilot implementation, follow [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md). Read its references only for the active step; do not implement later roadmap features.

## Context efficiency

- Do not scan the entire repository by default.
- Start from files directly related to the requested task.
- Expand the search only when the current files are insufficient.
- Avoid reading large files unless needed.
- Avoid generated code, dependencies, caches, build outputs, binaries, assets, and lockfiles unless directly relevant.

## Implementation

- Prefer the smallest correct change.
- Do not refactor unrelated code.
- Prefer modifying existing implementations over introducing new abstractions.
- Do not add dependencies unless necessary.
- Follow existing project patterns before introducing new ones.
- Preserve existing architecture unless the task explicitly requires changing it.

## Investigation

When locating code:

1. Search for the relevant symbol, feature, screen, route, or service.
2. Inspect the smallest set of matching files.
3. Follow imports/references only when necessary.
4. Stop exploring once enough context exists to implement the task.

Do not perform a repository-wide architectural review unless explicitly requested.

## Testing

- Run the narrowest relevant test first.
- Prefer tests related to changed files/features.
- Do not repeatedly run the full test suite during implementation.
- Run expensive full-project checks only when justified.

## Mobile development

- Follow existing UI/component conventions.
- Reuse existing components before creating new ones.
- Avoid unnecessary platform-specific changes.
- Do not modify Android/iOS native configuration unless required by the task.

## Git

- Do not modify unrelated files.
- Do not reformat unrelated code.
- Review the diff before finishing.

## Response

Keep the final response concise.

Include only:

- what changed
- files changed
- tests/checks performed
- important unresolved issue, if any

Do not paste complete files unless requested.
