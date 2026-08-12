# kin-lsp

> Language-server integration boundary for the Kin graph.

`kin-lsp` drives standard language servers and turns their answers into graph
relations. Tree-sitter parsing gives Kin syntax-level structure. `kin-lsp` adds
the type-resolved relations that only a language server can settle: call edges
from call hierarchy, override edges from type hierarchy, cross-file type-usage
edges from go-to-type-definition, and reference edges from find-references.

It is the language-server integration boundary in the open Kin local substrate.
`kin` depends directly on this standalone repo through the `kin` cargo registry,
and merges the relations it returns into the graph, where `kin-db` stores them as
first-class edges. Ranking, proof-weighting, and graph storage live above this
crate, not inside it. Enrichment is an addon over Kin's own parsers and linkers,
never a replacement for them.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Part of Kin](https://img.shields.io/badge/part%20of-Kin-6E56CF.svg)](https://github.com/firelock-ai/kin)

## What is Kin?

Kin is the system of record for AI-written software: your code as a graph of
entities, relations, and intents, not a pile of files and diffs. AI agents and humans
navigate it semantically, with provenance, review, and governance built in. It coexists
with Git and projects graph truth back to a normal filesystem, so any tool works unchanged.

Start at **[firelock-ai/kin](https://github.com/firelock-ai/kin)** · **[kinlab.ai](https://kinlab.ai)**

## Build

```bash
cargo build
cargo test
```

There are no compile-time feature flags. Which language servers are usable is a
runtime question, not a build-time one, so the crate compiles the same way on a
machine with no servers installed.

The integration tests under `tests/` drive a real `rust-analyzer` against a
sibling `kin` checkout. Each one prints `SKIP` and passes when the binary or the
checkout is missing, so a plain `cargo test` stays green on a bare machine.
Install the server with `rustup component add rust-analyzer` to exercise them for
real.

## Providers

`ProviderRegistry::with_defaults()` seeds the languages Kin knows how to drive.
Binary names are searched on `PATH` in preference order, and the first one found
wins.

| Language | Providers, in preference order |
|----------|--------------------------------|
| Rust | `rust-analyzer` |
| Python | `pyright` (`pyright-langserver`), then `pylsp` |
| TypeScript | `typescript-language-server`, then `vtsls` |
| JavaScript | `typescript-language-server` |
| Go | `gopls` |
| Java | `jdtls` (Eclipse JDT Language Server) |
| C and C++ | `clangd`, which wants a `compile_commands.json` to index against |

Every provider declares the capabilities Kin expects of it, and the live
`initialize` handshake decides what it actually serves. The gap between the two
is recorded rather than assumed. `LspCapability::CITABLE_MINIMUM` is the floor:
without go-to-definition and find-references a pass produces effectively nothing,
so a required server below that floor fails loud instead of running degraded.

A language with no server on `PATH` is not skipped quietly. The registry returns
a `ProviderGap` naming the language, the reason, and every provider it tried, so
a run that enriched less than it should says so.

Per-server launch details live beside the registry in `src/adapters/`, one small
`LspAdapter` impl each: the file extensions it claims, the initialization options
it sends, and whether it needs a workspace index before answers are trustworthy.

## How it feeds the graph

During ingest, or when the `kin` daemon reacts to a changed file, `kin` calls
into `kin-lsp` to enrich a set of source files.

1. `discovery.rs` and `registry.rs` resolve the provider for each language.
2. `lifecycle.rs` spawns the server and runs the LSP `initialize` handshake.
   `enrichment.rs` drives `prepareCallHierarchy` with
   `callHierarchy/outgoingCalls`, `prepareTypeHierarchy` with
   `typeHierarchy/supertypes`, `textDocument/typeDefinition`, and
   `textDocument/references`. `file_enrichment.rs` drives the per-file
   `textDocument/definition` pass.
3. Results come back as an `EnrichmentResult` built from `kin-model` types. The
   relations are `Calls`, `Overrides`, `UsesType`, and `References`, each tagged
   `RelationOrigin::Lsp` so it is always distinguishable from a tree-sitter or
   linker-derived edge. `stamp_lsp_provenance` attaches the finer record of
   provider, version, and capability; the caller applies it, because only the
   caller knows which server it just drove.
4. `kin` merges the relations into the graph through `kin-db`, where they become
   edges with content hashes and provenance.

`cache.rs` keeps an in-memory cache keyed by file content hash, so a file that
did not change skips re-enrichment within a session. Servers are started for an
enrichment pass and shut down cleanly with `shutdown` and `exit`. The crate holds
no long-lived background processes of its own; the `kin` daemon owns the
enrichment schedule and calls in when it wants work done.

## Key types

- `EnrichmentResult`, `EntityRef`, `EntityIndex`: what a pass returns, and the
  index it matches LSP locations against to find graph entities.
- `ProviderRegistry`, `ResolvedProvider`, `ProviderProbe`: the provider model,
  from static defaults through a binary found on `PATH` to a live server and the
  capabilities it reported.
- `ProviderGap`, `ProviderGapReason`: why a language produced nothing.
- `LspCapability`: the five LSP requests enrichment consumes, plus the citable
  minimum a required server has to meet.
- `LspProvenance`, `stamp_lsp_provenance`: the provider, version, and capability
  record carried by an LSP-derived relation.
- `LspEnrichmentProof`, `ProofRecorder`, `ProofMode`, `ProofViolation`: the
  per-run record of which servers ran, at which versions, and what they produced.
- `RegistryConfig`: per-repo settings for which provider serves a language, which
  languages are required, and which are disabled.
- `LspError`, `Result`: typed errors.

## License

[Apache-2.0](LICENSE).
