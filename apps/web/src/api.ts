export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

const API_URL_STORAGE_KEY = "koliwada-api-url";
const configuredApiUrl = import.meta.env.VITE_API_URL?.trim();
const DEFAULT_API_URL = configuredApiUrl || (import.meta.env.PROD ? "" : "http://localhost:4000");

export function getApiBaseUrl(): string {
  const savedUrl = window.localStorage.getItem(API_URL_STORAGE_KEY);
  return (savedUrl ?? DEFAULT_API_URL).replace(/\/+$/, "");
}

export function saveApiBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("Enter a valid server URL, including https://.");
  }
  const localDevelopmentUrl =
    import.meta.env.DEV && ["localhost", "127.0.0.1", "::1"].includes(url.hostname);
  if (url.protocol !== "https:" && !localDevelopmentUrl) {
    throw new Error("Server URL must use HTTPS.");
  }
  if (url.username || url.password || url.search || url.hash || (url.pathname !== "/" && url.pathname !== "")) {
    throw new Error("Enter only the server address, without credentials or a path.");
  }
  const normalized = url.origin;
  window.localStorage.setItem(API_URL_STORAGE_KEY, normalized);
  return normalized;
}

export function clearSavedApiBaseUrl(): void {
  window.localStorage.removeItem(API_URL_STORAGE_KEY);
}

export async function apiRequest<T>(
  path: string,
  token?: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  if (init.body) headers.set("Content-Type", "application/json");
  if (token) headers.set("Authorization", `Bearer ${token}`);

  let response: Response;
  try {
    response = await fetch(`${getApiBaseUrl()}/api${path}`, {
      ...init,
      headers,
      cache: "no-store",
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw error;
    }
    console.error(`API request failed: ${path}`, error);
    throw new ApiError("Cannot reach the restaurant server. Check the connection and try again.", 0);
  }

  if (!response.ok) {
    let message = `Request failed (${response.status}).`;
    try {
      const body: unknown = await response.json();
      if (typeof body === "object" && body !== null && "error" in body && typeof body.error === "string") {
        message = body.error;
      }
    } catch (error) {
      console.error(`Could not read the error response from ${path}:`, error);
    }
    throw new ApiError(message, response.status);
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export function jsonBody(value: unknown): string {
  return JSON.stringify(value);
}
