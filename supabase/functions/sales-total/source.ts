export type SalesStep = 'page' | 'action' | 'report' | 'parse';
export type SalesErrorCode = 'login' | 'timeout' | 'shape' | 'config' | 'other';
export class SalesError extends Error { constructor(readonly code: SalesErrorCode, readonly step?: SalesStep) { super(code); } }

/**
 * The one place that talks to the sales source; base URL from secret SALES_SOURCE_URL (so a fake server can stand in), SALES_SOURCE_USER / SALES_SOURCE_PASSWORD;
 * returns the money total exactly as the source prints it.
 */
async function readCapped(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) throw new SalesError('shape');
  let total = 0;
  const chunks: Uint8Array[] = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > 1048576) {
      await reader.cancel();
      throw new SalesError('shape'); // a reply over 1 MiB is not the page we expect
    }
    chunks.push(value);
  }
  const decoder = new TextDecoder();
  return chunks.map((c) => decoder.decode(c, { stream: true })).join('') + decoder.decode();
}

export async function fetchSalesTotal(day: string, prev: boolean): Promise<string> {
  void day; // shortcut: durum picks the day on the source's side; tarihBaslangic/tarihBitis not sent, add if the real call shows durum alone is not enough
  const baseUrl = Deno.env.get('SALES_SOURCE_URL');
  const username = Deno.env.get('SALES_SOURCE_USER');
  const password = Deno.env.get('SALES_SOURCE_PASSWORD');
  if (!baseUrl || !username || !password) {
    throw new SalesError('config');
  }
  const base = baseUrl.replace(/\/+$/, '');
  const signal = AbortSignal.timeout(15000);
  let step: SalesStep = 'page';
  try {
    // the site rejects a login without the anti-forgery token (hidden field + matching cookie from the login page)
    const page = await fetch(`${base}/Authentication/Login`, { redirect: 'manual', signal });
    const pre = page.headers.getSetCookie().map((c) => c.split(';')[0]);
    const pageHtml = page.status === 200 ? await readCapped(page) : (await page.body?.cancel(), '');
    // bounded window against regex backtracking
    const ti = pageHtml.indexOf('name="__RequestVerificationToken"');
    let field: string | undefined;
    if (ti >= 0) {
      const start = pageHtml.lastIndexOf('<input', ti);
      const end = pageHtml.indexOf('>', ti);
      if (start >= 0 && end >= 0) {
        const tag = pageHtml.slice(start, Math.min(end, start + 1024));
        field = tag.match(/value="([^"]*)"/)?.[1];
      }
    }
    if (!field || !pre.some((c) => c.startsWith('__RequestVerificationToken='))) throw new SalesError('login', step);
    step = 'action';
    const res = await fetch(`${base}/Authentication/LoginAction`, {
      method: 'POST', redirect: 'manual', signal,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: pre.join('; ') },
      body: new URLSearchParams({ UygulamaTipi: '3', UserName: username, Password: password, __RequestVerificationToken: field })
    });
    await res.body?.cancel();
    const set = res.headers.getSetCookie();
    if (res.status >= 400 || set.length === 0) throw new SalesError('login', step);
    const cookie = [...pre, ...set.map((c) => c.split(';')[0])].join('; ');
    step = 'report';
    const res2 = await fetch(`${base}/OzetRaporlar/List?durum=${prev ? 'dun' : 'bugun'}`, { redirect: 'manual', signal, headers: { Cookie: cookie } });
    if (res2.status !== 200) {
      await res2.body?.cancel();
      throw new SalesError('login', step); // a wrong login also answers 302: only 200 means the session is accepted
    }
    step = 'parse';
    const html = await readCapped(res2);
    // the regex backtracks badly on a crafted body, so it only sees the 512 bytes after the label
    const i = html.indexOf('Toplam Ciro</div>');
    const m = i < 0 ? null : html.slice(i, i + 512).match(/Toplam Ciro<\/div>\s*<[^>]*class="[^"]*dash-stat-value[^"]*"[^>]*>\s*([0-9.,]+)\s*</);
    if (!m) throw new SalesError('shape', step);
    return m[1];
  } catch (e) {
    if (e instanceof SalesError) throw e.step ? e : new SalesError(e.code, step);
    const n = (e as { name?: string }).name;
    if (n === 'TimeoutError' || n === 'AbortError') throw new SalesError('timeout', step);
    throw new SalesError('other', step); // a plain network error: its message is never read or logged
  }
}
