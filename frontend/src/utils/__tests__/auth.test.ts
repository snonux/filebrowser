// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createPinia, setActivePinia } from "pinia";
import { useAuthStore } from "@/stores/auth";
import { login, logout, parseToken, renew, validateLogin } from "@/utils/auth";
import { fetchURL, setSafeTimeout } from "@/api/utils";
import router from "@/router";
import { configureApplicationApiAuth } from "@/utils/api-auth";

vi.mock("@/router", () => ({ default: { push: vi.fn() } }));
vi.mock("@/i18n", () => ({
  detectLocale: () => "en",
  setLocale: vi.fn(),
}));
const authConfig = vi.hoisted(() => ({
  authMethod: "json",
  baseURL: "",
  noAuth: false,
  logoutPage: "/login",
}));
vi.mock("@/utils/constants", () => authConfig);

function token(username: string, revision = 0, lifetimeSeconds = 3600) {
  const payload = {
    user: { id: username === "alice" ? 1 : 2, username, locale: "en" },
    exp: Math.floor(Date.now() / 1000) + lifetimeSeconds,
    revision,
  };
  return `${btoa("{}")}.${btoa(JSON.stringify(payload))}.signature`;
}

function holdResponse() {
  let release!: (response: Response) => void;
  const response = new Promise<Response>((resolve) => {
    release = resolve;
  });
  vi.mocked(fetch).mockReturnValueOnce(response);
  return release;
}

function expectSession(jwt: string, username?: string) {
  const store = useAuthStore();
  expect(store.jwt).toBe(jwt);
  expect(store.isLoggedIn).toBe(Boolean(username));
  expect(store.user?.username).toBe(username);
  expect(localStorage.getItem("jwt")).toBe(jwt);
  expect(document.cookie).toBe(jwt ? `auth=${jwt}` : "");
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-11T00:00:00Z"));
  vi.clearAllMocks();
  authConfig.authMethod = "json";
  authConfig.logoutPage = "/login";
  setActivePinia(createPinia());
  configureApplicationApiAuth();
  localStorage.clear();
  document.cookie = "auth=; Max-Age=0; Path=/";
  vi.stubGlobal("fetch", vi.fn());
});

describe("authentication expiry ownership", () => {
  it("cancels logout before another account logs in", () => {
    parseToken(token("alice", 0, 10));
    logout();
    const replacement = token("bob", 0, 100);
    parseToken(replacement);
    vi.advanceTimersByTime(10_000);
    expectSession(replacement, "bob");
    expect(router.push).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(90_000);
    expectSession("");
    expect(router.push).toHaveBeenCalledTimes(2);
  });

  it("cancels expiry when an account is replaced directly", () => {
    parseToken(token("alice", 0, 10));
    const replacement = token("bob", 0, 100);
    parseToken(replacement);
    vi.advanceTimersByTime(10_000);
    expectSession(replacement, "bob");
    expect(router.push).not.toHaveBeenCalled();
  });

  it("replaces the expiry deadline on renewal", async () => {
    const old = token("alice", 0, 10);
    parseToken(old);
    const replacement = token("alice", 1, 100);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(replacement));
    await renew(old);
    vi.advanceTimersByTime(10_000);
    expectSession(replacement, "alice");
    expect(router.push).not.toHaveBeenCalled();
    vi.advanceTimersByTime(90_000);
    expectSession("");
  });

  it.each(["status", "fetch", "body", "token"])(
    "keeps the original expiry after a replacement login fails at %s",
    async (failure) => {
      const old = token("alice", 0, 10);
      parseToken(old);
      vi.advanceTimersByTime(2_000);
      if (failure === "fetch") {
        vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));
      } else {
        const response =
          failure === "status"
            ? new Response("bad credentials", { status: 401 })
            : new Response("invalid JWT");
        if (failure === "body") {
          vi.spyOn(response, "text").mockRejectedValue(
            new Error("body failed")
          );
        }
        vi.mocked(fetch).mockResolvedValueOnce(response);
      }
      await expect(login("bob", "wrong", "")).rejects.toBeInstanceOf(Error);
      vi.advanceTimersByTime(7_000);
      expectSession(old, "alice");
      vi.advanceTimersByTime(1_000);
      expectSession("");
      expect(router.push).toHaveBeenCalledTimes(1);
    }
  );

  it("expires the active account while a replacement login is pending", async () => {
    parseToken(token("alice", 0, 10));
    const release = holdResponse();
    const pending = login("bob", "password", "");
    vi.advanceTimersByTime(10_000);
    release(new Response(token("bob")));
    await pending;
    expectSession("");
    expect(router.push).toHaveBeenCalledTimes(1);
  });

  it.each(["logout", "renewal", "account switch"])(
    "cancels a long expiry after its first chunk on %s",
    async (change) => {
      const day = 86_400_000;
      const old = token("alice", 0, (2 * day) / 1000);
      parseToken(old);
      vi.advanceTimersByTime(day);
      if (change === "logout") logout();
      const username = change === "renewal" ? "alice" : "bob";
      const replacement = token(username, 1, (3 * day) / 1000);
      if (change === "renewal") {
        vi.mocked(fetch).mockResolvedValueOnce(new Response(replacement));
        await renew(old);
      } else {
        parseToken(replacement);
      }
      vi.advanceTimersByTime(day);
      expectSession(replacement, username);
      expect(router.push).toHaveBeenCalledTimes(change === "logout" ? 1 : 0);
    }
  );

  it("cancels the old expiry when proxy auth disables the replacement timeout", () => {
    parseToken(token("alice", 0, 10));
    authConfig.authMethod = "proxy";
    authConfig.logoutPage = "/signed-out";
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const replacement = token("bob");
    parseToken(replacement);
    expect(vi.getTimerCount()).toBe(0);
    vi.advanceTimersByTime(10_000);
    expectSession(replacement, "bob");
    expect(router.push).not.toHaveBeenCalled();
    warning.mockRestore();
  });

  it("cancels expiry when the store is cleared directly", () => {
    parseToken(token("alice", 0, 10));
    useAuthStore().clearUser();
    expect(vi.getTimerCount()).toBe(0);
    vi.advanceTimersByTime(10_000);
    expect(useAuthStore().isLoggedIn).toBe(false);
    expect(router.push).not.toHaveBeenCalled();
  });

  it("ignores a queued callback after same-token session replacement", () => {
    const schedule = vi.spyOn(window, "setTimeout");
    const jwt = token("alice", 0, 10);
    parseToken(jwt);
    const queued = schedule.mock.calls[0][0] as () => void;
    logout();
    parseToken(jwt);
    queued();
    expectSession(jwt, "alice");
    expect(router.push).toHaveBeenCalledTimes(1);
    schedule.mockRestore();
  });
});

describe("safe timeout cancellation", () => {
  it("keeps an infinite delay in cancellable bounded chunks", () => {
    const callback = vi.fn();
    const timeout = setSafeTimeout(callback, Infinity);
    vi.advanceTimersByTime(86_400_000);
    expect(callback).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(1);
    timeout.cancel();
    expect(vi.getTimerCount()).toBe(0);
  });

  it.each([-1000, 0, NaN])("runs a delay of %s once immediately", (delay) => {
    const callback = vi.fn();
    setSafeTimeout(callback, delay);
    vi.advanceTimersByTime(0);
    expect(callback).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("runs once at the full long deadline", () => {
    const callback = vi.fn();
    const day = 86_400_000;
    setSafeTimeout(callback, 2 * day + 10);
    vi.advanceTimersByTime(2 * day + 9);
    expect(callback).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(callback).toHaveBeenCalledTimes(1);
  });

  it("cancels the current chunk and suppresses an already queued chunk", () => {
    const schedule = vi.spyOn(window, "setTimeout");
    const callback = vi.fn();
    const day = 86_400_000;
    const timeout = setSafeTimeout(callback, 2 * day + 10);
    vi.advanceTimersByTime(day);
    const queued = schedule.mock.calls[1][0] as () => void;
    timeout.cancel();
    timeout.cancel();
    queued();
    expect(vi.getTimerCount()).toBe(0);
    vi.advanceTimersByTime(2 * day);
    expect(callback).not.toHaveBeenCalled();
    schedule.mockRestore();
  });
});

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("authentication response ownership", () => {
  it("discards a renewal response after logout", async () => {
    const old = token("alice");
    parseToken(old);
    const release = holdResponse();
    const pending = renew(old);
    logout();
    release(new Response(token("alice", 1)));
    await pending;
    expectSession("");
    expect(router.push).toHaveBeenCalledTimes(1);
  });

  it("preserves a new login when an older renewal arrives", async () => {
    const old = token("alice");
    parseToken(old);
    const release = holdResponse();
    const pending = renew(old);
    logout();
    const replacement = token("bob");
    vi.mocked(fetch).mockResolvedValueOnce(new Response(replacement));
    await login("bob", "password", "");
    release(new Response(token("alice", 1)));
    await pending;
    expectSession(replacement, "bob");
  });

  it("keeps a new login valid when an earlier renewal finishes first", async () => {
    const old = token("alice");
    parseToken(old);
    const releaseRenewal = holdResponse();
    const pendingRenewal = renew(old);
    const releaseLogin = holdResponse();
    const pendingLogin = login("bob", "password", "");
    releaseRenewal(new Response(token("alice", 1)));
    await pendingRenewal;
    expectSession(old, "alice");
    const replacement = token("bob");
    releaseLogin(new Response(replacement));
    await pendingLogin;
    expectSession(replacement, "bob");
  });

  it("rejects renewal from a previous session even if login reused its token", async () => {
    const old = token("alice");
    parseToken(old);
    const release = holdResponse();
    const pending = renew(old);
    logout();
    parseToken(old);
    release(new Response(token("alice", 1)));
    await pending;
    expectSession(old, "alice");
  });

  it("preserves a pending login against a later renewal and then renews normally", async () => {
    const old = token("alice");
    parseToken(old);
    const releaseLogin = holdResponse();
    const pendingLogin = login("bob", "password", "");
    await renew(old);
    expect(fetch).toHaveBeenCalledTimes(1);
    expectSession(old, "alice");
    const replacement = token("bob");
    releaseLogin(new Response(replacement));
    await pendingLogin;
    expectSession(replacement, "bob");
    const renewed = token("bob", 1);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(renewed));
    await renew(replacement);
    expectSession(renewed, "bob");
  });

  it.each(["status", "fetch", "body", "token"])(
    "restores renewal after a login fails at %s",
    async (failure) => {
      const old = token("alice");
      parseToken(old);
      let rejectFetch!: (error: Error) => void;
      let releaseLogin!: (response: Response) => void;
      vi.mocked(fetch).mockReturnValueOnce(
        new Promise<Response>((resolve, reject) => {
          releaseLogin = resolve;
          rejectFetch = reject;
        })
      );
      const pendingLogin = login("bob", "password", "");
      const rejected = expect(pendingLogin).rejects.toBeInstanceOf(Error);
      await renew(old);
      expect(fetch).toHaveBeenCalledTimes(1);
      if (failure === "fetch") {
        rejectFetch(new Error("offline"));
      } else if (failure === "body") {
        const response = new Response();
        vi.spyOn(response, "text").mockRejectedValue(new Error("body failed"));
        releaseLogin(response);
      } else if (failure === "token") {
        releaseLogin(new Response("invalid JWT"));
      } else {
        releaseLogin(new Response("bad credentials", { status: 401 }));
      }
      await rejected;
      expectSession(old, "alice");
      const renewed = token("alice", 1);
      vi.mocked(fetch).mockResolvedValueOnce(new Response(renewed));
      await renew(old);
      expectSession(renewed, "alice");
    }
  );

  it("keeps the latest login pending when an older login fails", async () => {
    const old = token("alice");
    parseToken(old);
    const releaseFirst = holdResponse();
    const first = login("alice", "wrong", "");
    const releaseLatest = holdResponse();
    const latest = login("bob", "password", "");
    releaseFirst(new Response("bad credentials", { status: 401 }));
    await first;
    await renew(old);
    expect(fetch).toHaveBeenCalledTimes(2);
    const replacement = token("bob");
    releaseLatest(new Response(replacement));
    await latest;
    expectSession(replacement, "bob");
  });

  it("does not start stored-token validation during a pending login", async () => {
    localStorage.setItem("jwt", token("alice"));
    const releaseLogin = holdResponse();
    const pendingLogin = login("bob", "password", "");
    await validateLogin();
    expect(fetch).toHaveBeenCalledTimes(1);
    const replacement = token("bob");
    releaseLogin(new Response(replacement));
    await pendingLogin;
    expectSession(replacement, "bob");
  });

  it("discards startup validation that finishes before a pending login", async () => {
    const old = token("alice");
    localStorage.setItem("jwt", old);
    const releaseValidation = holdResponse();
    const validation = validateLogin();
    const releaseLogin = holdResponse();
    const pendingLogin = login("bob", "password", "");
    releaseValidation(new Response(token("alice", 1)));
    await validation;
    expect(useAuthStore().isLoggedIn).toBe(false);
    expect(localStorage.getItem("jwt")).toBe(old);
    expect(document.cookie).toBe("");
    const replacement = token("bob");
    releaseLogin(new Response(replacement));
    await pendingLogin;
    expectSession(replacement, "bob");
  });

  it("keeps the newer of two concurrent renewal results", async () => {
    const old = token("alice");
    parseToken(old);
    const release = holdResponse();
    const pending = renew(old);
    const current = token("alice", 2);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(current));
    await renew(old);
    release(new Response(token("alice", 1)));
    await pending;
    expectSession(current, "alice");
  });

  it("discards renewal after a switch while the response body is pending", async () => {
    const old = token("alice");
    parseToken(old);
    let release!: (body: string) => void;
    const body = new Promise<string>((resolve) => {
      release = resolve;
    });
    const response = new Response();
    const readBody = vi.spyOn(response, "text").mockReturnValue(body);
    vi.mocked(fetch).mockResolvedValueOnce(response);
    const pending = renew(old);
    await vi.waitFor(() => expect(readBody).toHaveBeenCalled());
    const replacement = token("bob");
    parseToken(replacement);
    release(token("alice", 1));
    await pending;
    expectSession(replacement, "bob");
  });

  it("validates the initial stored token and installs its renewal", async () => {
    const old = token("alice");
    localStorage.setItem("jwt", old);
    const current = token("alice", 1);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(current));
    await validateLogin();
    expect(fetch).toHaveBeenCalledWith("/api/renew", {
      method: "POST",
      headers: { "X-Auth": old },
    });
    expectSession(current, "alice");
  });

  it("discards an initial stored-token renewal after logout", async () => {
    localStorage.setItem("jwt", token("alice"));
    const release = holdResponse();
    const pending = validateLogin();
    logout();
    release(new Response(token("alice", 1)));
    await pending;
    expectSession("");
  });

  it("renews the current session normally", async () => {
    const old = token("alice");
    parseToken(old);
    const current = token("alice", 1);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(current));
    await renew(old);
    expectSession(current, "alice");
  });

  it("reports a current renewal failure without changing credentials", async () => {
    const old = token("alice");
    parseToken(old);
    vi.mocked(fetch).mockResolvedValueOnce(
      new Response("expired", { status: 401 })
    );
    await expect(renew(old)).rejects.toMatchObject({ status: 401 });
    expectSession(old, "alice");
  });

  it("discards a login response after logout", async () => {
    const release = holdResponse();
    const pending = login("alice", "password", "");
    logout();
    release(new Response(token("alice")));
    await pending;
    expectSession("");
  });

  it("lets the latest overlapping login attempt own the session", async () => {
    const releaseAlice = holdResponse();
    const aliceLogin = login("alice", "password", "");
    const releaseBob = holdResponse();
    const bobLogin = login("bob", "password", "");
    releaseAlice(new Response(token("alice")));
    await aliceLogin;
    expect(useAuthStore().isLoggedIn).toBe(false);
    expect(document.cookie).toBe("");
    expect(localStorage.getItem("jwt")).toBeNull();
    const replacement = token("bob");
    releaseBob(new Response(replacement));
    await bobLogin;
    expectSession(replacement, "bob");
  });
});

describe("API response ownership", () => {
  it.each(["401", "renewal"])(
    "ignores API %s side effects while a login is pending",
    async (kind) => {
      const old = token("alice");
      parseToken(old);
      const releaseLogin = holdResponse();
      const pendingLogin = login("bob", "password", "");
      const response =
        kind === "401"
          ? new Response("expired", { status: 401 })
          : new Response("{}", { headers: { "X-Renew-Token": "true" } });
      vi.mocked(fetch).mockResolvedValueOnce(response);
      const request = fetchURL("/api/resources/", {});
      if (kind === "401") {
        await expect(request).rejects.toMatchObject({ status: 401 });
      } else {
        expect(await request).toBe(response);
      }
      expect(fetch).toHaveBeenCalledTimes(2);
      expect(router.push).not.toHaveBeenCalled();
      expectSession(old, "alice");
      const replacement = token("bob");
      releaseLogin(new Response(replacement));
      await pendingLogin;
      expectSession(replacement, "bob");
    }
  );

  it.each(["401", "renewal"])(
    "keeps an API %s response stale after the pending login fails",
    async (kind) => {
      const old = token("alice");
      parseToken(old);
      const releaseLogin = holdResponse();
      const pendingLogin = login("bob", "wrong", "");
      const loginFailure = expect(pendingLogin).rejects.toMatchObject({
        status: 401,
      });
      const releaseRequest = holdResponse();
      const request = fetchURL("/api/resources/", {});
      const requestResult =
        kind === "401"
          ? expect(request).rejects.toMatchObject({ status: 401 })
          : request;
      releaseLogin(new Response("bad credentials", { status: 401 }));
      await loginFailure;
      const response =
        kind === "401"
          ? new Response("expired", { status: 401 })
          : new Response("{}", { headers: { "X-Renew-Token": "true" } });
      releaseRequest(response);
      await requestResult;
      expect(fetch).toHaveBeenCalledTimes(2);
      expect(router.push).not.toHaveBeenCalled();
      expectSession(old, "alice");
    }
  );
  it("checks ownership again after reading a delayed 401 body", async () => {
    parseToken(token("alice"));
    let release!: (body: string) => void;
    const body = new Promise<string>((resolve) => {
      release = resolve;
    });
    const response = new Response("", { status: 401 });
    const readBody = vi.spyOn(response, "text").mockReturnValue(body);
    vi.mocked(fetch).mockResolvedValueOnce(response);
    const pending = fetchURL("/api/resources/", {});
    const failure = expect(pending).rejects.toMatchObject({ status: 401 });
    await vi.waitFor(() => expect(readBody).toHaveBeenCalled());
    const replacement = token("bob");
    parseToken(replacement);
    release("expired");
    await failure;
    expectSession(replacement, "bob");
    expect(router.push).not.toHaveBeenCalled();
  });

  it("does not log out the replacement account on an old request's 401", async () => {
    parseToken(token("alice"));
    const release = holdResponse();
    const pending = fetchURL("/api/resources/", {});
    const failure = expect(pending).rejects.toMatchObject({ status: 401 });
    const replacement = token("bob");
    parseToken(replacement);
    release(new Response("expired", { status: 401 }));
    await failure;
    expectSession(replacement, "bob");
    expect(router.push).not.toHaveBeenCalled();
  });

  it("logs out on a current request's 401", async () => {
    parseToken(token("alice"));
    vi.mocked(fetch).mockResolvedValueOnce(
      new Response("expired", { status: 401 })
    );
    await expect(fetchURL("/api/resources/", {})).rejects.toMatchObject({
      status: 401,
    });
    expectSession("");
    expect(router.push).toHaveBeenCalledTimes(1);
  });

  it("ignores an old response's renewal header after account replacement", async () => {
    parseToken(token("alice"));
    const release = holdResponse();
    const pending = fetchURL("/api/resources/", {});
    const replacement = token("bob");
    parseToken(replacement);
    const response = new Response("{}", {
      headers: { "X-Renew-Token": "true" },
    });
    release(response);
    expect(await pending).toBe(response);
    expect(fetch).toHaveBeenCalledTimes(1);
    expectSession(replacement, "bob");
  });

  it("renews on a current successful response's renewal header", async () => {
    const old = token("alice");
    parseToken(old);
    const current = token("alice", 1);
    const response = new Response("{}", {
      headers: { "X-Renew-Token": "true" },
    });
    vi.mocked(fetch)
      .mockResolvedValueOnce(response)
      .mockResolvedValueOnce(new Response(current));
    expect(await fetchURL("/api/resources/", {})).toBe(response);
    expectSession(current, "alice");
    expect(fetch).toHaveBeenLastCalledWith("/api/renew", {
      method: "POST",
      headers: { "X-Auth": old },
    });
  });
});
