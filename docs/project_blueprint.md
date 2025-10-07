# SOCINT Platform Transformation Master Plan

## Chapter 1. Vision & Guiding Principles
- **Objective**: Transform the initial n8n-style workflow into a secure, scalable, and interactive SOCINT (Social Intelligence) platform capable of collecting, analysing, and presenting psychological insights on public personas.
- **Constraints & Environment**:
  - Windows 11 Pro host with 64 GB RAM and RTX 4060 (8 GB).
  - Strictly no Docker, VM, or n8n in production; native Windows services with IIS (or Windows-compatible alternatives) and HTTPS certificates.
  - Entire stack deployable locally with zero-downtime (blue/green) release capabilities.
- **Non-Functional Goals**: Maintainable architecture, compliance-ready (privacy-by-design), modular security, and actionable intelligence output.

## Chapter 2. High-Level Architecture Overview
| Layer | Primary Technologies | Responsibilities |
| --- | --- | --- |
| Presentation | **Next.js 14 + TypeScript**, Tailwind CSS, Headless UI | Responsive UI, target input, dashboards, reporting.
| Application/API | **Rust** (Axum or Actix Web), Tokio, Serde | REST/GraphQL APIs, orchestration, auth, business logic.
| Data Processing & AI | Rust services + Python micro-workers (optional) leveraging **Ollama** (Llama 3, Mistral), ONNX Runtime, NVIDIA GPU acceleration | Summarisation, credibility scoring, psychological profiling.
| Data Storage | **SQL Server 2022**, Redis 7 (Windows native build), local file/object storage | Core schema, cache, binary artefacts, audit logs.
| Data Collection | SearXNG proxy, Wikipedia, Tavily, Perplexity APIs, ethical web scrapers (Playwright), RSS/Atom feeders, public/open APIs, social media connectors | Aggregated multi-source intelligence gathering with caching & resilience via compliant data channels.
| Operations | IIS/ASP.NET Core Module for reverse proxy, Windows Services, PowerShell automation, GitHub Actions (optional) | Deployment, monitoring, blue-green rollout, certificate renewal.

## Chapter 3. Roadmap by Epics & Phases
1. **Epic 1 – Platform Foundation Infrastructure**
   - Feature 1.1, 1.2, 1.3, 1.4 plus supporting stories (1.1.1, 1.1.2, 1.2.1, 1.2.2A/B, 1.3.1, 1.4.1A/B).
   - Deliverables: Next.js foundation, authentication flows, SQL Server schema, Redis cache, RBAC middleware, caching abstraction.
2. **Epic 2 – Core Analysis Platform**
   - Feature 2.1 (2.1.1A/B), Feature 20 (visual dashboard), 44 (8-factor component), 19 (auto-save), 18 (validation).
   - Deliverables: Input flows, live validation, autosave, radar charts, analysis dashboards.
3. **Epic 3 – Advanced Intelligence Features**
   - Features 27–29, 45, data validation, credibility scoring, multi-layer caching enhancements.
4. **Epic 4 – Enterprise Integration Platform**
   - Features 30–32, 4.1.1A/B, hardware key auth, AD/SAML, device management, compliance logging.
5. **Epic 5 – Data Collection & Intelligence Platform**
   - Features 36–43, 37, 38, 39, 40, 41, 42, 46; resilient data ingestion pipelines, circuit breakers, social media integrations.

Each epic decomposes into sprints combining backend, frontend, and ops tasks. Milestones align with feature parity and security readiness.

## Chapter 4. Detailed Feature Breakdown
### Feature 1.1 – Web Frontend Foundation
- Implement Next.js 14 with App Router, TypeScript, and pnpm workspace.
- Establish shared UI library (`frontend/components/ui`), Tailwind theme, dark/light modes.
- Provide layouts for Target Input Interface (Story 1.1.1) and Analysis Results Dashboard (Story 1.1.2).
- Integrate progress indicators, skeleton loaders, and WebSocket/Server Sent Events hooks for long-running jobs.

### Feature 1.2 – Multi-Tier Authentication System
- **Stories 1.2.1, 1.2.2, 1.2.2A/B**: NextAuth (credentials provider) replaced with custom Rust auth service.
- Implement JWT issuance (Features 12 & 21) with refresh/blacklist tables, plus API key management.
- Plan hardware security key integration (Feature 30, 31) via WebAuthn during Epic 4.
- Provide Active Directory connector blueprint using LDAP or Azure AD Graph when ready.

### Feature 1.3 – Database Foundation
- **Stories 9, 15, 16, 33, 34**: Design ERD with tables: `Users`, `Roles`, `Permissions`, `Sessions`, `Profiles`, `PsychAnalysis`, `CommunicationGuides`, `SearchCache`, `ResearchData`, `SourceCredibility`, `SystemLogs`.
- Use Rust `sqlx` or `tiberius` for SQL Server connectivity. Include migration tooling (Barrel or custom `sqlx migrate`).
- Ensure row-level security concept via stored procedures or filtered views.

### Feature 1.4 – Caching Infrastructure
- **Stories 10, 1.4.1A, 1.4.1B, 45**: Install Redis on Windows as a service. Implement layered caching (in-memory via DashMap, Redis, and persisted search cache table).
- Provide TTL strategy: hot results 5 min, curated intelligence 24 h, metadata 12 h.
- Add monitoring hooks (Prometheus exporters for Windows, optionally WMI counters).

### Feature 2.1 – Visual Profile Dashboard
- **Stories 2.1.1A/B, 20, 44**: Build 8-factor radar chart with d3.js or Recharts. Provide accessible list view with color-coded confidence scores.
- Create drill-down modals for factor details, source references, and recommended communication guide entries.
- Implement autosave (Story 19) via IndexedDB fallback and Redis session store.

### Feature 3.1 – Multi-Source Data Validation
- **Stories 27–29**: Cross-verify data by comparing textual embeddings (e.g., Sentence Transformers on GPU) and scoring sources using credibility algorithm.
- Maintain `SourceCredibility` table with historical stats; expose UI badges and tooltips.

### Feature 4.1 – Advanced Authentication Systems
- **Stories 30–32, 4.1.1A/B**: Implement WebAuthn server in Rust (using `webauthn-rs`), device lifecycle management UI, audit trails, and policy enforcement (e.g., admin-only features requiring hardware keys).
- Integrate with AD through secure LDAP or Azure AD once org decides identity provider.

### Feature 5.1 – Multi-Source Data Collection Engine
- **Stories 37–40, 46**: Unified ingestion engine using Rust async tasks.
  - Primary search via local SearXNG proxy, fallback to Tavily & Perplexity (Feature 39) with circuit breakers (Feature 43).
  - Dedicated collectors for each required site list; use RSS when available; Playwright/Chrome headless for dynamic pages within ethical scraping guidelines and robots.txt compliance.
  - Social media connectors using official APIs where possible (e.g., Reddit JSON, YouTube Data API) and fallback scrapers with rate-limiting.

### Feature 5.2 – Intelligent Caching & Data Pipeline
- **Stories 41, 42, 5.2.1**: Introduce Kafka-like queue alternative (e.g., NATS JetStream Windows binary) for pipeline resilience, caching normalized responses, and warming caches on schedule.

### Feature 5.3 – Resilience and Fallback Systems
- **Stories 42, 43**: Circuit breaker middleware (Rust `tower` layers), retry policies, degrade gracefully to cached data, alert via Windows notifications or Teams webhook.

## Chapter 5. Data Architecture & Schemas
- Provide conceptual ERD detailing relationships; highlight indices for high-volume tables (`SearchCache`, `ResearchData`).
- Partition large tables by target ID and date; use full-text search indexes on narrative fields.
- Logging strategy: `SystemLogs` with categories (auth, ingestion, analysis, admin actions).
- Backup rotation using SQL Server Agent jobs and PowerShell scripts to encrypted storage.

## Chapter 6. AI & Analysis Stack Recommendations
- Use **Ollama** to host local LLMs: Llama 3 8B (general), Mixtral 8x7B (reasoning), Phi-3-mini (fast summaries).
- For embeddings and similarity: `sentence-transformers` (all-MiniLM-L12-v2) via ONNX.
- GPU acceleration via CUDA toolkit; manage VRAM with quantized models (GGUF for Ollama).
- Summarisation workflow: Source ingestion → Deduplication → Entity extraction (spaCy) → LLM summariser → 8-factor score generator (rule-based + ML model).
- Optional RAG pipeline with vector store (Qdrant Windows build or Redis Search module).

## Chapter 7. Security & Compliance Blueprint
- Enforce HTTPS via IIS Reverse Proxy + Kestrel (Rust API) behind it; manage certificates with Windows ACME Simple (WACS).
- Multi-tier auth: password policy, JWT rotation, API keys hashed in DB, WebAuthn for privileged actions.
- Implement audit logging, rate limiting, IP allow/block lists, request content sanitisation.
- Plan GDPR-ready data handling: consent tracking, right-to-erasure workflows, pseudonymisation of stored targets.

## Chapter 8. Deployment & Operations
- Adopt **blue-green deployment** using two IIS sites (e.g., `SocintAI-Blue`, `SocintAI-Green`) pointing to separate service directories.
- Use PowerShell scripts to:
  - Pull latest Git revision, compile Rust binaries (`cargo build --release`), build Next.js production bundles (`pnpm build`), run migrations, and switch IIS bindings.
  - Monitor Windows Event Logs, integrate with Performance Monitor counters.
- CI/CD option: GitHub Actions building artifacts, pushing to Windows host via WinRM.

## Chapter 9. Testing Strategy
- Unit tests: Rust `cargo test`, Next.js `vitest`/`jest` for hooks and components.
- Integration tests: Postman/Newman suites, Playwright E2E for UI flows.
- Load testing: k6 scripts focusing on search aggregation and dashboard queries.
- Security testing: OWASP ZAP baseline, dependency scanning (cargo-audit, npm audit).

## Chapter 10. Documentation & Deliverables
- Artefacts to produce each sprint:
  - ER diagrams (draw.io/diagrams.net) exported to `/docs/erd/`.
  - API specification (OpenAPI/AsyncAPI) stored in `/docs/api/`.
  - UI wireframes (Figma exports) placed in `/docs/ui/`.
  - Runbooks for deployment, incident response, credential rotation.
- Maintain knowledge base within repo using MkDocs or Docusaurus for publication.

## Chapter 11. Additional Recommendations
- Consider Windows Subsystem for Linux for developer convenience while keeping prod native.
- Introduce feature flags (Rust `launchdarkly-server-sdk` or open-source `unleash`) to control rollout.
- Implement privacy compliance module: configurable redaction, data retention scheduler.
- Provide analytics instrumentation (PostHog self-hosted) for user behaviour insights.
- Establish governance board for scraping ethics, review robots.txt compliance logs.

## Chapter 12. Suggested Timeline & Milestones
1. **Month 0–1**: Environment setup, Next.js skeleton, Rust API bootstrap, SQL Server schema draft.
2. **Month 2–3**: Authentication MVP (Feature 1.2), input forms (Feature 1.1), caching layer (Feature 1.4A), initial data ingestion (SearXNG primary).
3. **Month 4–5**: Visual dashboard (Feature 2.1), autosave, validation, initial AI summarisation pipeline.
4. **Month 6–7**: Advanced data validation (Feature 3.1), multi-source collectors, circuit breakers, Redis multi-layer cache (Feature 45).
5. **Month 8–9**: WebAuthn integration, device management, AD planning, expanded social media connectors (Feature 5.1.2B, 46).
6. **Month 10+**: Enterprise hardening, compliance audits, disaster recovery drills, performance tuning.

## Chapter 13. Success Metrics
- Time-to-insight < 2 minutes for standard persona request.
- Dashboard interaction latency < 200 ms for cached results, < 1 s for fresh computations.
- ≥ 99.5 % ingestion success rate with automatic failover.
- Zero critical security findings in quarterly penetration tests.

## Chapter 14. Next Steps Checklist
- [ ] Approve architecture & technology selections.
- [ ] Finalise data governance policy for listed sources (Bloomberg, Reuters, WSJ, etc.).
- [ ] Confirm identity provider strategy for AD/WebAuthn integration.
- [ ] Begin drafting ERD and migration scripts in `/docs/erd/`.
- [ ] Prototype SearXNG proxy configuration with failover endpoints.
- [ ] Evaluate Ollama model combinations on RTX 4060 for throughput.

