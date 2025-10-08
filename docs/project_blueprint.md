# SOCINT Platform Transformation Master Plan

## Chapter 1. Vision & Guiding Principles
- **Core Mission**: Deliver repeatable, defensible psychological analysis on any publicly observable target by orchestrating multi-source intelligence, behavioural science tooling, and analyst workflows into a single platform experience.
- **Objective**: Transform the initial n8n-style workflow into a secure, scalable, and interactive SOCINT (Social Intelligence) platform capable of collecting, analysing, and presenting psychological insights on public personas while prioritising evidence-backed psychological models over generic data aggregation.
- **Constraints & Environment**:
  - Windows 11 Pro host with 64 GB RAM and RTX 4060 (8 GB).
  - Strictly no Docker, VM, or n8n in production; native Windows services with IIS (or Windows-compatible alternatives) and HTTPS certificates.
  - Entire stack deployable locally with zero-downtime (blue/green) release capabilities.
- **Explicitly Disallowed Tooling**: Maintain an allow/deny inventory covering Docker, VM hypervisors, n8n, and any browser automation without robots.txt compliance. Flag any new ingestion connector for legal/ethics review before activation.
- **Non-Functional Goals**: Maintainable architecture, compliance-ready (privacy-by-design), modular security, and actionable intelligence output.

## Chapter 2. High-Level Architecture Overview
| Layer | Primary Technologies | Responsibilities |
| --- | --- | --- |
| Presentation | **Next.js 14 + TypeScript**, Tailwind CSS, Headless UI | Responsive UI, target input, dashboards, reporting.
| Application/API | **Rust** (Axum or Actix Web), Tokio, Serde | REST/GraphQL APIs, orchestration, auth, business logic.
| Data Processing & AI | Rust services + Python micro-workers (optional) leveraging **Ollama** (Llama 3, Mistral), ONNX Runtime, NVIDIA GPU acceleration | Summarisation, credibility scoring, psychological modeling (8-factor/Big Five mapping), temporal progression analysis.
| Data Storage | **SQL Server 2022**, Redis 7 (Windows native build), local file/object storage | Core schema, cache, binary artefacts, audit logs.
| Data Collection | SearXNG proxy, Wikipedia, Tavily, Perplexity APIs, ethical web scrapers (Playwright), RSS/Atom feeders, public/open APIs, newsroom research APIs, transcript services, social media connectors | Aggregated multi-source intelligence gathering with caching & resilience via compliant data channels, prioritising official feeds and rate-limit-aware collectors with per-source guardrails.
| Psychological Knowledge Graph | Neo4j Desktop (optional), SQL Server graph extensions, Rust-based entity resolution | Persist relationships between personas, organisations, events, and psychological vectors to surface cross-target behavioural patterns and inconsistencies. |
| Operations | **Caddy Edge** reverse proxy + IIS/ASP.NET Core Module in hybrid mode, Windows Services, PowerShell automation, GitHub Actions (optional) | Deployment, monitoring, blue-green rollout, certificate renewal with selectable edge gateway.

## Chapter 3. Roadmap by Epics & Phases
1. **Epic 1 – Platform Foundation Infrastructure**
   - Feature 1.1, 1.2, 1.3, 1.4 plus supporting stories (1.1.1, 1.1.2, 1.2.1, 1.2.2A/B, 1.3.1, 1.4.1A/B).
   - Deliverables: Next.js foundation, authentication flows, SQL Server schema, Redis cache, RBAC middleware, caching abstraction, hybrid edge gateway control (Feature 1.5), baseline psychological signal taxonomy.
2. **Epic 2 – Core Analysis Platform**
   - Feature 2.1 (2.1.1A/B), Feature 20 (visual dashboard), 44 (8-factor component), 19 (auto-save), 18 (validation).
   - Deliverables: Input flows, live validation, autosave, radar charts, analysis dashboards.
3. **Epic 3 – Advanced Intelligence Features**
   - Features 27–29, 45, data validation, credibility scoring, multi-layer caching enhancements, cross-target psychological correlation services.
4. **Epic 4 – Enterprise Integration Platform**
   - Features 30–32, 4.1.1A/B, hardware key auth, AD/SAML, device management, compliance logging.
5. **Epic 5 – Data Collection & Intelligence Platform**
   - Features 36–43, 37, 38, 39, 40, 41, 42, 46; resilient data ingestion pipelines, circuit breakers, social media integrations, and adaptive workload schedulers tuned to analytics demand.

Each epic decomposes into sprints combining backend, frontend, and ops tasks. Milestones align with feature parity and security readiness.

## Chapter 4. Detailed Feature Breakdown
### Feature 1.1 – Web Frontend Foundation
- Implement Next.js 14 with App Router, TypeScript, and pnpm workspace.
- Establish shared UI library (`frontend/components/ui`), Tailwind theme, dark/light modes.
- Provide layouts for Target Input Interface (Story 1.1.1) and Analysis Results Dashboard (Story 1.1.2).
- Integrate progress indicators, skeleton loaders, and WebSocket/Server Sent Events hooks for long-running jobs.
- Embed persona context switcher, session playback, and hypothesis tagging widgets so analysts can pivot between psychological narratives quickly.

### Feature 1.2 – Multi-Tier Authentication System
- **Stories 1.2.1, 1.2.2, 1.2.2A/B**: NextAuth (credentials provider) replaced with custom Rust auth service.
- Implement JWT issuance (Features 12 & 21) with refresh/blacklist tables, plus API key management.
- Plan hardware security key integration (Feature 30, 31) via WebAuthn during Epic 4.
- Provide Active Directory connector blueprint using LDAP or Azure AD Graph when ready.
- Add adaptive authentication prompts leveraging psychological risk scores (e.g., escalate to WebAuthn when sensitive personas are queried).

### Feature 1.3 – Database Foundation
- **Stories 9, 15, 16, 33, 34**: Design ERD with tables: `Users`, `Roles`, `Permissions`, `Sessions`, `Profiles`, `PsychAnalysis`, `CommunicationGuides`, `SearchCache`, `ResearchData`, `SourceCredibility`, `SystemLogs`.
- Use Rust `sqlx` or `tiberius` for SQL Server connectivity. Include migration tooling (Barrel or custom `sqlx migrate`).
- Ensure row-level security concept via stored procedures or filtered views.
- Pre-model target baselines by storing canonical psychological factor templates for fast comparison against new data bursts.

### Feature 1.4 – Caching Infrastructure
- **Stories 10, 1.4.1A, 1.4.1B, 45**: Install Redis on Windows as a service. Implement layered caching (in-memory via DashMap, Redis, and persisted search cache table).
- Provide TTL strategy: hot results 5 min, curated intelligence 24 h, metadata 12 h.
- Add monitoring hooks (Prometheus exporters for Windows, optionally WMI counters).
- Implement GPU-aware cache warming to pre-compute embeddings and psychological vectors during off-peak hours, balancing workload with RTX 4060 VRAM constraints.

### Feature 1.5 – Hybrid Edge Gateway Control
- Provision both IIS and **Caddy Edge** on the Windows host, with Caddy terminating TLS and optionally proxying into IIS or bypassing it entirely.
- Build an infrastructure control panel inside the admin portal that surfaces gateway health, current routing mode, and a **single-button switch** to toggle between "Caddy → IIS" and "IIS direct" paths with scripted fail-safes.
- Automate configuration swaps via PowerShell/`caddy.exe` API and IIS AppCmd commands, including certificate sync, site binding updates, and warmup checks before promoting the alternate edge.
- Log all toggle events to `SystemLogs` with operator identity, pre- and post-state, and roll back automatically if health probes fail.

### Feature 2.1 – Visual Profile Dashboard
- **Stories 2.1.1A/B, 20, 44**: Build 8-factor radar chart with d3.js or Recharts. Provide accessible list view with color-coded confidence scores.
- Create drill-down modals for factor details, source references, and recommended communication guide entries.
- Layer in persona timelines and life-event markers aligned to the 8 factors, enabling analysts to correlate behavioural shifts with external triggers.
- Implement autosave (Story 19) via IndexedDB fallback and Redis session store.
- Surface cross-channel sentiment deltas and alert analysts when recent signals diverge sharply from long-term psychological baselines.

### Feature 3.1 – Multi-Source Data Validation
- **Stories 27–29**: Cross-verify data by comparing textual embeddings (e.g., Sentence Transformers on GPU) and scoring sources using credibility algorithm, including psychological consistency checks across time and channels.
- Maintain `SourceCredibility` table with historical stats; expose UI badges and tooltips.
- Augment validation with narrative conflict detection that flags when persona statements contradict prior behaviourally inferred traits.

### Feature 4.1 – Advanced Authentication Systems
- **Stories 30–32, 4.1.1A/B**: Implement WebAuthn server in Rust (using `webauthn-rs`), device lifecycle management UI, audit trails, and policy enforcement (e.g., admin-only features requiring hardware keys).
- Integrate with AD through secure LDAP or Azure AD once org decides identity provider.
- Introduce workload-aware session policies, e.g., shorter token lifetimes when high-risk data exports or bulk psychological report generation is initiated.

### Feature 5.1 – Multi-Source Data Collection Engine
- **Stories 37–40, 46**: Unified ingestion engine using Rust async tasks.
  - Primary search via local SearXNG proxy, fallback to Tavily & Perplexity (Feature 39) with circuit breakers (Feature 43).
  - Dedicated collectors for each required site list; favour official APIs, syndication feeds (RSS/Atom), and structured endpoints (e.g., Bloomberg Enterprise Access Point, Reuters News API) before resorting to Playwright/Chrome headless with robots.txt compliance.
  - Social media connectors using official APIs where possible (e.g., Reddit JSON, YouTube Data API, LinkedIn public profile export) and fallback scrapers with rate-limiting and consent-aware throttles.
  - Integrate transcription and caption ingestion for multimedia (YouTube, podcasts) with diarisation-ready text to support language tone analysis.
  - Expand collectors with translation pipelines for non-English sources using local NLLB or Marian models, preserving quote fidelity for psychological nuance.
  - Configure per-connector workload budgets so GPU-intensive summarisation batches are staggered to avoid analyst-facing slowdowns.

### Feature 5.2 – Intelligent Caching & Data Pipeline
- **Stories 41, 42, 5.2.1**: Introduce Kafka-like queue alternative (e.g., NATS JetStream Windows binary) for pipeline resilience, caching normalized responses, and warming caches on schedule. Pre-compute psychological feature vectors and store them alongside raw documents to accelerate dashboard load times.
- Add workload balancer that measures ingestion freshness vs. psychological drift, allowing the system to prioritise personas with fast-changing behavioural signals.

### Feature 5.3 – Resilience and Fallback Systems
- **Stories 42, 43**: Circuit breaker middleware (Rust `tower` layers), retry policies, degrade gracefully to cached data, alert via Windows notifications or Teams webhook.
- Maintain a restricted-mode ingestion profile that automatically downgrades collectors to RSS/API-only when legal or rate-limit thresholds near violation, protecting compliance without halting psychological monitoring.

## Chapter 5. Data Architecture & Schemas
- Provide conceptual ERD detailing relationships; highlight indices for high-volume tables (`SearchCache`, `ResearchData`). Extend schema with `PsychSignals`, `PersonaTimeline`, and `MediaTranscripts` tables to capture factor histories, event chronology, and derived linguistic features.
- Partition large tables by target ID and date; use full-text search indexes on narrative fields, plus vector indexes (via SQL Server semantic search) for rapid similarity across psychological notes.
- Logging strategy: `SystemLogs` with categories (auth, ingestion, analysis, admin actions).
- Backup rotation using SQL Server Agent jobs and PowerShell scripts to encrypted storage.
- Implement `PersonaGraph` linking `Profiles`, `ResearchData`, and `PsychAnalysis` records via graph edges to support cross-target influence mapping and narrative propagation detection.
- Store workload telemetry (GPU usage, ingestion latency) to inform adaptive scheduling policies defined in Chapters 4 and 5.

## Chapter 6. Psychological Intelligence Methodology
- **Framework Harmonisation**: Combine the mandated 8-factor radar model with complementary Big Five, DISC, and Dark Triad screening modules so analysts can toggle perspectives per mission scope. Maintain translation tables to keep scores comparable across frameworks.
- **Persona Signal Pipeline**: Normalise ingested content into structured timelines (events, quotes, media appearances) and behavioural categories (leadership, communication, risk appetite). Use entity-resolution against the `Profiles` and `ResearchData` tables to avoid duplicate personas.
- **Psycholinguistic Tooling**: Enrich summaries with sentiment, emotion, and tone analysis using lexicon-based tools (e.g., NRC, LIWC-style dictionaries) plus transformer classifiers for sarcasm, formality, and persuasion detection. Capture verbal tics from transcripts to feed into communication guides.
- **Cognitive Bias & Credibility Controls**: Auto-detect conflicting narratives by clustering embeddings and highlight inconsistencies or propaganda markers. Weight scores with the `SourceCredibility` index and expose analyst override workflows for transparent adjustments.
- **Communication & Influence Playbooks**: Generate guidance artefacts by fusing 8-factor outputs with scenario templates (negotiation, crisis response, investor outreach). Store reusable playbooks in `CommunicationGuides` with traceability back to source evidence.
- **Continuous Learning Loop**: Provide annotation tooling for analysts to validate or adjust factor scores, feeding a reinforcement dataset that can fine-tune local models and improve future automation while documenting rationale for auditability.
- **Restricted Collection Guardrails**: Embed compliance checks to ensure each data request honours platform-level restrictions, automatically recording consent state and robots.txt status for transparency and audit.
- **Resilience for Analyst Workflows**: Offer "psych snapshot" caching that keeps the latest analysed state instantly available even when ingestion throttles occur, preserving analyst productivity.

## Chapter 7. AI & Analysis Stack Recommendations
- Use **Ollama** to host local LLMs: Llama 3 8B (general), Mixtral 8x7B (reasoning), Phi-3-mini (fast summaries).
- For embeddings and similarity: `sentence-transformers` (all-MiniLM-L12-v2) via ONNX.
- GPU acceleration via CUDA toolkit; manage VRAM with quantized models (GGUF for Ollama).
- Summarisation workflow: Source ingestion → Deduplication → Entity extraction (spaCy) → LLM summariser → 8-factor score generator (rule-based + ML model) with guardrails for hallucination detection and evidence citation.
- Optional RAG pipeline with vector store (Qdrant Windows build or Redis Search module). Incorporate specialised classifiers (e.g., MBTI predictors, persuasion intensity detectors) to enrich psychological feature vectors.
- Add local speech-to-text (e.g., Whisper.cpp GPU build) and facial micro-expression analysis (OpenSeeFace) modules to widen behavioural signal coverage where lawful.
- Maintain model registry with evaluation benchmarks (accuracy, hallucination rate, latency) so upgrades tangibly improve psychological insight quality.

## Chapter 8. Security & Compliance Blueprint
- Enforce HTTPS via **Caddy Edge** (primary) or IIS reverse proxy in fallback mode feeding Kestrel (Rust API); manage certificates with Windows ACME Simple (WACS) and reuse across both gateways.
- Multi-tier auth: password policy, JWT rotation, API keys hashed in DB, WebAuthn for privileged actions.
- Implement audit logging, rate limiting, IP allow/block lists, request content sanitisation.
- Plan GDPR-ready data handling: consent tracking, right-to-erasure workflows, pseudonymisation of stored targets.
- Add continuous compliance scanner that validates each ingestion connector remains within approved regions, data sharing agreements, and workload thresholds.

## Chapter 9. Deployment & Operations
- Adopt **blue-green deployment** using two IIS sites (e.g., `SocintAI-Blue`, `SocintAI-Green`) pointing to separate service directories and front them with **Caddy Edge** as the default TLS terminator.
- Provide a hybrid edge automation script set so the platform can pivot between "Caddy-fronted" and "IIS-fronted" modes; the script must expose a command that the admin portal’s single-button switch (Feature 1.5) can call safely.
- Use PowerShell scripts to:
  - Pull latest Git revision, compile Rust binaries (`cargo build --release`), build Next.js production bundles (`pnpm build`), run migrations, and switch IIS bindings.
  - Monitor Windows Event Logs, integrate with Performance Monitor counters.
- CI/CD option: GitHub Actions building artifacts, pushing to Windows host via WinRM.
- Introduce workload-aware deployment policy: queue heavy GPU reprocessing tasks post-cutover to keep blue/green swaps fast and low-risk.
- Maintain runbooks for emergency ingestion throttling and psychological model rollback if a regression degrades insight accuracy.

## Chapter 10. Testing Strategy
- Unit tests: Rust `cargo test`, Next.js `vitest`/`jest` for hooks and components.
- Integration tests: Postman/Newman suites, Playwright E2E for UI flows.
- Load testing: k6 scripts focusing on search aggregation and dashboard queries.
- Security testing: OWASP ZAP baseline, dependency scanning (cargo-audit, npm audit).
- Psychological validation testing: curated benchmark personas with known behavioural traits to verify model outputs remain within acceptable variance.

## Chapter 11. Documentation & Deliverables
- Artefacts to produce each sprint:
  - ER diagrams (draw.io/diagrams.net) exported to `/docs/erd/`.
  - API specification (OpenAPI/AsyncAPI) stored in `/docs/api/`.
  - UI wireframes (Figma exports) placed in `/docs/ui/`.
  - Runbooks for deployment, incident response, credential rotation.
- Maintain knowledge base within repo using MkDocs or Docusaurus for publication.

## Chapter 12. Additional Recommendations
- Consider Windows Subsystem for Linux for developer convenience while keeping prod native.
- Introduce feature flags (Rust `launchdarkly-server-sdk` or open-source `unleash`) to control rollout.
- Implement privacy compliance module: configurable redaction, data retention scheduler.
- Provide analytics instrumentation (PostHog self-hosted) for user behaviour insights.
- Evaluate optional knowledge graph service (Neo4j Desktop or RDF triplestore) to model relationships between targets, organisations, and events for richer psychological context while keeping SQL Server authoritative for transactions.
- Establish governance board for scraping ethics, review robots.txt compliance logs.

## Chapter 13. Suggested Timeline & Milestones
1. **Month 0–1**: Environment setup, Next.js skeleton, Rust API bootstrap, SQL Server schema draft, install IIS + Caddy Edge baseline with shared certificate automation.
2. **Month 2–3**: Authentication MVP (Feature 1.2), input forms (Feature 1.1), caching layer (Feature 1.4A), initial data ingestion (SearXNG primary), prototype Feature 1.5 toggle workflow.
3. **Month 4–5**: Visual dashboard (Feature 2.1), autosave, validation, initial AI summarisation pipeline.
4. **Month 6–7**: Advanced data validation (Feature 3.1), multi-source collectors, circuit breakers, Redis multi-layer cache (Feature 45).
5. **Month 8–9**: WebAuthn integration, device management, AD planning, expanded social media connectors (Feature 5.1.2B, 46).
6. **Month 10+**: Enterprise hardening, compliance audits, disaster recovery drills, performance tuning.

## Chapter 14. Success Metrics
- Time-to-insight < 2 minutes for standard persona request.
- Dashboard interaction latency < 200 ms for cached results, < 1 s for fresh computations.
- ≥ 99.5 % ingestion success rate with automatic failover.
- Zero critical security findings in quarterly penetration tests.

## Chapter 15. Next Steps Checklist
- [ ] Approve architecture & technology selections.
- [ ] Finalise data governance policy for listed sources (Bloomberg, Reuters, WSJ, etc.).
- [ ] Confirm identity provider strategy for AD/WebAuthn integration.
- [ ] Begin drafting ERD and migration scripts in `/docs/erd/`.
- [ ] Prototype SearXNG proxy configuration with failover endpoints.
- [ ] Implement Caddy Edge + IIS hybrid automation scripts and wire admin single-button toggle (Feature 1.5).
- [ ] Evaluate Ollama model combinations on RTX 4060 for throughput.

