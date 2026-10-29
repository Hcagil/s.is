export type VegaErrorCode = 'login' | 'timeout' | 'shape' | 'config';
export class VegaError extends Error { constructor(readonly code: VegaErrorCode) { super(code); } }
/** The one place that talks to Vega. Base URL comes from the secret VEGA_BASE_URL (so a fake server can stand in); username/password from VEGA_USERNAME / VEGA_PASSWORD. Returns the money total exactly as Vega prints it. */
export async function fetchVegaTotal(day: string, prev: boolean): Promise<string> {
  void day;
  void prev;
  const baseUrl = Deno.env.get('VEGA_BASE_URL');
  const username = Deno.env.get('VEGA_USERNAME');
  const password = Deno.env.get('VEGA_PASSWORD');
  if (!baseUrl || !username || !password) {
    throw new VegaError('config');
  }
  // TODO(owner step): Vega's login form fields and the page that holds the total are not known without credentials. Implement login + read here, nothing else may change. Never put the password in a URL, never log request or response.
  throw new VegaError('shape');
}
