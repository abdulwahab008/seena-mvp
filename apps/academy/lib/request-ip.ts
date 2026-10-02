/**
 * FR-L11 AC4: the address an approval was made from.
 *
 * Postgres can see inet_client_addr(), and behind PostgREST and Supabase's
 * pooler it reports the POOLER's address — the same value for every user in
 * the tenant. The client address exists only in the request, so the server
 * action reads it here and passes it to decide_expense_voucher().
 *
 * What this is worth, honestly:
 *
 *   * `x-forwarded-for` is appended to by each proxy, so the FIRST entry is
 *     the original client — but only if a trusted proxy overwrote whatever
 *     the client sent. Behind Vercel or a correctly configured nginx it is
 *     evidence. With Next.js exposed directly to the internet a caller can
 *     send any value they like and it is a claim, not evidence.
 *   * A request with neither header (a direct origin hit) yields null, which
 *     is recorded as NULL and displayed as "not recorded". Never 0.0.0.0.
 *   * It records where a request came FROM. WHO it came from is the approver
 *     id, which comes from the JWT and is not spoofable.
 *
 * Anything that is not a plausible address is dropped here and again in
 * app.fn_parse_request_ip(), so a header full of junk stores NULL rather
 * than failing the approval.
 */

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
// Deliberately loose: the authority on what is an address is Postgres's inet
// type, and this only keeps obvious junk out of the round trip.
const IPV6 = /^[0-9a-fA-F:]{2,45}$/;

export function parseForwardedIp(value: string | null | undefined): string | null {
  if (!value) return null;
  const first = value.split(',')[0]?.trim();
  if (!first) return null;
  // An IPv6 literal in a Forwarded-style header may be bracketed, and either
  // family may carry a :port.
  const unbracketed = first.startsWith('[') ? first.slice(1).split(']')[0]! : first;
  const candidate = unbracketed.includes('.') ? unbracketed.split(':')[0]! : unbracketed;
  if (IPV4.test(candidate)) return candidate;
  if (candidate.includes(':') && IPV6.test(candidate)) return candidate;
  return null;
}

export function clientIpFromHeaders(headers: Headers): string | null {
  return parseForwardedIp(headers.get('x-forwarded-for')) ?? parseForwardedIp(headers.get('x-real-ip'));
}
