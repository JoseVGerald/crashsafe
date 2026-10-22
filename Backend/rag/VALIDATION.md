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
