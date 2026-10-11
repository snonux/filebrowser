import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createTransport, type AuthSession } from "../transport";
import { StatusError } from "@/utils/errors";

const transport = createTransport("/base");
let session: AuthSession;
let pendingLogin: boolean;
const renew = vi.fn(async () => {});
const logout = vi.fn();

beforeEach(() => {
  session = { jwt: "token", generation: 1 };
  pendingLogin = false;
  vi.clearAllMocks();
  vi.stubGlobal("fetch", vi.fn());
  transport.configureAuth({
    captureSession: () => ({ ...session }),
    isCurrentSession: (captured) =>
      !pendingLogin &&
      captured.generation === session.generation &&
      captured.jwt === session.jwt,
    renew,
    logout,
  });
});
afterEach(() => vi.unstubAllGlobals());

describe("API transport without presentation dependencies", () => {
  it("sends the captured token and request options", async () => {
    const response = new Response("{}");
    vi.mocked(fetch).mockResolvedValue(response);
    expect(
      await transport.fetchURL("/api/resources/", {
        method: "PATCH",
        headers: { "X-Test": "yes" },
      })
    ).toBe(response);
    expect(fetch).toHaveBeenCalledWith("/base/api/resources/", {
      method: "PATCH",
      headers: { "X-Auth": "token", "X-Test": "yes" },
    });
  });

  it("awaits current-session renewal before returning the response", async () => {
    let finish!: () => void;
    renew.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve;
        })
    );
    vi.mocked(fetch).mockResolvedValue(
      new Response("{}", { headers: { "X-Renew-Token": "true" } })
    );
    const completed = vi.fn();
    const request = transport.fetchURL("/resources", {}).then(completed);
    await vi.waitFor(() => expect(renew).toHaveBeenCalledWith("token"));
    expect(completed).not.toHaveBeenCalled();
    finish();
    await request;
    expect(completed).toHaveBeenCalledTimes(1);
  });

  it("propagates renewal failure", async () => {
    renew.mockRejectedValueOnce(new StatusError("expired", 401));
    vi.mocked(fetch).mockResolvedValue(
      new Response("{}", { headers: { "X-Renew-Token": "true" } })
    );
    await expect(transport.fetchURL("/resources", {})).rejects.toMatchObject({
      status: 401,
    });
  });

  it("calls the session callback for a current unauthorized response", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response("denied", { status: 401 }));
    await expect(transport.fetchURL("/resources", {})).rejects.toMatchObject({
      status: 401,
      message: "denied",
    });
    expect(logout).toHaveBeenCalledTimes(1);
  });

  it.each(["replacement", "pending login"])(
    "ignores stale response effects during %s",
    async (reason) => {
      let finish!: (response: Response) => void;
      vi.mocked(fetch).mockReturnValueOnce(
        new Promise<Response>((resolve) => {
          finish = resolve;
        })
      );
      const request = transport.fetchURL("/resources", {});
      if (reason === "replacement") session = { ...session, generation: 2 };
      else pendingLogin = true;
      finish(
        new Response("denied", {
          status: 401,
          headers: { "X-Renew-Token": "true" },
        })
      );
      await expect(request).rejects.toMatchObject({ status: 401 });
      expect(renew).not.toHaveBeenCalled();
      expect(logout).not.toHaveBeenCalled();
    }
  );

  it("skips session effects on public requests", async () => {
    vi.mocked(fetch).mockResolvedValue(
      new Response("denied", {
        status: 401,
        headers: { "X-Renew-Token": "true" },
      })
    );
    await expect(
      transport.fetchURL("/public", {}, false)
    ).rejects.toMatchObject({ status: 401 });
    expect(renew).not.toHaveBeenCalled();
    expect(logout).not.toHaveBeenCalled();
  });

  it.each([false, true])(
    "normalizes network failure with cancellation=%s",
    async (canceled) => {
      vi.mocked(fetch).mockRejectedValue(
        canceled
          ? new DOMException("canceled", "AbortError")
          : new TypeError("network")
      );
      await expect(transport.fetchURL("/resources", {})).rejects.toMatchObject({
        status: 0,
        is_canceled: canceled || undefined,
      });
    }
  );

  it("retains the JSON status contract", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(new Response('{"ok":true}'));
    expect(await transport.fetchJSON("/resources")).toEqual({ ok: true });
    vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 204 }));
    await expect(transport.fetchJSON("/resources")).rejects.toMatchObject({
      status: 204,
    });
  });
});
