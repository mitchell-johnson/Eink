import { afterEach, expect, it, vi } from "vitest";
import { generateImage } from "../src/generation";

afterEach(() => vi.restoreAllMocks());

it("validates the production Request options before mocking provider output", async () => {
  const png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
  vi.spyOn(globalThis,"fetch").mockImplementationOnce(async (url,options) => {
    // Preserve workerd's actual request validation at the mocked network boundary.
    const request=new Request(url,options);
    expect(request.redirect).toBe("manual");
    return Response.json({status:"completed",output:[{type:"image_generation_call",status:"completed",result:png}]});
  });
  await expect(generateImage("A flower","fake-key")).resolves.toBeInstanceOf(Uint8Array);
  expect(fetch).toHaveBeenCalledTimes(1);
});

it("rejects a provider redirect without following it or forwarding credentials", async () => {
  const log=vi.spyOn(console,"error").mockImplementation(()=>{});
  vi.spyOn(globalThis,"fetch").mockImplementationOnce(async input => {
    const request=new Request(input);
    expect(request.redirect).toBe("manual");
    return new Response(null,{status:307,headers:{Location:"https://untrusted.example/secret", "x-request-id":"req_test123"}});
  });
  await expect(generateImage("A flower","fake-key")).rejects.toMatchObject({code:"provider_redirect"});
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(JSON.parse(log.mock.calls[0][0])).toMatchObject({stage:"request",responseStatus:307,requestId:"req_test123"});
  expect(JSON.stringify(log.mock.calls)).not.toContain("untrusted.example");
});

it("records only allowlisted diagnostic fields when an exception contains secrets", async () => {
  const log=vi.spyOn(console,"error").mockImplementation(()=>{});
  const error=new Error("fake-credential and confidential-prompt must not appear in logs");
  error.name="fake-credential";
  vi.spyOn(globalThis,"fetch").mockRejectedValueOnce(error);
  await expect(generateImage("confidential-prompt","fake-credential")).rejects.toMatchObject({code:"generation_connection_lost"});
  const record=JSON.parse(log.mock.calls[0][0]);
  expect(record).toMatchObject({event:"image_generation_failed",stage:"request",errorName:"UnknownError"});
  expect(Object.keys(record).sort()).toEqual(["code","elapsedMs","errorName","event","stage"]);
  expect(JSON.stringify(log.mock.calls)).not.toContain("fake-credential");
  expect(JSON.stringify(log.mock.calls)).not.toContain("confidential-prompt");
});
