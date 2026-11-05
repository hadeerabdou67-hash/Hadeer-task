# Live HTTP E2E — Verified Skills

This collection runs the authenticated HTTP workflow against the linked Supabase project. It does not contain credentials or service-role secrets.

## One-time setup
1. In Supabase Dashboard → Authentication → Users, create a **dedicated test user** and confirm its email.
2. In Supabase → Project Settings → API, copy the **publishable/anon key** (never the service_role/secret key).
3. Import `postman/Verified-Skills-Live-E2E.postman_collection.json` and `postman/Verified-Skills-Test.postman_environment.json` into Postman.
4. Select the imported environment and set `anonKey`, `email`, and `password`. Keep these values local; do not commit the populated environment.
5. Open the collection and choose **Run collection**. Run requests in listed order, with no delay required.

## What it tests
- Password sign-in and access-token extraction.
- Authenticated skills listing and candidate skill claim.
- Published assessment listing and public question retrieval.
- Confirms answer keys are not returned by the assessment detail API.
- Starts an attempt with an idempotency key.
- Saves the demo fixture answer, submits, and checks server-side scoring.
- Confirms the verified badge and candidate assessment history are returned.

The seeded demo assessment is SQL Fundamentals — Demo Assessment. Its first question's fixture answer is `b`; this is intentionally a fixture-only value. If the seed assessment changes, update the `answerValue` environment variable based on the approved fixture answer.

## Expected outcome
All requests return 2xx. The demo answer should produce a passing result and the badge request should contain the SQL Fundamentals verification. If the assessment has more than one active question, this simple collection is not sufficient to answer all of them; use the database transactional E2E test as the complete multi-question workflow proof or extend the collection with one answer request per question.

## Security
- Never use a production candidate account for this test.
- Never paste a service-role key into Postman.
- Do not commit an environment file after filling credentials.
- The collection intentionally creates a real test candidate, skill claim, and assessment attempt in the linked project. Remove the dedicated test user and its test data after collecting the evidence, following your project's retention policy.
