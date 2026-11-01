export type VegaErrorCode = 'login' | 'timeout' | 'shape' | 'config';
export class VegaError extends Error { constructor(readonly code: VegaErrorCode) { super(code); } }

/**
 * The one place that talks to Vega; base URL from secret VEGA_BASE_URL (so a fake server can stand in), VEGA_USERNAME / VEGA_PASSWORD;
 * returns the money total exactly as Vega prints it.
 */
export async function fetchVegaTotal(day: string, prev: boolean): Promise<string> {
  void day; // shortcut: durum picks the day on Vega's side; tarihBaslangic/tarihBitis not sent, add if the real call shows durum alone is not enough
  const baseUrl = Deno.env.get('VEGA_BASE_URL');
  const username = Deno.env.get('VEGA_USERNAME');
  const password = Deno.env.get('VEGA_PASSWORD');
  if (!baseUrl || !username || !password) {
    throw new VegaError('config');
  }
  const base = baseUrl.replace(/\/+$/, '');
  const signal = AbortSignal.timeout(15000);
  try {
    const res = await fetch(`${base}/Authentication/LoginAction`, {
      method: 'POST', redirect: 'manual', signal,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ UygulamaTipi: '3', UserName: username, Password: password })
    });
    await res.body?.cancel();
    const cookie = res.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
    if (res.status >= 400 || cookie === '') throw new VegaError('login');
    const res2 = await fetch(`${base}/OzetRaporlar/List?durum=${prev ? 'dun' : 'bugun'}`, { redirect: 'manual', signal, headers: { Cookie: cookie } });
    if (res2.status >= 300) {
      await res2.body?.cancel();
      throw new VegaError('login'); // a redirect = session not accepted
    }
    const reader = res2.body?.getReader();
    if (!reader) throw new VegaError('shape');
    let total = 0;
    const chunks: Uint8Array[] = [];
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > 1048576) {
        await reader.cancel();
        throw new VegaError('shape'); // a reply over 1 MiB is not the report page
      }
      chunks.push(value);
    }
    const decoder = new TextDecoder();
    const html = chunks.map((c) => decoder.decode(c, { stream: true })).join('') + decoder.decode();
    // the regex backtracks badly on a crafted body, so it only sees the 512 bytes after the label
    const i = html.indexOf('Toplam Ciro</div>');
    const m = i < 0 ? null : html.slice(i, i + 512).match(/Toplam Ciro<\/div>\s*<[^>]*class="[^"]*dash-stat-value[^"]*"[^>]*>\s*([0-9.,]+)\s*</);
    if (!m) throw new VegaError('shape');
    return m[1];
  } catch (e) {
    if (e instanceof VegaError) throw e;
    const n = (e as { name?: string }).name;
    if (n === 'TimeoutError' || n === 'AbortError') throw new VegaError('timeout');
    throw e; // network error: index.ts counts it as 'other'
  }
}
