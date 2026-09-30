// The post-deploy smoke (docs/qa/README.md, "The regime"): run by the deploy
// workflow against the app it just deployed, never by the push gate. Read-only
// checks first (health, headers, the PWA files, an anonymous lobby and room,
// Nexus for a listed room), then the one write of the run: the two staging
// identities, signed in through their stored session cookies, meet in the
// unlisted smoke room — one sends a stamped message, the other sees it live,
// the file is read back from the homeserver, and the sender deletes it again.
//
//   cd pubky_rooms && NODE_PATH=assets/node_modules \
//   ROOMS_URL=https://pubky-rooms-staging.fly.dev SMOKE_ROOM=/r/<owner>/<id> \
//   SMOKE_ALICE_COOKIE=… SMOKE_BOB_COOKIE=… node scripts/deploy_smoke.js
//
// Environment: ROOMS_URL, SMOKE_ROOM (path of the unlisted room both
// identities are members of), SMOKE_ALICE_COOKIE / SMOKE_BOB_COOKIE (the
// `_pubky_rooms_key` values; repository secrets), SMOKE_HOMESERVER_URL (the
// homeserver both identities live on, default the staging one), SMOKE_NEXUS_URL
// (optional; a failing Nexus check is reported but does not fail the run),
// SMOKE_SHOTS_DIR (screenshots on failure, default tmp/smoke). Exit code 1 when
// any hard check fails. Playwright comes from assets/node_modules.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = must('ROOMS_URL').replace(/\/$/, '');
const ROOM = must('SMOKE_ROOM');
const COOKIES = { alice: must('SMOKE_ALICE_COOKIE'), bob: must('SMOKE_BOB_COOKIE') };
const HOMESERVER = (process.env.SMOKE_HOMESERVER_URL || 'https://homeserver.staging.pubky.app').replace(/\/$/, '');
const NEXUS = (process.env.SMOKE_NEXUS_URL || '').replace(/\/$/, '');
const SHOTS = process.env.SMOKE_SHOTS_DIR || 'tmp/smoke';
const RUN = `${process.env.GITHUB_RUN_ID || 'local'}-${Date.now().toString(36)}`;
const host = new URL(BASE).hostname;

function must(name) {
  const v = process.env[name];
  if (!v) { console.error(`${name} is not set`); process.exit(2); }
  return v;
}

const results = [];
async function check(name, fn, { soft = false } = {}) {
  const t0 = Date.now();
  try {
    const note = await fn();
    results.push({ name, ok: true, ms: Date.now() - t0, note });
    console.log(`ok    ${name}${note ? ` — ${note}` : ''} (${Date.now() - t0} ms)`);
  } catch (e) {
    results.push({ name, ok: !!soft, soft, ms: Date.now() - t0, note: e.message });
    console.log(`${soft ? 'warn ' : 'FAIL '} ${name} — ${e.message}`);
  }
}
function expect(cond, msg) { if (!cond) throw new Error(msg); }

async function browserPage(browser, name, cookie) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  if (cookie) {
    await ctx.addCookies([{ name: '_pubky_rooms_key', value: cookie, domain: host, path: '/', httpOnly: true, secure: BASE.startsWith('https'), sameSite: 'Lax' }]);
  }
  const page = await ctx.newPage();
  page.setDefaultTimeout(20000);
  const problems = [];
  page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') problems.push(`[${m.type()}] ${m.text()}`); });
  page.on('pageerror', e => problems.push(`[pageerror] ${e.message}`));
  page.on('dialog', d => d.accept()); // the delete confirmation
  return { name, ctx, page, problems };
}

async function open(p, route) {
  await p.page.goto(`${BASE}${route}`, { waitUntil: 'domcontentloaded' });
  await p.page.waitForSelector('.phx-connected', { timeout: 20000 });
}

const rows = page => page.locator('#messages > [id^="msg-"]');

// the message file on the homeserver: path-addressed storage first, the legacy
// form (path + pubky-host header) for homeservers without the feature
async function fileStatus(author, filePath) {
  const a = await fetch(`${HOMESERVER}/storage/${author}${filePath}`);
  if (a.status === 200) return { status: 200, form: 'path-addressed' };
  const b = await fetch(`${HOMESERVER}${filePath}`, { headers: { 'pubky-host': author } });
  return { status: b.status === 200 ? 200 : a.status, form: b.status === 200 ? 'legacy' : 'path-addressed' };
}

(async () => {
  console.log(`smoke ${RUN} against ${BASE} (room ${ROOM})`);

  // ── read-only ──────────────────────────────────────────────────────────
  await check('health', async () => {
    const r = await fetch(`${BASE}/healthz`);
    expect(r.status === 200, `status ${r.status}`);
    const body = await r.json();
    expect(body.status === 'ok', `body ${JSON.stringify(body)}`);
    return `rooms ${body.rooms}, streams ${body.streams}`;
  });

  await check('security headers on /', async () => {
    const r = await fetch(`${BASE}/`);
    expect(r.status === 200, `status ${r.status}`);
    const h = n => r.headers.get(n) || '';
    expect(h('content-security-policy').includes("default-src 'self'"), `csp: ${h('content-security-policy').slice(0, 60)}`);
    expect(h('x-frame-options') === 'DENY', `x-frame-options: ${h('x-frame-options')}`);
    expect(h('x-content-type-options') === 'nosniff', 'x-content-type-options missing');
    expect(h('referrer-policy') === 'strict-origin-when-cross-origin', 'referrer-policy missing');
    if (BASE.startsWith('https')) expect(h('strict-transport-security').includes('max-age'), 'hsts missing');
  });

  if (BASE.startsWith('https')) {
    await check('http redirects to https', async () => {
      const r = await fetch(`http://${host}/`, { redirect: 'manual' });
      expect([301, 302, 307, 308].includes(r.status), `status ${r.status}`);
      expect((r.headers.get('location') || '').startsWith('https://'), `location ${r.headers.get('location')}`);
    });
  }

  await check('pwa files', async () => {
    const m = await fetch(`${BASE}/manifest.webmanifest`);
    expect(m.status === 200, `manifest ${m.status}`);
    const sw = await fetch(`${BASE}/sw.js`);
    expect(sw.status === 200, `sw.js ${sw.status}`);
    const version = ((await sw.text()).match(/pubky-rooms-v\d+/) || [])[0];
    expect(version, 'sw.js carries no cache version');
    const off = await fetch(`${BASE}/offline.html`);
    expect(off.status === 200 && (await off.text()).includes('<svg'), `offline page ${off.status}`);
    return `worker ${version}`;
  });

  const browser = await chromium.launch();
  const anon = await browserPage(browser, 'anon');
  let listed = null;

  await check('anonymous lobby', async () => {
    await open(anon, '/');
    await anon.page.locator('#directory').waitFor();
    const link = anon.page.locator('#directory a[href^="/r/"]').first();
    if (await link.count()) listed = await link.getAttribute('href');
    expect(!(await anon.page.locator('body').innerText()).includes('Deploy smoke'), 'the smoke room is listed');
    return listed ? `first listed room ${listed}` : 'directory empty';
  });

  if (listed) {
    await check('anonymous room', async () => {
      await open(anon, listed);
      await anon.page.locator('#messages').waitFor();
      expect(!(await anon.page.locator('#composer').count()), 'a signed-out viewer has a composer');
      return `${await rows(anon.page).count()} messages on first paint`;
    });

    if (NEXUS) {
      await check('nexus knows a listed room', async () => {
        const [, owner, id] = listed.match(/^\/r\/([a-z0-9]{52})\/([A-Z0-9]{13})$/) || [];
        expect(owner, `unexpected room path ${listed}`);
        const uri = `pubky://${owner}/pub/pubky-rooms/rooms/${id}`;
        const r = await fetch(`${NEXUS}/v0/resource/by-uri?uri=${encodeURIComponent(uri)}`);
        expect(r.status === 200, `status ${r.status}`);
        const body = await r.json();
        expect(body.resource && body.resource.uri === uri, `unexpected body ${JSON.stringify(body).slice(0, 120)}`);
        return `${(body.tags || []).length} tags`;
      }, { soft: true });
    }
  }

  await check('anonymous console clean', async () => expect(anon.problems.length === 0, anon.problems.join(' | ')));

  // ── the one write of the run ───────────────────────────────────────────
  const alice = await browserPage(browser, 'alice', COOKIES.alice);
  const bob = await browserPage(browser, 'bob', COOKIES.bob);
  const stamp = `smoke ${RUN} ${new Date().toISOString()}`;
  let author = null, msgId = null, form = null;
  const [, owner, roomId] = ROOM.match(/^\/r\/([a-z0-9]{52})\/([A-Z0-9]{13})$/) || [];
  expect(owner, `SMOKE_ROOM must be /r/<owner>/<id>, got ${ROOM}`);

  try {
    await check('both identities signed in and members of the smoke room', async () => {
      for (const p of [alice, bob]) {
        await open(p, ROOM);
        expect(await p.page.locator('a[href="/me"]').count(), `${p.name} is signed out (cookie expired or revoked: sign in again and update the secret)`);
        await p.page.locator('#composer').waitFor({ timeout: 20000 }).catch(() => { throw new Error(`${p.name} has no composer: not a member`); });
      }
      expect((await alice.page.locator('body').innerText()).includes('Unlisted'), 'the smoke room is not unlisted');
    });

    await check('alice sends, the row confirms as stored', async () => {
      await alice.page.fill('#composer-input', stamp);
      await alice.page.press('#composer-input', 'Enter');
      const row = rows(alice.page).filter({ hasText: stamp }).last();
      await row.waitFor();
      await row.locator('[data-tip="Stored on your homeserver"]').waitFor({ timeout: 30000 });
      [, author, msgId] = (await row.getAttribute('id')).match(/^msg-([a-z0-9]{52})-([A-Z0-9]{13})$/);
      expect(author && msgId, 'row id without author and id');
    });

    await check('bob sees it live', async () => {
      const t0 = Date.now();
      await rows(bob.page).filter({ hasText: stamp }).first().waitFor({ timeout: 20000 });
      return `${Date.now() - t0} ms`;
    });

    await check('the message file is on the homeserver', async () => {
      expect(msgId, 'no message id');
      const r = await fileStatus(author, `/pub/pubky-rooms/messages/${owner}/${roomId}/${msgId}`);
      expect(r.status === 200, `status ${r.status}`);
      form = r.form;
      return form;
    });

    await check('alice deletes it, both views and the homeserver agree', async () => {
      expect(msgId, 'no message id');
      const id = `msg-${author}-${msgId}`;
      await alice.page.hover(`#${id}`);
      await alice.page.click(`#${id}-actions [aria-label="Delete"]`);
      await alice.page.locator(`#${id}`).waitFor({ state: 'detached', timeout: 20000 });
      await bob.page.locator(`#${id}`).waitFor({ state: 'detached', timeout: 20000 });
      const filePath = `/pub/pubky-rooms/messages/${owner}/${roomId}/${msgId}`;
      let status = 200;
      for (let i = 0; i < 20 && status === 200; i++) {
        status = (await fileStatus(author, filePath)).status;
        if (status === 200) await new Promise(r => setTimeout(r, 500));
      }
      expect(status === 404, `file still answers ${status}`);
    });

    await check('signed-in consoles clean', async () => {
      const all = [...alice.problems.map(p => `alice ${p}`), ...bob.problems.map(p => `bob ${p}`)];
      expect(all.length === 0, all.join(' | '));
    });
  } finally {
    if (results.some(r => !r.ok)) {
      fs.mkdirSync(SHOTS, { recursive: true });
      for (const p of [anon, alice, bob]) {
        await p.page.screenshot({ path: path.join(SHOTS, `${p.name}.png`), fullPage: true }).catch(() => {});
      }
      console.log(`screenshots in ${SHOTS}/`);
    }
    await browser.close();
  }

  const failed = results.filter(r => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed` + (failed.length ? `; failed: ${failed.map(f => f.name).join(', ')}` : ''));
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error('smoke crashed:', e); process.exit(1); });
