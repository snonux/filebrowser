import { useAuthStore } from "@/stores/auth";
import {
  renew,
  logout,
  captureAuthSession,
  isCurrentAuthSession,
} from "@/utils/auth";
import { baseURL } from "@/utils/constants";
import { encodePath } from "@/utils/url";

export class StatusError extends Error {
  constructor(
    message: any,
    public status?: number,
    public is_canceled?: boolean
  ) {
    super(message);
    this.name = "StatusError";
  }
}

export async function fetchURL(
  url: string,
  opts: ApiOpts,
  auth = true
): Promise<Response> {
  const authStore = useAuthStore();
  const session = captureAuthSession();

  opts = opts || {};
  opts.headers = opts.headers || {};

  const { headers, ...rest } = opts;
  let res;
  try {
    res = await fetch(`${baseURL}${url}`, {
      headers: {
        "X-Auth": authStore.jwt,
        ...headers,
      },
      ...rest,
    });
  } catch (e) {
    // Check if the error is an intentional cancellation
    if (e instanceof Error && e.name === "AbortError") {
      throw new StatusError("000 No connection", 0, true);
    }
    throw new StatusError("000 No connection", 0);
  }

  if (
    auth &&
    isCurrentAuthSession(session) &&
    res.headers.get("X-Renew-Token") === "true"
  ) {
    await renew(session.jwt);
  }

  if (res.status < 200 || res.status > 299) {
    const body = await res.text();
    const error = new StatusError(
      body || `${res.status} ${res.statusText}`,
      res.status
    );

    if (auth && res.status == 401 && isCurrentAuthSession(session)) {
      logout();
    }

    throw error;
  }

  return res;
}

export async function fetchJSON<T>(url: string, opts?: any): Promise<T> {
  const res = await fetchURL(url, opts);

  if (res.status === 200) {
    return res.json() as Promise<T>;
  }

  throw new StatusError(`${res.status} ${res.statusText}`, res.status);
}

export function removePrefix(url: string): string {
  url = url.split("/").splice(2).join("/");

  if (url === "") url = "/";
  if (url[0] !== "/") url = "/" + url;
  return url;
}

export function createURL(endpoint: string, searchParams = {}): string {
  let prefix = baseURL;
  if (!prefix.endsWith("/")) {
    prefix = prefix + "/";
  }
  const url = new URL(prefix + encodePath(endpoint), origin);
  url.search = new URLSearchParams(searchParams).toString();

  return url.toString();
}

export interface SafeTimeout {
  cancel(): void;
}

export function setSafeTimeout(
  callback: () => void,
  delay: number
): SafeTimeout {
  const MAX_DELAY = 86_400_000;
  let remaining = delay;
  let timer: number;
  let canceled = false;

  function scheduleNext() {
    timer = window.setTimeout(
      () => {
        // Clearing the browser timeout cannot stop a callback already queued.
        if (canceled) return;
        // NaN follows the browser's immediate timeout behavior. Infinite delays
        // stay in bounded chunks until canceled, without a busy loop.
        if (remaining > MAX_DELAY) {
          remaining -= MAX_DELAY;
          scheduleNext();
        } else {
          callback();
        }
      },
      Math.min(remaining, MAX_DELAY)
    );
  }

  scheduleNext();
  return {
    cancel() {
      canceled = true;
      window.clearTimeout(timer);
    },
  };
}
