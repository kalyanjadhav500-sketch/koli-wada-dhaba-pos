export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/**
 * Koli Wada Dhaba is a single-laptop, local-only POS application.
 * Never read VITE_API_URL or a user-saved remote URL in the packaged client.
 * The API is hosted by the local Express process started by Electron.
 */
const API_URL_STORAGE_KEY = "koliwada-api-url";
const LOCAL_API_URL = "http://127.0.0.1:4000";

export function getApiBaseUrl(): string {
  // Return the fixed loopback endpoint so stale cloud URLs from older builds
  // cannot redirect restaurant data to an external server.
  return LOCAL_API_URL;
}

/**
 * Kept for compatibility with any older Settings UI.
 * Only the exact local POS endpoint is accepted; remote URLs are rejected.
 */
export function saveApiBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("Koli Wada Dhaba POS uses its built-in local server only.");
  }

  if (
    url.protocol !== "http:" ||
    url.hostname !== "127.0.0.1" ||
    url.port !== "4000" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (url.pathname !== "/" && url.pathname !== "")
  ) {
    throw new Error("External servers are not supported. Use the local Koli Wada Dhaba POS server.");
  }

  clearSavedApiBaseUrl();
  return LOCAL_API_URL;
}

export function clearSavedApiBaseUrl(): void {
  // Remove a remote URL saved by an earlier cloud-enabled build.
  window.localStorage.removeItem(API_URL_STORAGE_KEY);
}

export async function apiRequest<T>(
  path: string,
  token?: string,
  init: RequestInit = {},
): Promise<T> {
  if (!path.startsWith("/") || path.startsWith("//")) {
    throw new ApiError("Invalid local API path.", 400);
  }

  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  if (init.body !== undefined && init.body !== null) {
    headers.set("Content-Type", "application/json");
  }
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }

  let response: Response;
  try {
    response = await fetch(`${LOCAL_API_URL}/api${path}`, {
      ...init,
      headers,
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw error;
    }
    console.error(`Local API request failed: ${path}`, error);
    throw new ApiError(
      "Cannot reach the local restaurant database service. Check that Koli Wada Dhaba POS is running.",
      0,
    );
  }

  if (!response.ok) {
    let message = `Request failed (${response.status}).`;
    try {
      const body: unknown = await response.json();
      if (
        typeof body === "object" &&
        body !== null &&
        "error" in body &&
        typeof body.error === "string"
      ) {
        message = body.error;
      }
    } catch (error) {
      console.error(`Could not read the local API error response from ${path}:`, error);
    }
    throw new ApiError(message, response.status);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

export function jsonBody(value: unknown): string {
  return JSON.stringify(value);
}
