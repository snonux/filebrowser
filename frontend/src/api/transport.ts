import { StatusError } from "@/utils/errors";

export interface AuthSession {
  jwt: string;
  generation: number;
}

export interface ApiAuthAdapter {
  captureSession(): AuthSession;
  isCurrentSession(session: AuthSession): boolean;
  renew(jwt: string): Promise<void>;
  logout(): void;
}

// The application supplies session ownership and presentation effects at startup.
export function createTransport(baseURL: string) {
  let authAdapter: ApiAuthAdapter = {
    captureSession: () => ({ jwt: "", generation: 0 }),
    isCurrentSession: () => false,
    renew: async () => {},
    logout: () => {},
  };

  async function fetchURL(
    url: string,
    opts: ApiOpts,
    auth = true
  ): Promise<Response> {
    const session = authAdapter.captureSession();

    opts = opts || {};
    opts.headers = opts.headers || {};

    const { headers, ...rest } = opts;
    let res;
    try {
      res = await fetch(`${baseURL}${url}`, {
        headers: {
          "X-Auth": session.jwt,
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
      authAdapter.isCurrentSession(session) &&
      res.headers.get("X-Renew-Token") === "true"
    ) {
      await authAdapter.renew(session.jwt);
    }

    if (res.status < 200 || res.status > 299) {
      const body = await res.text();
      const error = new StatusError(
        body || `${res.status} ${res.statusText}`,
        res.status
      );

      if (auth && res.status == 401 && authAdapter.isCurrentSession(session)) {
        authAdapter.logout();
      }

      throw error;
    }

    return res;
  }

  async function fetchJSON<T>(url: string, opts?: any): Promise<T> {
    const res = await fetchURL(url, opts);

    if (res.status === 200) {
      return res.json() as Promise<T>;
    }

    throw new StatusError(`${res.status} ${res.statusText}`, res.status);
  }

  return {
    fetchURL,
    fetchJSON,
    getAuthToken: () => authAdapter.captureSession().jwt,
    configureAuth: (adapter: ApiAuthAdapter) => {
      authAdapter = adapter;
    },
  };
}
