import { env, exports } from "cloudflare:workers";
import { reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { generateImage, GENERATION_TIMEOUT_MS } from "../src/generation";

const ID = "91bf840c-09e7-484e-9b6e-4aba937fe001";
const request = (path: string, method = "GET", body?: unknown, token = "test-access-token") =>
  exports.default.fetch(new Request(`https://private.test${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  }));
const create = (id = ID, prompt = "A red flower") => request(`/v1/jobs/${id}`, "PUT", { prompt });

beforeEach(() => { vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Unexpected outbound request")); });
afterEach(async () => { vi.restoreAllMocks(); await reset(); });

describe("private API", () => {
  it("exposes only a minimal public health response", async () => {
    const response = await request("/health", "GET", undefined, "wrong");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });
  it("rejects wrong credentials on configuration, jobs, and images", async () => {
    for (const path of ["/v1/config", `/v1/jobs/${ID}`, `/v1/jobs/${ID}/image`]) {
      expect((await request(path, "GET", undefined, "wrong")).status).toBe(401);
    }
    expect((await request(`/v1/jobs/${ID}`, "PUT", {prompt:"hello"}, "wrong")).status).toBe(401);
  });
  it("reports the fixed image model and panel contract", async () => {
    expect(await (await request("/v1/config")).json()).toEqual({
      model:"gpt-image-2.5-sunburst", width:400, height:300,
      palette:["#000000", "#FFFFFF", "#FFFF00", "#FF0000"], ready:true,
    });
  });
  it("rejects invalid input before creating jobs", async () => {
    for (const body of [{prompt:""}, {prompt:"x".repeat(4097)}, {prompt:"hello",model:"other"}, []]) {
      expect((await request(`/v1/jobs/${ID}`, "PUT", body)).status).toBe(400);
    }
    expect((await request(`/v1/jobs/${ID}`, "PUT", {prompt:"x".repeat(17000)})).status).toBe(413);
    expect((await create("invalid-id")).status).toBe(400);
    expect((await request(`/v1/jobs/${ID}`)).status).toBe(404);
  });
  it("makes concurrent creates idempotent and rejects a changed prompt", async () => {
    const responses = await Promise.all([create(),create(),create()]);
    expect(responses.map(r=>r.status).sort()).toEqual([200,200,202]);
    for (const response of responses) expect(await response.json()).toMatchObject({id:ID,status:"queued"});
    expect((await create(ID,"Different content")).status).toBe(409);
    expect((await request(`/v1/jobs/${ID}`)).status).toBe(200);
    expect((await request(`/v1/jobs/${ID}/image`)).status).toBe(409);
  });
  it("limits new job admission to three per minute without limiting replays or polling", async () => {
    for (let n=1;n<=3;n++) expect((await create(ID.slice(0,-1)+n)).status).toBe(202);
    expect((await create(ID.slice(0,-1)+4)).status).toBe(429);
    expect((await create(ID.slice(0,-1)+1)).status).toBe(200);
    expect((await request(`/v1/jobs/${ID.slice(0,-1)+1}`)).status).toBe(200);
  });
  it("never starts generation through GET of an unknown job", async () => {
    expect((await request(`/v1/jobs/${ID}`)).status).toBe(404);
    expect((await request(`/v1/jobs/${ID}/image`)).status).toBe(404);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("reports unconfigured generation and rejects creates before quota admission", async () => {
    const missingKey={...env,OPENAI_API_KEY:""};
    const config=await worker.fetch(new Request("https://private.test/v1/config",{headers:{Authorization:"Bearer test-access-token"}}),missingKey);
    expect(await config.json()).toMatchObject({ready:false});
    const response=await worker.fetch(new Request(`https://private.test/v1/jobs/${ID}`,{method:"PUT",headers:{Authorization:"Bearer test-access-token","Content-Type":"application/json"},body:JSON.stringify({prompt:"flower"})}),missingKey);
    expect(response.status).toBe(503);
    expect(await env.JOBS.getByName(ID).status()).toBe(null);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("rejects malformed UTF-8 as input rather than a service outage", async () => {
    const response=await exports.default.fetch(new Request(`https://private.test/v1/jobs/${ID}`,{method:"PUT",headers:{Authorization:"Bearer test-access-token","Content-Type":"application/json"},body:new Uint8Array([0xff,0xfe])}));
    expect(response.status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe("durable generation", () => {
  it("stores a private PNG and does not generate again on retries or later alarms", async () => {
    // A valid 1x1 PNG is sufficient to exercise opaque image storage/transport.
    const png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
    vi.mocked(fetch).mockImplementationOnce(async (inputRequest) => {
      const nativeRequest = new Request(inputRequest);
      expect(nativeRequest.url).toBe("https://api.openai.com/v1/responses");
      const input=await nativeRequest.json<Record<string,unknown>>();
      expect(input.model).toBe("gpt-5.6-luna");
      expect(input.instructions).toContain("#FFFF00");
      expect(input.tools).toEqual([{type:"image_generation",model:"gpt-image-2.5-sunburst",action:"generate",size:"1024x768",quality:"medium",output_format:"png",background:"opaque"}]);
      expect(input.max_tool_calls).toBe(1);
      expect(input.store).toBe(false);
      return Response.json({status:"completed",output:[{type:"image_generation_call",status:"completed",result:png}]});
    });
    expect((await create()).status).toBe(202);
    const stub=env.JOBS.getByName(ID);
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const status=await (await request(`/v1/jobs/${ID}`)).json();
    expect(status).toMatchObject({status:"succeeded",model:"gpt-image-2.5-sunburst"});
    const image=await request(`/v1/jobs/${ID}/image`);
    expect(image.headers.get("Content-Type")).toBe("image/png");
    expect(image.headers.get("Cache-Control")).toContain("no-store");
    expect(new Uint8Array(await image.arrayBuffer()).slice(0,8)).toEqual(new Uint8Array([137,80,78,71,13,10,26,10]));
    expect((await create()).status).toBe(200);
    await runDurableObjectAlarm(stub);
    expect(await (await request(`/v1/jobs/${ID}`)).json()).toMatchObject({status:"succeeded"});
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("does not retry OpenAI errors and keeps provider detail private", async () => {
    vi.mocked(fetch).mockImplementationOnce(async () => Response.json({error:{code:"insufficient_quota",message:"private account detail"}}, {status:429}));
    await create();
    await runDurableObjectAlarm(env.JOBS.getByName(ID));
    const job=await (await request(`/v1/jobs/${ID}`)).json();
    expect(job).toMatchObject({status:"failed",error:{code:"provider_quota"}});
    expect(JSON.stringify(job)).not.toContain("private account detail");
    await create();
    await runDurableObjectAlarm(env.JOBS.getByName(ID));
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("fails an interrupted running job without starting another paid call", async () => {
    await create();
    const stub=env.JOBS.getByName(ID);
    await runInDurableObject(stub, async (_instance,state)=>{
      const job=await state.storage.get<Record<string,unknown>>("job");
      await state.storage.put("job",{...job,status:"running"});
    });
    await runDurableObjectAlarm(stub);
    expect(await (await request(`/v1/jobs/${ID}`)).json()).toMatchObject({status:"failed",error:{code:"generation_interrupted"}});
    expect((await create()).status).toBe(200);
  });
  it("expires stored images while preserving the idempotency tombstone", async () => {
    await create();
    const stub=env.JOBS.getByName(ID);
    await env.IMAGES.put(`${ID}.png`,new Uint8Array([1,2,3]));
    await runInDurableObject(stub, async (_instance,state)=>{
      const job=await state.storage.get<Record<string,unknown>>("job");
      await state.storage.put("job",{...job,status:"succeeded",expiresAt:Date.now()-1});
    });
    await runDurableObjectAlarm(stub);
    expect(await env.IMAGES.get(`${ID}.png`)).toBe(null);
    expect(await (await create()).json()).toMatchObject({status:"failed",error:{code:"image_expired"}});
    expect((await request(`/v1/jobs/${ID}/image`)).status).toBe(410);
    expect((await create(ID,"new prompt")).status).toBe(409);
  });
  it("returns a stable failed job when the provider emits no image", async () => {
    vi.mocked(fetch).mockImplementationOnce(async () => Response.json({status:"completed",output:[]}));
    await create();
    await runDurableObjectAlarm(env.JOBS.getByName(ID));
    expect(await (await request(`/v1/jobs/${ID}`)).json()).toMatchObject({status:"failed",error:{code:"image_missing"}});
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("aborts a stalled provider request at the fixed deadline without retrying", async () => {
    vi.useFakeTimers();
    vi.mocked(fetch).mockImplementationOnce(async (input) => new Promise((_resolve,reject)=>{
      const request=new Request(input);
      request.signal.addEventListener("abort",()=>reject(new Error("aborted")),{once:true});
    }));
    try {
      const outcome=generateImage("A flower","test-key").catch(error=>error);
      await vi.advanceTimersByTimeAsync(GENERATION_TIMEOUT_MS);
      expect(await outcome).toMatchObject({code:"generation_timeout"});
      expect(fetch).toHaveBeenCalledTimes(1);
    } finally { vi.useRealTimers(); }
  });
});
