import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.57.0";

const cors = {
  "access-control-allow-origin": Deno.env.get("CORS_ORIGIN") ?? "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, idempotency-key",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "content-type": "application/json; charset=utf-8",
};

type Json = Record<string, unknown>;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: cors });
const fail = (message: string, status = 400) => json({ error: message }, status);
const isRecord = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

function requiredString(value: unknown, field: string, max = 500): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    throw new Error(`Invalid ${field}`);
  }
  return value.trim();
}

function getClient(req: Request): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!url || !key) throw new Error("Supabase environment is not configured");
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw new Error("Authentication required");
  return createClient(url, key, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function currentUser(client: SupabaseClient) {
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new Error("Invalid or expired session");
  return data.user;
}

async function candidateId(client: SupabaseClient): Promise<string> {
  const { data, error } = await client.rpc("ensure_candidate_profile");
  if (error || typeof data !== "string") throw new Error(error?.message ?? "Could not resolve candidate profile");
  return data;
}

async function body(req: Request): Promise<Json> {
  const value: unknown = await req.json();
  if (!isRecord(value)) throw new Error("Request body must be a JSON object");
  return value;
}

async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  let client: SupabaseClient;
  try {
    client = getClient(req);
    await currentUser(client);
  } catch (error) {
    return fail(error instanceof Error ? error.message : "Unauthorized", 401);
  }

  const url = new URL(req.url);
  // Supabase Edge Function deployment path:
  // /functions/v1/verified-skills/api/v1/...
  const path = url.pathname.replace(/^\/functions\/v1\/verified-skills/, "").replace(/\/$/, "") || "/";
  try {
    const candidate = await candidateId(client);

    if (req.method === "GET" && path === "/api/v1/skills") {
      const category = url.searchParams.get("category");
      let query = client.from("skills")
        .select("id,name,slug,description,level,category:skill_categories(id,name,slug)")
        .eq("is_active", true).order("name");
      if (category) query = query.eq("category_id", category);
      const { data, error } = await query;
      if (error) throw error;
      return json({ data });
    }

    if (req.method === "POST" && path === "/api/v1/candidate/skills") {
      const input = await body(req);
      const skillId = requiredString(input.skill_id, "skill_id", 80);
      const { data, error } = await client.from("candidate_skills")
        .insert({ candidate_id: candidate, skill_id: skillId, status: "claimed" })
        .select("id,skill_id,status,claimed_at").single();
      if (error?.code === "23505") return fail("Skill already claimed", 409);
      if (error) throw error;
      return json({ data }, 201);
    }

    const deleteSkill = path.match(/^\/api\/v1\/candidate\/skills\/([0-9a-f-]{36})$/i);
    if (req.method === "DELETE" && deleteSkill) {
      const { data, error } = await client.from("candidate_skills")
        .delete().eq("id", deleteSkill[1]).eq("candidate_id", candidate).select("id").maybeSingle();
      if (error) throw error;
      if (!data) return fail("Candidate skill not found", 404);
      return json({ deleted: true, id: data.id });
    }

    if (req.method === "POST" && path === "/api/v1/candidate/skills/evidence") {
      const input = await body(req);
      const candidateSkillId = requiredString(input.candidate_skill_id, "candidate_skill_id", 80);
      const type = requiredString(input.evidence_type, "evidence_type", 30);
      if (!["url", "document", "certificate", "portfolio", "note"].includes(type)) return fail("Unsupported evidence_type");
      const title = requiredString(input.title, "title", 200);
      const { data, error } = await client.from("skill_evidence").insert({
        candidate_skill_id: candidateSkillId, evidence_type: type, title,
        uri: typeof input.uri === "string" ? input.uri.slice(0, 2048) : null,
        description: typeof input.description === "string" ? input.description.slice(0, 4000) : null,
        metadata: isRecord(input.metadata) ? input.metadata : {},
      }).select("id,candidate_skill_id,evidence_type,title,uri,description,submitted_at").single();
      if (error) throw error;
      return json({ data }, 201);
    }

    if (req.method === "GET" && path === "/api/v1/assessments") {
      const skillId = url.searchParams.get("skill_id");
      let query = client.from("assessments")
        .select("id,skill_id,title,description,passing_score,duration_minutes,max_attempts,retake_cooldown_hours,version")
        .eq("is_published", true).order("created_at", { ascending: false });
      if (skillId) query = query.eq("skill_id", skillId);
      const { data, error } = await query;
      if (error) throw error;
      return json({ data });
    }

    const assessmentDetail = path.match(/^\/api\/v1\/assessments\/([0-9a-f-]{36})$/i);
    if (req.method === "GET" && assessmentDetail) {
      const { data, error } = await client.from("assessments")
        .select("id,skill_id,title,description,passing_score,duration_minutes,sections:assessment_sections(id,title,description,sort_order,questions:assessment_questions(id,question_type,prompt,options,points,sort_order))")
        .eq("id", assessmentDetail[1]).eq("is_published", true)
        .order("sort_order", { referencedTable: "assessment_sections" })
        .maybeSingle();
      if (error) throw error;
      if (!data) return fail("Assessment not found", 404);
      return json({ data });
    }

    const startAssessment = path.match(/^\/api\/v1\/assessments\/([0-9a-f-]{36})\/start$/i);
    if (req.method === "POST" && startAssessment) {
      const input = await body(req);
      const candidateSkillId = requiredString(input.candidate_skill_id, "candidate_skill_id", 36);
      const headerKey = req.headers.get("idempotency-key");
      const bodyKey = typeof input.idempotency_key === "string" ? input.idempotency_key : null;
      if (headerKey && bodyKey && headerKey !== bodyKey) {
        return fail("Idempotency-Key header and body value differ", 400);
      }
      const idempotencyKey = headerKey ?? bodyKey;
      if (idempotencyKey && (idempotencyKey.trim().length === 0 || idempotencyKey.length > 128)) {
        return fail("Invalid idempotency key", 400);
      }
      const { data, error } = await client.rpc("start_assessment_attempt", {
        p_assessment_id: startAssessment[1],
        p_candidate_skill_id: candidateSkillId,
        p_idempotency_key: idempotencyKey,
      });
      if (error) {
        const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 :
          error.code === "P0001" || error.code === "23505" ? 409 : 400;
        return fail(error.message, status);
      }
      const reused = isRecord(data) && data.reused === true;
      return json({ data, reused }, reused ? 200 : 201);
    }

    const answerAttempt = path.match(/^\/api\/v1\/attempts\/([0-9a-f-]{36})\/answers$/i);
    if (req.method === "POST" && answerAttempt) {
      const input = await body(req);
      const questionId = requiredString(input.question_id, "question_id", 80);
      if (!("answer" in input)) return fail("answer is required");
      const { data: attempt, error: attemptError } = await client.from("assessment_attempts")
        .select("id,assessment_id,status,expires_at").eq("id", answerAttempt[1])
        .eq("candidate_id", candidate).single();
      if (attemptError || !attempt) return fail("Attempt not found", 404);
      if (attempt.status !== "in_progress" || new Date(attempt.expires_at) <= new Date()) return fail("Attempt is not active", 409);
      const { data: question, error: qErr } = await client.from("assessment_questions")
        .select("id,question_type,options,section:assessment_sections!inner(assessment_id)")
        .eq("id", questionId).eq("is_active", true).single();
      if (qErr || !question || question.section.assessment_id !== attempt.assessment_id) return fail("Question does not belong to this assessment", 400);
      const validAnswer = question.question_type === "multiple_choice"
        ? Array.isArray(input.answer) && input.answer.every((v) => typeof v === "string")
        : typeof input.answer === "string" || typeof input.answer === "boolean";
      if (!validAnswer) return fail("Answer format does not match question type");
      const { data, error } = await client.from("assessment_answers").upsert({
        attempt_id: attempt.id, question_id: questionId, answer: input.answer, answered_at: new Date().toISOString(),
      }, { onConflict: "attempt_id,question_id" }).select("id,attempt_id,question_id,answered_at").single();
      if (error) throw error;
      return json({ data });
    }

    const submitAttempt = path.match(/^\\/api\\/v1\\/attempts\\/([0-9a-f-]{36})\\/submit$/i);
    if (req.method === "POST" && submitAttempt) {
      const { data, error } = await client.rpc("submit_assessment_attempt", { p_attempt_id: submitAttempt[1] });
      if (error) {
        const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 :
          error.code === "23505" ? 409 : error.code === "22023" ? 400 : 500;
        return fail(status === 500 ? "Assessment scoring failed" : error.message, status);
      }
      if (isRecord(data) && data.code === "ATTEMPT_EXPIRED") {
        return fail("Attempt expired", 410, "ATTEMPT_EXPIRED");
      }
      return json({ data });
    }

    if (req.method === "GET" && path === "/api/v1/candidate/assessment-history") {
      const { data, error } = await client.from("assessment_attempts")
        .select("id,assessment_id,attempt_number,status,started_at,submitted_at,result:assessment_results(score,passed,scored_at),assessment:assessments(title,skill_id)")
        .eq("candidate_id", candidate).order("started_at", { ascending: false });
      if (error) throw error;
      return json({ data });
    }

    if (req.method === "GET" && path === "/api/v1/candidate/verified-skills") {
      const { data, error } = await client.from("skill_verifications")
        .select("id,status,verified_at,expires_at,badge_code,candidate_skill:candidate_skills!inner(skill:skills(id,name,slug,category:skill_categories(name)))")
        .eq("candidate_skill.candidate_id", candidate).eq("status", "verified")
        .order("verified_at", { ascending: false });
      if (error) throw error;
      return json({ data });
    }

    return fail("Route not found", 404);
  } catch (error) {
    if (error instanceof SyntaxError) return fail("Invalid JSON body", 400);
    console.error("verified-skills request failed", error);
    return fail("Internal server error", 500);
  }
}

Deno.serve(handle);
