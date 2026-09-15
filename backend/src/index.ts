import { DurableObject } from "cloudflare:workers";
import { boundedText, generateImage, IMAGE_MODEL, PALETTE, ServiceError } from "./generation";

const RETENTION_MS = 24 * 60 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type JobStatus = "queued" | "running" | "succeeded" | "failed";
type PublicError = { code: string; message: string };
type PublicJob = { id: string; status: JobStatus; model: string; error?: PublicError };
type Job = PublicJob & { prompt?: string; promptHash: string; expiresAt: number };
const expired: PublicError = { code: "image_expired", message: "This image has expired. Create a new request to generate another image." };
const headers = {
  "Cache-Control": "private, no-store",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
};
const json = (body: unknown, status = 200, extra: Record<string,string> = {}) => Response.json(body, { status, headers: { ...headers, ...extra } });
const failure = (code: string, message: string, status: number) => json({ error: { code, message } }, status);
const publicJob = (job: Job): PublicJob => {
  const { id, status, model, error } = job;
  return Date.now() >= job.expiresAt ? { id, status: "failed", model, error: expired } : { id, status, model, ...(error ? { error } : {}) };
};

async function digest(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

async function authenticated(request: Request, expected: string | undefined): Promise<boolean> {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!expected || authorization.length > 4096 || !authorization.startsWith("Bearer ")) return false;
  const [providedHash, expectedHash] = await Promise.all([digest(authorization.slice(7)), digest(expected)]);
  return crypto.subtle.timingSafeEqual(providedHash, expectedHash);
}

/** One small coordination object for this private application's admission budget. */
export class Admission extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS admissions (id TEXT PRIMARY KEY, accepted_at INTEGER NOT NULL)");
  }
  async reserve(id: string): Promise<boolean> {
    return this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      sql.exec("DELETE FROM admissions WHERE accepted_at <= ?", Date.now() - 60_000);
      if (sql.exec("SELECT id FROM admissions WHERE id = ?", id).toArray().length) return true;
      const count = sql.exec<{ total: number }>("SELECT COUNT(*) AS total FROM admissions").one().total;
      if (count >= 3) return false;
      sql.exec("INSERT INTO admissions (id, accepted_at) VALUES (?, ?)", id, Date.now());
      return true;
    });
  }
}

/** One object per client UUID. Persisting running before fetch prevents paid replay. */
export class ImageJob extends DurableObject<Env> {
  async status(): Promise<PublicJob | null> {
    const job = await this.ctx.storage.get<Job>("job");
    return job ? publicJob(job) : null;
  }

  async create(id: string, prompt: string, promptHash: string): Promise<{ created: boolean; conflict: boolean; job: PublicJob }> {
    return this.ctx.storage.transaction(async tx => {
      const existing = await tx.get<Job>("job");
      if (existing) return { created: false, conflict: existing.promptHash !== promptHash, job: publicJob(existing) };
      const job: Job = { id, status: "queued", model: IMAGE_MODEL, prompt, promptHash, expiresAt: Date.now() + RETENTION_MS };
      await tx.put("job", job);
      await tx.setAlarm(Date.now() + 1000);
      return { created: true, conflict: false, job: publicJob(job) };
    });
  }

  async image(): Promise<Response> {
    const job = await this.ctx.storage.get<Job>("job");
    if (!job) return failure("job_not_found", "This request does not exist.", 404);
    if (Date.now() >= job.expiresAt) return failure(expired.code, expired.message, 410);
    if (job.status !== "succeeded") return failure("image_not_ready", "This request has no completed image.", 409);
    const stored = await this.env.IMAGES.get(`${job.id}.png`);
    if (!stored) return failure("image_unavailable", "The completed image is unavailable. This request will not be regenerated automatically.", 410);
    return new Response(stored.body, { headers: { ...headers, "Content-Type": "image/png", "Content-Length": String(stored.size) } });
  }

  private async finish(job: Job, status: "failed" | "succeeded", error?: PublicError): Promise<void> {
    const { prompt: _prompt, ...retained } = job;
    await this.ctx.storage.transaction(async tx => {
      await tx.put("job", { ...retained, status, ...(error ? { error } : {}) });
      await tx.setAlarm(job.expiresAt);
    });
    console.log(JSON.stringify({ event: "image_job_finished", id: job.id, status, code: error?.code }));
  }

  async alarm(): Promise<void> {
    const job = await this.ctx.storage.get<Job>("job");
    if (!job) return;
    if (Date.now() >= job.expiresAt) {
      try { await this.env.IMAGES.delete(`${job.id}.png`); }
      catch {
        await this.ctx.storage.setAlarm(Date.now() + 60_000);
        return;
      }
      const { prompt: _prompt, ...retained } = job;
      await this.ctx.storage.transaction(async tx => {
        await tx.put("job", { ...retained, status: "failed", error: expired });
        await tx.deleteAlarm();
      });
      return;
    }
    if (job.status === "running") {
      await this.finish(job, "failed", { code: "generation_interrupted", message: "Generation was interrupted and its provider outcome is unknown. It was not automatically retried." });
      return;
    }
    if (job.status !== "queued") {
      await this.ctx.storage.setAlarm(job.expiresAt);
      return;
    }
    // Atomically mark the only allowed paid attempt and arrange recovery if it crashes.
    await this.ctx.storage.transaction(async tx => {
      await tx.put("job", { ...job, status: "running" });
      await tx.setAlarm(Date.now() + 240_000);
    });
    try {
      if (!this.env.OPENAI_API_KEY) throw new ServiceError("not_configured", "Image generation is not configured yet.");
      const png = await generateImage(job.prompt!, this.env.OPENAI_API_KEY);
      await this.env.IMAGES.put(`${job.id}.png`, png, { httpMetadata: { contentType: "image/png", cacheControl: "private, no-store" } });
      await this.finish(job, "succeeded");
    } catch (error) {
      const detail = error instanceof ServiceError ? { code: error.code, message: error.message } : { code: "storage_failed", message: "The generated image could not be saved. It was not regenerated automatically." };
      await this.finish(job, "failed", detail);
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const path = new URL(request.url).pathname;
      if (request.method === "GET" && path === "/health") return json({ ok: true });
      if (!await authenticated(request, env.APP_ACCESS_TOKEN)) return failure("unauthorized", "A valid app access token is required.", 401);
      if (request.method === "GET" && path === "/v1/config") return json({ model: IMAGE_MODEL, width: 400, height: 300, palette: PALETTE, ready: Boolean(env.OPENAI_API_KEY) });
      const match = /^\/v1\/jobs\/([^/]+)(\/image)?$/.exec(path);
      if (!match) return failure("not_found", "This endpoint does not exist.", 404);
      if (!UUID.test(match[1])) return failure("invalid_id", "Use a UUID as the request ID.", 400);
      const id = match[1].toLowerCase();
      const stub = env.JOBS.getByName(id);
      if (request.method === "GET") {
        if (match[2]) return await stub.image();
        const job = await stub.status();
        return job ? json(job) : failure("job_not_found", "This request does not exist.", 404);
      }
      if (request.method !== "PUT" || match[2]) return failure("method_not_allowed", "Use GET to read or PUT to create a request.", 405);
      if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return failure("invalid_content_type", "Send an application/json body.", 415);
      let text: string;
      try { text = await boundedText(request.body, 16 * 1024); }
      catch (error) {
        if (error instanceof TypeError) return failure("invalid_json", "Send valid UTF-8 JSON.", 400);
        throw error;
      }
      let parsed: unknown;
      try { parsed = JSON.parse(text); } catch { return failure("invalid_json", "Send a valid JSON object containing prompt.", 400); }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || Object.keys(parsed).length !== 1 || !("prompt" in parsed) || typeof parsed.prompt !== "string" || !parsed.prompt.trim() || new TextEncoder().encode(parsed.prompt).length > 4096) return failure("invalid_prompt", "Provide only prompt, containing 1–4096 UTF-8 bytes of text.", 400);
      const hash = Array.from(new Uint8Array(await digest(parsed.prompt)), b => b.toString(16).padStart(2, "0")).join("");
      if (!await stub.status()) {
        if (!env.OPENAI_API_KEY) return failure("not_configured", "Image generation is not configured yet.", 503);
        if (!await env.ADMISSION.getByName("private-app").reserve(id)) return json({ error: { code: "rate_limited", message: "Please wait a minute before starting another image." } }, 429, { "Retry-After": "60" });
      }
      const result = await stub.create(id, parsed.prompt, hash);
      if (result.conflict) return failure("id_conflict", "This request ID already belongs to different content. Use a new UUID for a new request.", 409);
      return json(result.job, result.created ? 202 : 200);
    } catch (error) {
      if (error instanceof ServiceError) return failure(error.code, error.message, error.httpStatus);
      console.error(JSON.stringify({ event: "request_failed" }));
      return failure("service_unavailable", "The service is temporarily unavailable. Reuse the same request ID when reconnecting.", 503);
    }
  },
} satisfies ExportedHandler<Env>;
