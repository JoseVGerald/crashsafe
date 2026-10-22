# Validation

Date: October 21, 2026. Runtime: Python 3.14.6, SQLite 3.50.4, Windows.

## Results

- 32 automated tests passed.
- 14/14 authored query cases retrieved their expected evidence card in the top 4.
- 500 local lexical retrieval requests with changing suffixes to avoid exact-query cache hits.
- Median retrieval: 0.554 ms.
- 95th percentile retrieval: 0.712 ms.
- 20 indexed cards, 2 discovery-only notes excluded, 35 source records.

These are small-corpus, warm-process measurements on this machine. They do not establish performance on an iPhone, large corpus, different machine, voice pipeline or clinical setting. They exclude model generation and query embedding.

Tests cover HTTP requests, input validation, prompt-like FTS input, corpus validation, expired content, jurisdiction isolation, discovery-note exclusion, production review filtering, active/follow-up separation, emergency rules, persona choice, model output validation, semantic fusion and timeout fallback.

## What was exercised live

Real SQLite index creation and retrieval, default evidence-bounded answers, temporary HTTP server requests and model-independent emergency responses.

## What was tested with mocks

Local embedding results, local model evidence selection, unavailable model, invalid model selection and slow embedding fallback. The local Ollama service was not available. No downloaded model was installed, so semantic quality, real model latency and real structured-output compliance remain unmeasured.

## Coverage limitations

The 14 authored cases are development fixtures, not an independent evaluation dataset. They do not prove robust paraphrase understanding. Keyword routing is not a medical triage system. Citations and exact-card composition prevent unsupported generated wording, but an inappropriate retrieved card can still produce an inappropriate response.

The 20 source-linked cards are editorial research summaries. None has professional clinical or legal approval. Production mode blocks these unapproved cards rather than treating software tests as professional review.

Raw test output: tests/latest-results.txt. Benchmark output: tests/benchmark.json.

## Location

Built in the session's permitted workspace. E:\test was readable but outside the configured writable roots. The package is intended for extraction into E:\test; no claim is made that files were written there.


## Repository integration validation

60 Python tests passed after integrating typed incident context, isolated repository retrieval and real upstream behavior-module invocation. See tests/integration-results.txt and INTEGRATION.md. Four Swift tests were added but not executed on Windows. The developer index contains 66 excerpts from 15 selected files.

## Source expansion verification — October 22, 2026

- Corpus: 48 source records; 47 answerable editorial cards; 2 discovery-only cards excluded. Thirteen new sources and one full-page source upgrade.
- Python: 67 tests passed, including actual upstream adapter tests using local checked-out repositories. Clean CI skips repository-dependent tests when the generated local manifest is absent.
- Authored retrieval examples: 43/43 expected cards found in the top four. This is a regression set, not an independent clinical or generalization evaluation.
- Local lexical retrieval, 500 varied requests: median 0.640 ms; p95 0.858 ms. No embedding model configured. Excludes language-model, voice, device and network latency.
- Offline Swift arrays and readable source catalog generated from the corpus; parity checked by Python and CI. Generation consistency does not execute or validate Swift behavior.
- State and stage isolation regression tests added. Washington regulation cards explicitly use the version effective October 18, 2026.
- Xcode/iOS build, real-device offline ranking, and live embedding/generation remain untested on this Windows environment. Source review remains editorial; clinical and legal review are pending.
