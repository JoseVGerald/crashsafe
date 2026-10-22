# Crash response RAG prototype

A local retrieval and evidence-bounded response system for the CAC crash assistant. The original research guide is included as background, not blindly indexed as advice.

## What is implemented

- 47 focused, source-linked answer cards and a 48-source register.
- Discovery-only notes excluded from indexing; per-card jurisdiction, stage, expiry and review status.
- Persistent SQLite FTS5/BM25 retrieval with weighted title and keyword fields.
- Optional genuine vector embeddings via local Ollama; cosine ranking fused with BM25 using reciprocal rank fusion.
- Bounded context size, 128-entry in-memory retrieval cache and a semantic query deadline.
- Local emergency-rule bypass, explicit emergency flags and two selectable response personas.
- Evidence-bounded response composition, citations, abstention and a ready-to-use context endpoint.
- Optional local model selection of evidence, constrained to existing card IDs. Model-written medical or insurance advice is never displayed.
- CLI, localhost HTTP API, automated tests and retrieval benchmarks.
- No external packages required for the default path. Python 3.11+ with SQLite FTS5.

**Readiness: prototype.** Source verification is not clinical approval. This is not a deployable emergency service, diagnostic tool, insurer integration or automatic 911 system. Production mode currently blocks all unapproved answer cards. Keyword emergency routing is intentionally conservative and incomplete.

## Why the single document was not enough

A source directory contains references and planned behavior, not complete domain knowledge. It mixed procedures, policy notes, examples, discovery leads and unresolved questions. Blindly chunking it would let draft material look like authoritative advice and could retrieve Washington rules for a crash elsewhere.

Here, behavior instructions stay outside the retrieval corpus. Each answer card is small and scoped. The full-text-unavailable sources remain in the register without becoming detailed advice. The cards cover a limited core plus recovery, family support, repair and coverage questions, with state reporting procedures for Washington, Oregon and California. They are not comprehensive medical or legal coverage.

## Run from the CrashSafe repository

The backend lives in Backend/rag. From the repository root:

~~~powershell
cd Backend/rag
python rag.py ingest
python -m unittest discover -s tests -v
python rag.py serve
~~~

The default path needs no model download or external Python packages. It creates a local index under data/. Optional transport adapters need numpy.

## API

GET http://127.0.0.1:8787/health

~~~powershell
$body = @{
  query = "Do I have to give a recorded statement?"
  jurisdiction = "WA"
  stage = "followup"
  persona = "practical"
} | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:8787/v1/answer -Method Post -ContentType application/json -Body $body
~~~

POST /v1/answer fields:

| Field | Values | Default |
|---|---|---|
| query | 1–4000 characters | required |
| jurisdiction | two-letter state or UNKNOWN | UNKNOWN |
| stage | active or followup | active |
| persona | auto, supportive or practical | auto |
| flags | optional booleans fire, unresponsive, serious_symptoms | none |

Structured flags are supplied by your application or user report; the RAG service does not derive reliable medical flags from sensors. The stage is explicit incident state, not guessed from emotional tone. Do not omit an active emergency flag because someone speaks calmly.

POST /v1/retrieve accepts query, jurisdiction, stage, limit (1–8) and max_context_chars (500–8000). Its default stage is followup. It returns short source-linked context for your existing agent. Add the supplied prompts/system.md as a system instruction, not as a retrieved document.

Response statuses: answered, emergency, insufficient_evidence, review_required. Every client must handle all statuses. Emergency answers explicitly state dispatch was not requested. Never translate that into a confirmation of help being sent.

## Semantic retrieval with Ollama

Ollama is optional and must already be installed and running locally. Pick and download an embedding model appropriate for the machine. Use the exact installed model name:

~~~powershell
python rag.py ingest --embedding-model YOUR_INSTALLED_EMBEDDING_MODEL
python rag.py benchmark --runs 200
python rag.py serve
~~~

Ingestion sends card text to the local /api/embed endpoint and stores normalized vectors. Each query tries a local embedding and falls back to BM25 if it exceeds the 250 ms retrieval deadline. Only two embedding requests can be in flight, preventing an unbounded queue. An in-flight HTTP call can continue up to its one-second timeout after retrieval falls back.

Cosine cutoff 0.55 and the rank-fusion settings are initial heuristics. They require evaluation for the selected embedding model. Changing embedding models requires re-ingestion. Small-corpus Python vector scanning suits this prototype; larger collections need a dedicated vector index.

## Optional model-assisted generation

~~~powershell
$env:CRASH_RAG_LLM_MODEL = "YOUR_INSTALLED_CHAT_MODEL"
python rag.py serve
~~~

The local /api/generate endpoint selects card IDs using structured output. Responses are composed from the selected card bodies, so a model cannot insert invented clinical or claims advice. Unsupported IDs, malformed output or a two-second timeout trigger deterministic fallback.

This is deliberately evidence-bounded RAG, not open-ended conversational generation. To use your own general AI agent, call /v1/retrieve and pass the returned context with the system prompt. That integration permits paraphrasing and needs a separate factuality and safety evaluation. No provider credentials are collected by this package. No end-to-end model latency is claimed when a model has not been installed and tested.

## Speed and privacy

The fastest path has no query embedding, network call or language-model generation. Index building is offline. A lexical query opens the local read-only index, retrieves a few cards and composes a response. Results are cached in memory, never written as incident logs.

The cache can contain sensitive query text in process memory. Restart clears it. It is a single-user local prototype, without authentication or tenant separation; do not expose it to a network or reuse it as a multi-user service. The API binds to 127.0.0.1 and rejects cross-origin browser POSTs. Integrate through a trusted local/backend client. Cloud hosting requires authentication, authorization, TLS, quotas, isolation and a separate privacy design.

See VALIDATION.md for measurements from this machine. Retrieval time is not model, voice, device or emergency-response latency.

## Updating the knowledge

Edit knowledge/corpus.json, then run:

~~~powershell
python sync_knowledge.py
python sync_knowledge.py --check
python rag.py ingest
python -m unittest discover -s tests -v
~~~

The exporter updates the Swift offline cards and knowledge/SOURCE_CATALOG.md from the same corpus. CI checks for stale generated files. Do not edit generated blocks directly. Every card has:
id, title, body, terms, scope, stage, source_ids, status, verified, expires and professional_review.

- scope: US for general U.S. content or a state abbreviation.
- stage: any, active or followup.
- status: discovery_only, source_verified or clinician_approved.
- expires: ISO date; expired cards are filtered even if present in the index.
- body: one focused statement or short procedure; preserve conditions and exceptions.

Keep laws and coverage separate. State-specific reporting, insurer duties and deadlines require current controlling material. Do not infer benefits from general insurance articles. Keep uploaded policies out of the shared corpus until per-user isolation is implemented.

Ingest validates source references and IDs before replacing the existing index. A failed ingest preserves the prior database. It does not approve content or automatically fetch website updates.

Before editing a status to clinician_approved, record the actual reviewer and review evidence in a separate controlled review log. Do not do that merely to enable production mode.

Production trial command:

~~~powershell
python rag.py serve --production
~~~

Currently this returns no corpus advice because no card has professional approval. Emergency results become a minimal review-required response. This switch is a review filter, not a certification or complete compliance control.

## Known gaps

- Only a small core corpus. No complete pediatric, pregnancy, anticoagulant, water-submersion or extraction protocols.
- Keyword rules miss paraphrases, misspellings and context; negative statements and hypothetical questions cannot all be classified reliably.
- The retrieval threshold is heuristic; no retrieval system proves an answer medically appropriate.
- Citations identify the source of the card; exact paragraph anchors and archived full-text evidence should be added during professional review.
- No reliable medical triage, consciousness detection, automatic emergency calling, insurer actions or real provider availability.
- No policy-document upload, user accounts, long-term conversation memory or protected health profile storage.
- Source freshness requires human review; expiry may intentionally cause abstention until updated.
- Default tests validate software behavior and a small authored query set, not clinical outcomes.
- Optional Ollama model calls are covered by contract mocks until real models are available.

## Primary technical references

- SQLite FTS5 and BM25: https://www.sqlite.org/fts5.html
- Ollama API: https://docs.ollama.com/api
- Ollama embeddings: https://ollama.com/blog/embedding-models
- Ollama structured outputs: https://ollama.com/blog/structured-outputs

Current medical, psychological and insurance sources, access status, reviewed sections and associated cards are listed in [knowledge/SOURCE_CATALOG.md](knowledge/SOURCE_CATALOG.md). The original guide is historical background. No framework, hosting service, paid API or database account is required.


## Repository integration update

See [INTEGRATION.md](INTEGRATION.md) for the CrashSafe app adapter, typed incident context, transport event adapter, isolated developer knowledge index and current validation limits. New endpoint: POST /v1/assist. Repository context endpoint: POST /v1/developer/retrieve.

## October 22, 2026 expansion

Added 13 primary-source pages and upgraded the NIMH children-and-trauma source from a search extract to a full-page review. Added 27 cards on concussion recovery, air bags, internal bleeding, chest injury, optional coping, family support, repair authorization, replacement parts, GAP and uninsured coverage, and WA/OR/CA procedures. Washington repair-inspection and towing explanation cards use the WAC version effective October 18, 2026.

Supportive and practical styles use the same evidence. Emotional support is optional, does not diagnose PTSD, and is separated from immediate crash procedures through stage filters. State selection is explicit; no state-specific reporting deadline is supplied for an unknown location. The two discovery-only cards remain quarantined. New cards expire January 20, 2027 pending renewed review; no card has professional approval.
