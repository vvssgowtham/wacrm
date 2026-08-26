/**
 * The Supabase origin that SERVER-side code should call.
 *
 * The browser and the server do not necessarily reach Supabase at the
 * same address. On a single-box self-host (see `deploy/selfhost/`)
 * `NEXT_PUBLIC_SUPABASE_URL` is the machine's own public address —
 * which the browser can reach, but the app container cannot: an EC2
 * instance does not route traffic to its own Elastic IP, it sends it
 * out to the internet gateway where it is dropped.
 *
 * The symptom is specific and misleading. Login succeeds, because the
 * browser talks to Supabase directly. Then `middleware.ts` calls
 * `supabase.auth.getUser()`, the request never arrives, `user` comes
 * back null, and the middleware redirects to /login — so you land back
 * on the login page with no error anywhere, having just authenticated
 * successfully.
 *
 * Set `SUPABASE_INTERNAL_URL` to an address the server can reach
 * (`http://kong:8000` on the compose network) and leave
 * `NEXT_PUBLIC_SUPABASE_URL` as the browser's public address.
 *
 * When unset — hosted Supabase, or any deployment where one URL works
 * for both — this is exactly `NEXT_PUBLIC_SUPABASE_URL` and nothing
 * changes.
 *
 * Do NOT use this in browser code: `SUPABASE_INTERNAL_URL` names a
 * host that only exists inside the container network.
 * `src/lib/supabase/client.ts` must keep reading the public value.
 *
 * Deliberately a function, not a `const`. The value must be read when
 * the client is built, not when this module is first imported — the
 * originals read `process.env` inside their factories, and
 * `middleware.test.ts` relies on that: it imports the module under
 * test before `beforeEach` assigns the environment.
 */
export function supabaseApiUrl(): string {
  return process.env.SUPABASE_INTERNAL_URL || process.env.NEXT_PUBLIC_SUPABASE_URL!
}
