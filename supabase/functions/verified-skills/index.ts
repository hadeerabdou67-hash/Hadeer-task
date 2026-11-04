import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "access-control-allow-origin": Deno.env.get("CORS_ORIGIN") ?? "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, idempotency-key",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "content-type": "application/json; charset=utf-8",
};

type JsonObject = Record<string, unknown>;
type DbError = { code?: string; message?: string };

const isRecord = (value: unknown): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function fail(message: string, status = 400, code?: string): Response {
  return response({ error: message, ...(code ? { code } : {}) }, status);
}

function requiredString(value: unknown, field: string, max = 500): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    throw new Error(`Invalid ${field}`);
  }
  return value.trim();
}

function requiredUuid(value: unknown, field: string): string {
  const result = requiredString(value, field, 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)) {
    throw new Error(`Invalid ${field}`);
  }
  return result;
}

async function readBody(req: Request): Promise<JsonObject> {
  let value: unknown;
  try {
    value = await req.json();
  } catch {
    throw new SyntaxError("Invalid JSON body");
  }
  if (!isRecord(value)) throw new Error("Request body must be a JSON object");
  return value;
}

function createUserClient(req: Request): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const authorization = req.headers.get("authorization");

  if (!url || !key) throw new Error("Supabase environment is not configured");
  if (!authorization?.startsWith("Bearer ")) throw new Error("Authentication required");

  return createClient(url, key, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function authenticate(client: SupabaseClient): Promise<void> {
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new Error("Invalid or expired session");
}

async function getCandidateId(client: SupabaseClient): Promise<string> {
  const { data, error } = await client.rpc("ensure_candidate_profile");
  if (error || typeof data !== "string") {
    console.error("candidate profile provisioning failed", error);
    throw new Error("Could not resolve candidate profile");
  }
  return data;
}

function databaseError(error: DbError): Response {
  const code = error.code ?? "";
  const message = error.message ?? "Request could not be completed";

  if (code === "42501") return fail("You are not allowed to perform this action", 403);
  if (code === "P0002") return fail(message, 404);
  if (code === "23505") return fail(message, 409);
  if (code === "P0001") return fail(message, 409);
  if (code === "22023" || code === "23514") return fail(message, 400);
  if (code === "55000") return fail("Assessment is not configured correctly", 500, "ASSESSMENT_CONFIGURATION_ERROR");

  console.error("database operation failed", error);
  return fail("Internal server error", 500);
}

async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  let client: SupabaseClient;
  try {
    client = createUserClient(req);
    await authenticate(client);
  } catch (error) {
    return fail(error instanceof Error ? error.message : "Unauthorized", 401);
  }

  const url = new URL(req.url);
  const path = url.pathname
    .replace(/^\/functions\/v1\/verified-skills/, "")
    .replace(/\/$/, "") || "/";

  try {
    const candidateId = await getCandidateId(client);

    if (req.method === "GET" && path === "/api/v1/skills") {
      const categoryId = url.searchParams.get("category_id");
      let query = client.from("skills")
        .select("id,name,slug,description,level,category:skill_categories(id,name,slug)")
        .eq("is_active", true)
        .order("name");

      if (categoryId) query = query.eq("category_id", categoryId);
      const { data, error } = await query;
      if (error) return databaseError(error);
      return response({ data });
    }

    if (req.method === "POST" && path === "/api/v1/candidate/skills") {
      const input = await readBody(req);
      const skillId = requiredUuid(input.skill_id, "skill_id");
      const { data, error } = await client.rpc("claim_candidate_skill", {
        p_skill_id: skillId,
      });
      if (error) return databaseError(error);
      return response({ data }, 201);
    }

    const deleteSkill = path.match(/^\/api\/v1\/candidate\/skills\/([0-9a-f-]{36})$/i);
    if (req.method === "DELETE" && deleteSkill) {
      const { data, error } = await client.rpc("remove_candidate_skill", {
        p_candidate_skill_id: deleteSkill[1],
      });

      if (error) return databaseError(error);
      return response({ data });
    }

    if (req.method === "POST" && path === "/api/v1/candidate/skills/evidence") {
      const input = await readBody(req);
      const candidateSkillId = requiredUuid(input.candidate_skill_id, "candidate_skill_id");
      const evidenceType = requiredString(input.evidence_type, "evidence_type", 30);
      const allowedTypes = ["url", "document", "certificate", "portfolio", "note"];

      if (!allowedTypes.includes(evidenceType)) return fail("Unsupported evidence_type");
      const title = requiredString(input.title, "title", 200);

      if (input.uri !== undefined && input.uri !== null &&
          (typeof input.uri !== "string" || input.uri.length > 2048)) {
        return fail("Invalid uri");
      }
      if (input.description !== undefined && input.description !== null &&
          (typeof input.description !== "string" || input.description.length > 4000)) {
        return fail("Invalid description");
      }

      const { data, error } = await client.from("skill_evidence").insert({
        candidate_skill_id: candidateSkillId,
        evidence_type: evidenceType,
        title,
        uri: typeof input.uri === "string" ? input.uri : null,
        description: typeof input.description === "string" ? input.description : null,
        metadata: isRecord(input.metadata) ? input.metadata : {},
      }).select("id,candidate_skill_id,evidence_type,title,uri,description,submitted_at").single();

      if (error) return databaseError(error);
      return response({ data }, 201);
    }

    if (req.method === "GET" && path === "/api/v1/assessments") {
      const skillId = url.searchParams.get("skill_id");
      let query = client.from("assessments")
        .select("id,skill_id,title,description,passing_score,duration_minutes,max_attempts,retake_cooldown_hours,version")
        .eq("is_published", true)
        .order("created_at", { ascending: false });

      if (skillId) query = query.eq("skill_id", skillId);
      const { data, error } = await query;
      if (error) return databaseError(error);
      return response({ data });
    }

    const assessmentDetail = path.match(/^\/api\/v1\/assessments\/([0-9a-f-]{36})$/i);
    if (req.method === "GET" && assessmentDetail) {
      const { data, error } = await client.from("assessments")
        .select("id,skill_id,title,description,passing_score,duration_minutes,sections:assessment_sections(id,title,description,sort_order,questions:assessment_questions(id,question_type,prompt,options,points,sort_order))")
        .eq("id", assessmentDetail[1])
        .eq("is_published", true)
        .order("sort_order", { referencedTable: "assessment_sections" })
        .maybeSingle();

      if (error) return databaseError(error);
      if (!data) return fail("Assessment not found", 404);
      return response({ data });
    }

    const startAssessment = path.match(/^\/api\/v1\/assessments\/([0-9a-f-]{36})\/start$/i);
    if (req.method === "POST" && startAssessment) {
      const input = await readBody(req);
      const candidateSkillId = requiredUuid(input.candidate_skill_id, "candidate_skill_id");
      const headerKey = req.headers.get("idempotency-key");
      const bodyKey = typeof input.idempotency_key === "string" ? input.idempotency_key : null;

      if (headerKey && bodyKey && headerKey !== bodyKey) {
        return fail("Idempotency-Key header and body value differ");
      }
      const idempotencyKey = headerKey ?? bodyKey;
      if (idempotencyKey !== null &&
          (idempotencyKey.trim().length === 0 || idempotencyKey.length > 128)) {
        return fail("Invalid idempotency key");
      }

      const { data, error } = await client.rpc("start_assessment_attempt", {
        p_assessment_id: startAssessment[1],
        p_candidate_skill_id: candidateSkillId,
        p_idempotency_key: idempotencyKey,
      });
      if (error) return databaseError(error);

      const reused = isRecord(data) && data.reused === true;
      return response({ data, reused }, reused ? 200 : 201);
    }

    const answerAttempt = path.match(/^\/api\/v1\/attempts\/([0-9a-f-]{36})\/answers$/i);
    if (req.method === "POST" && answerAttempt) {
      const input = await readBody(req);
      const questionId = requiredUuid(input.question_id, "question_id");
      if (!("answer" in input)) return fail("answer is required");

      const { data, error } = await client.rpc("save_assessment_answer", {
        p_attempt_id: answerAttempt[1],
        p_question_id: questionId,
        p_answer: input.answer,
      });
      if (error) return databaseError(error);

      if (isRecord(data) && data.code === "ATTEMPT_EXPIRED") {
        return fail("Attempt expired", 410, "ATTEMPT_EXPIRED");
      }
      return response({ data });
    }

    const submitAttempt = path.match(/^\/api\/v1\/attempts\/([0-9a-f-]{36})\/submit$/i);
    if (req.method === "POST" && submitAttempt) {
      const { data, error } = await client.rpc("submit_assessment_attempt", {
        p_attempt_id: submitAttempt[1],
      });
      if (error) return databaseError(error);

      if (isRecord(data) && data.code === "ATTEMPT_EXPIRED") {
        return fail("Attempt expired", 410, "ATTEMPT_EXPIRED");
      }
      return response({ data });
    }

    if (req.method === "GET" && path === "/api/v1/candidate/assessment-history") {
      const { data, error } = await client.from("assessment_attempts")
        .select("id,assessment_id,attempt_number,status,started_at,submitted_at,result:assessment_results(score,passed,scored_at),assessment:assessments(title,skill_id)")
        .eq("candidate_id", candidateId)
        .order("started_at", { ascending: false });

      if (error) return databaseError(error);
      return response({ data });
    }

    if (req.method === "GET" && path === "/api/v1/candidate/verified-skills") {
      const { data, error } = await client.from("skill_verifications")
        .select("id,status,verified_at,expires_at,badge_code,candidate_skill:candidate_skills!inner(skill:skills(id,name,slug,category:skill_categories(name)))")
        .eq("candidate_skill.candidate_id", candidateId)
        .eq("status", "verified")
        .order("verified_at", { ascending: false });

      if (error) return databaseError(error);
      return response({ data });
    }

    return fail("Route not found", 404);
  } catch (error) {
    if (error instanceof SyntaxError) return fail("Invalid JSON body", 400);
    if (error instanceof Error &&
        (error.message.startsWith("Invalid ") || error.message === "Request body must be a JSON object")) {
      return fail(error.message, 400);
    }
    console.error("verified-skills request failed", error);
    return fail("Internal server error", 500);
  }
}

Deno.serve(handle);
