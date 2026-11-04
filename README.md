# Verified Skills + Assessment Engine

Backend module implemented for the `feature/person-3-assessments` branch.

## Scope

- Skill taxonomy and categories.
- Candidate skill claims and evidence tracking.
- Published assessments, sections and questions.
- Attempt lifecycle, answer capture, server-side scoring and results.
- Verified badges, candidate verification status and assessment history.
- Retake limits, cooldowns, idempotent attempt creation and expiry handling.

## Repository layout

```text
supabase/
  config.toml
  functions/verified-skills/
    deno.json
    index.ts
  migrations/
    20261104150000_verified_skills_assessment.sql
    20261104160000_assessment_security_hardening.sql
    20261104170000_restrict_privileged_rpc_execution.sql
    20261104180000_seed_demo_candidate_skill.sql
    20261104190000_verified_skills_engine_hardening.sql
    20261104190100_enforce_server_owned_assessment_workflow.sql
    20261104200000_verified_skills_integrity_concurrency.sql
    20261104200200_finalize_scoring_and_profile_permissions.sql
    20261104210000_index_attempts_candidate_skill_owner.sql
  tests/
    verified_skills_security.sql
    verified_skills_smoke_test.sql
```

Migration versions are unique and ordered. The live project has the schema changes applied. For a fresh linked project, run:

```bash
supabase link --project-ref lcuhfpmpsgdysjhvdpcf
supabase db push
```

## Database model

The module creates 12 tables in `public` and one protected table in `private`:

- `skill_categories`, `skills`
- `candidate_profiles`, `candidate_skills`, `skill_evidence`
- `assessments`, `assessment_sections`, `assessment_questions`
- `assessment_attempts`, `assessment_answers`, `assessment_results`
- `skill_verifications`
- `private.assessment_answer_keys` (never exposed to clients)

All public tables have RLS enabled. The private schema is not exposed to authenticated clients.

## Edge Function

Function: `verified-skills`

Deployment: **ACTIVE, version 6**, with JWT verification enabled.

Base URL:

`https://lcuhfpmpsgdysjhvdpcf.supabase.co/functions/v1/verified-skills`

All routes require a valid Supabase Auth access token in the Authorization bearer header.

| Method | Route (relative to function base URL) | Purpose |
|---|---|---|
| GET | `/api/v1/skills` | List active skills; optional `category_id` |
| POST | `/api/v1/candidate/skills` | Claim a skill (`skill_id`) |
| DELETE | `/api/v1/candidate/skills/:id` | Remove an unused own claim |
| POST | `/api/v1/candidate/skills/evidence` | Attach evidence to an own claim |
| GET | `/api/v1/assessments` | List published assessments; optional `skill_id` |
| GET | `/api/v1/assessments/:id` | Assessment with sections/questions, never answer keys |
| POST | `/api/v1/assessments/:id/start` | Start an attempt (`candidate_skill_id`; optional `Idempotency-Key`) |
| POST | `/api/v1/attempts/:id/answers` | Save/update an answer (`question_id`, `answer`) |
| POST | `/api/v1/attempts/:id/submit` | Submit and score on Postgres |
| GET | `/api/v1/candidate/assessment-history` | Own assessment history |
| GET | `/api/v1/candidate/verified-skills` | Own verified skills and badges |

Example:
`https://lcuhfpmpsgdysjhvdpcf.supabase.co/functions/v1/verified-skills/api/v1/skills`

## Workflow and security

1. A signed-in candidate is resolved from `auth.uid()`; the client never supplies a trusted candidate ID.
2. Candidate claims are created only as `claimed` through `claim_candidate_skill`.
3. Attempts are created only through the transactional `start_assessment_attempt` RPC. It verifies the candidate's matching claim, serializes attempt creation, enforces maximum attempts and cooldowns, and supports idempotency keys.
4. Answers are written through `save_assessment_answer`. It locks the attempt, verifies ownership and expiry, checks that the question belongs to the assessment, and validates answer type and option IDs.
5. Submission is scored inside Postgres. Results and verification records are written atomically.
6. Expired attempts are marked abandoned and the corresponding in-progress claim is marked expired.
7. Composite ownership constraints and validation triggers prevent cross-candidate or cross-assessment references.

Clients cannot directly insert or update attempts, answers, results, verification records, or candidate skill status. The answer-key table and internal workflow functions are not directly accessible to authenticated clients. Public RPC wrappers are narrow SECURITY DEFINER entry points; their internal functions independently validate `auth.uid()`.

## Demo fixtures

- Demo profile external reference: `demo-candidate-001` (not an Auth account).
- Categories: Technical Skills and Professional Skills.
- Skills: SQL Fundamentals, API Design and Communication.
- Published SQL Fundamentals demo assessment with a private answer key.
- The demo profile has a claimed SQL Fundamentals skill.

For a real end-to-end API run, sign in with a real Supabase Auth user. The candidate profile is provisioned on the first authenticated API request.

## Tests and verification

Run the read-only smoke test in the Supabase SQL Editor using a database-owner session:

`supabase/tests/verified_skills_smoke_test.sql`

Run the transactional security test (it rolls back its temporary fixture changes):

`supabase/tests/verified_skills_security.sql`

The security test was executed successfully against the linked project. It verifies RLS coverage, private answer-key isolation, least-privilege grants, guarded RPC permissions, demo fixtures and rejection of an attempt that pairs a candidate's claim with an assessment for a different skill.

Confirmed on the linked project:
- 12 public tables and the private answer-key table exist.
- All module tables have RLS enabled.
- Authenticated users cannot directly insert claims, attempts or answers.
- Authenticated users cannot directly modify candidate profiles, attempts, answers, results or verification lifecycle records.
- Private schema usage and direct execution of private workflow functions are revoked.
- Guarded public RPCs are available to authenticated users.
- The Edge Function is active at version 6 with JWT verification enabled.

Not yet completed: a full authenticated HTTP journey using a real test-user access token (claim → start → save answer → submit → verify badge). The demo candidate is intentionally not an Auth user, and no real user session was created for this test.

## Production integration notes

1. This repository contained only a minimal README at initial inspection, so the delivery is a self-contained Supabase backend module; it is not wired into an assumed frontend or framework.
2. Supabase Edge Function URLs include the `/functions/v1/verified-skills` prefix. If the host application requires bare `/api/v1/*` paths, configure a gateway rewrite or mount equivalent handlers in its application server.
3. Confirm that the `public` schema is exposed in the Supabase Data API settings.
4. Set `CORS_ORIGIN` to the actual frontend origin before production; the default wildcard is for development convenience.
5. Replace demo assessment content with reviewed production questions and answer keys before real candidate verification.
6. Security Advisor may flag the authenticated SECURITY DEFINER RPC wrappers for review. These are intentional, narrowly scoped entry points; the private implementation functions remain inaccessible and each operation validates the authenticated identity. Re-run the Advisor after deployment and review any new findings.
