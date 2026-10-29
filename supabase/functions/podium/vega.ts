export type VegaErrorCode = 'login' | 'timeout' | 'shape' | 'config';
export class VegaError extends Error { constructor(readonly code: VegaErrorCode) { super(code); } }

/**
 * The one place that talks to Vega; base URL from secret VEGA_BASE_URL (so a fake server can stand in), VEGA_USERNAME / VEGA_PASSWORD;
 * returns the money total exactly as Vega prints it.
 */
export async function fetchVegaTotal(day: string, prev: boolean): Promise<string> {
  void day; void prev;
  const baseUrl = Deno.env.get('VEGA_BASE_URL');
  const username = Deno.env.get('VEGA_USERNAME');
  const password = Deno.env.get('VEGA_PASSWORD');
  if (!baseUrl || !username || !password) {
    throw new VegaError('config');
  }
  // TODO(owner step): the page that holds the total is not known without credentials. Login form: POST /Authentication/LoginAction, fields UygulamaTipi=3, UserName, Password. Never put the password in a URL, never log request or response.
  throw new VegaError('shape');
}
