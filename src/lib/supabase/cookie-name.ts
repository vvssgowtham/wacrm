/**
 * The name of the cookie the Supabase session is stored in.
 *
 * Pinned explicitly, because the default is derived from the URL's
 * hostname. In supabase-js:
 *
 *   const defaultStorageKey = `sb-${baseUrl.hostname.split(".")[0]}-auth-token`
 *
 * The browser and the server do not always build their client from
 * the same URL — see `./api-url.ts` — and on a single-box self-host
 * they don't:
 *
 *   browser  http://203.0.113.5:8000  -> hostname 203.0.113.5 -> "sb-203-auth-token"
 *   server   http://kong:8000         -> hostname kong        -> "sb-kong-auth-token"
 *
 * The browser writes one cookie, the server reads a different name,
 * finds nothing, and treats every authenticated request as anonymous.
 * Login appears to succeed and then bounces straight back to /login.
 *
 * A fixed name makes the two agree regardless of the URL each side
 * uses. It also survives the machine's IP changing, which the derived
 * name does not — a new address would otherwise silently log everyone
 * out.
 *
 * Must be identical in `client.ts`, `server.ts` and `middleware.ts`.
 * Changing it invalidates every existing session, which is harmless
 * (users log in again) but not something to do casually.
 */
export const SUPABASE_COOKIE_NAME = 'sb-wacrm-auth-token'
