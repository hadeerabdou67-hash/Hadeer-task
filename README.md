# Verified Skills + Assessment Engine

Implementation for `feature/person-3-assessments`.

## Scope
- Skill taxonomy, categories, candidate claims and evidence.
- Published assessments, sections and questions.
- Candidate attempts, answer capture and server-side scoring.
- Verification lifecycle, badge identifiers, history and retake limits.
- Candidate-scoped RLS; answer keys are stored in the non-exposed `private` schema.

## Database
Migration: `supabase/migrations/20261104150000_verified_skills_assessment.sql`

Apply with:
```bash
supabase link --project-ref lcuhfpmpsgdysjhvdpcf
supabase db push
```

The migrations create the requested entities, indexes, RLS policies, grants, scoring RPC, security hardening and isolated demo fixtures. They seed `demo-candidate-001` as a demo profile with a claimed SQL Fundamentals skill, not as an Auth user. The migrations have been applied to the linked project.

## Edge Function
Function: `verified-skills`

Deployment status: **ACTIVE** on the linked Supabase project (JWT verification enabled). To redeploy from a local checkout:
```bash
supabase functions deploy verified-skills
```

All routes require a valid Supabase Auth access token:

| Method | Route (relative to function) | Purpose |
|---|---|---|
| GET | `/api/v1/skills` | List active skills |
| POST | `/api/v1/candidate/skills` | Claim a skill (`skill_id`) |
| DELETE | `/api/v1/candidate/skills/:id` | Remove own claim |
| POST | `/api/v1/candidate/skills/evidence` | Attach evidence |
| GET | `/api/v1/assessments` | List published assessments; optional `skill_id` |
| GET | `/api/v1/assessments/:id` | Assessment with sections/questions, never answer keys |
| POST | `/api/v1/assessments/:id/start` | Start attempt (`candidate_skill_id`; optional `Idempotency-Key`) |
| POST | `/api/v1/attempts/:id/answers` | Save answer (`question_id`, `answer`) |
| POST | `/api/v1/attempts/:id/submit` | Submit and score on Postgres |
| GET | `/api/v1/candidate/assessment-history` | Own assessment history |
| GET | `/api/v1/candidate/verified-skills` | Own verified skills and badges |

URL pattern:
`https://lcuhfpmpsgdysjhvdpcf.supabase.co/functions/v1/verified-skills/api/v1/skills`

## Security
- All routes require Supabase Auth; caller-supplied candidate IDs are not trusted.
- Candidate identity is resolved from `auth.uid()`.
- RLS scopes candidate-owned rows to the authenticated user.
- Clients can read question prompts/options but cannot read `private.assessment_answer_keys`.
- Scoring runs in a private-schema Postgres function and writes result/verification atomically.
- Clients cannot write assessment results or verification rows.
- Attempt count, expiry, retake cooldown and answer completeness are checked.

## Demo fixtures
- Candidate external reference: `demo-candidate-001`
- Categories: Technical Skills and Professional Skills
- Skills: SQL Fundamentals, API Design and Communication
- Published SQL Fundamentals demo assessment with a private answer key.

The demo candidate is isolated fixture data. For an end-to-end API test, sign in as a real Auth user; the profile is provisioned on first request.

## Integration notes
1. The repository contained only a minimal README when inspected, so this is a self-contained Supabase backend module, not wired into an assumed frontend/framework.
2. The Supabase function URL includes the function prefix. To expose exact external `/api/v1/*` paths, add a gateway rewrite or mount the handlers in the host application's server.
3. New projects may require explicit Data API exposure of the `public` schema. RLS and SQL grants are separate controls.
4. Configure a restrictive `CORS_ORIGIN` before production.
5. Demo assessment content must be replaced with reviewed production questions.

## Verification status
- [x] Applied database migrations to the linked project.
- [x] Confirmed all 12 requested tables exist and RLS is enabled.
- [x] Confirmed seed data: 2 categories, 3 skills, 1 published assessment, 1 question and demo candidate/skill.
- [x] Confirmed authenticated users cannot read answer keys or directly execute private scoring/profile routines; guarded public RPCs remain available.
- [x] Deployed Edge Function; status ACTIVE with JWT verification enabled.
- [x] Ran Supabase Security and Performance Advisors.
- [ ] Run authenticated end-to-end claim/start/answer/submit tests with a real test account.

Advisor notes: the private answer-key table intentionally has RLS enabled with no client policies. The two public SECURITY DEFINER RPCs are narrow authenticated wrappers; their internal private routines are not executable by authenticated clients. Performance advisor currently reports unused indexes on this new, low-traffic schema; reassess after representative query traffic.
