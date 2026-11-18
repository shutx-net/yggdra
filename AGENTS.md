# Agent Instructions

These instructions apply to the entire repository. Keep this file short and repository-wide; put package-specific rules, interfaces, and procedures in dedicated documentation, then link them below.

## Project intent

- Build a local-first, native tool for exploring and auditing software architecture, including code written by AI agents.
- Odin owns the language-agnostic core and native graph viewer. Analyzers are separate processes; Go is the first supported language.
- Source files are the source of truth. Graphs, caches, and snapshots are derived artifacts, not authoritative definitions.
- Keep the MVP narrow. Do not add OpenAPI, IaC, more language analyzers, cloud dependencies, or a web UI unless requested.

## Architecture principles

- Separate **analysis**, **graph semantics**, **layout**, and **rendering**. No analyzer-specific logic in the core or visual styling in analyzer output.
- Keep analyzer integration language-neutral and process-isolated, using an explicit, versioned data contract.
- Model relationships precisely: preserve source locations and evidence; distinguish established facts from inferred or unresolved relationships.
- Prefer deterministic graph output, stable identities, and reproducible analysis over visual polish.
- Choose small, reversible implementations over speculative abstractions. Avoid introducing frameworks or dependencies without a concrete need.
- Treat analyzed code and plugin output as untrusted. Validate inputs, handle failures, avoid implicit code execution, and do not introduce unexpected network access.

## Working rules

- Inspect the actual repository, relevant documentation, and tests before changing code. Do not assume planned paths or commands already exist.
- Make focused changes; preserve unrelated work. Follow the conventions of the code you touch.
- For changes to shared contracts, update every affected producer, consumer, fixture, and test together; version breaking formats explicitly.
- Add or update meaningful tests for changed behavior. Prefer deterministic, offline tests; isolate GUI-dependent verification.
- Run the repository's documented formatting, build, lint, and test commands where applicable. Never invent commands or claim checks passed if they were not run.
- Report what changed, what was verified, and any limitations or unresolved assumptions.
- Never commit secrets, proprietary fixtures, generated build artifacts, or unnecessary dependencies.

## Detailed documentation

Package-specific instructions belong in separate documents, **not** in this file. Add Markdown links here as those documents are created, and read the relevant documents before editing their components.

<!-- Add links to existing documentation here, e.g. - [Graph model](docs/graph.md). Do not add broken links. -->
