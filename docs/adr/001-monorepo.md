# ADR-001: Monorepo Structure

## Status
Accepted

## Context
SSOP has multiple components (frontend, orchestrator, cloud-init templates, scripts, docs). We need to decide how to organize the codebase.

## Decision
Use a single monorepo with top-level directories per component.

## Rationale
- Small team (one human + one agent) — monorepo reduces coordination overhead
- Shared tooling (linting, CI) across components
- Atomic commits across frontend + orchestrator changes
- Single place for docs and ADRs

## Consequences
- Need clear directory boundaries
- CI pipeline must be component-aware (don't rebuild everything on every change)
- If frontend grows large, can extract later
