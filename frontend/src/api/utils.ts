import { baseURL } from "@/utils/constants";
import { encodePath } from "@/utils/url";
import { createTransport } from "./transport";

// Preserve the public API while keeping transport independent of UI state.
export { StatusError } from "@/utils/errors";
export { setSafeTimeout, type SafeTimeout } from "@/utils/timers";
const transport = createTransport(baseURL);
export const { fetchURL, fetchJSON, getAuthToken } = transport;
export const configureApiAuth = transport.configureAuth;

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
