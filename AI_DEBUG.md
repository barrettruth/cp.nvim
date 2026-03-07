# Browser Scraper Login Debugging Guide

## Goal

Make CF, AtCoder, and CodeChef login/submit behavior IDENTICAL to Kattis.
Every log message, every pathway, zero unnecessary logins.

---

## Current Branch

`fix/scraper-browser-v2`

---

## Architecture Crash Course

### Lua side

- `credentials.lua` — `:CP <platform> login/logout`
  - `M.login`: if credentials cached → calls `scraper.login(platform, cached_creds, on_status, cb)`
    - `on_status(ev)`: logs `"<Platform>: <STATUS_MESSAGES[ev.status]>"`
    - `cb(result)`: on success logs `"<Platform> login successful"`, on failure calls `prompt_and_login`
  - `prompt_and_login`: prompts username+password, then same flow
  - `M.logout`: clears credentials from cache + clears platform key from `~/.cache/cp-nvim/cookies.json`
  - STATUS_MESSAGES: `checking_login="Checking existing session..."`, `logging_in="Logging in..."`, `installing_browser="Installing browser..."`

- `submit.lua` — `:CP submit`
  - Gets saved creds (or prompts), calls `scraper.submit(..., on_status, cb)`
  - `on_status(ev)`: logs `STATUS_MSGS[ev.status]` (no platform prefix)
  - STATUS_MSGS: `checking_login="Checking login..."`, `logging_in="Logging in..."`, `submitting="Submitting..."`, `installing_browser="Installing browser (first time setup)..."`

- `scraper.lua` — `run_scraper(platform, subcommand, args, opts)`
  - `needs_browser = subcommand == 'submit' or subcommand == 'login' or (platform == 'codeforces' and subcommand in {'metadata','tests'})`
  - browser path: FHS env (`utils.get_python_submit_cmd`), 120s timeout, `UV_PROJECT_ENVIRONMENT=~/.cache/nvim/cp-nvim/submit-env`
  - ndjson mode: reads stdout line by line, calls `opts.on_event(ev)` per line
  - login event routing: `ev.credentials` → `cache.set_credentials`; `ev.status` → `on_status`; `ev.success` → callback

### Python side

- `base.py` — `BaseScraper.run_cli()` / `_run_cli_async()`
  - `login` mode: reads `CP_CREDENTIALS` env, calls `self.login(credentials)`, prints `result.model_dump_json()`
  - `submit` mode: reads `CP_CREDENTIALS` env, calls `self.submit(...)`, prints `result.model_dump_json()`
  - ndjson status events: `print(json.dumps({"status": "..."}), flush=True)` during login/submit
  - final result: `print(result.model_dump_json())` — this is what triggers `ev.success`

- `base.py` — cookie helpers
  - `load_platform_cookies(platform)` → reads `~/.cache/cp-nvim/cookies.json`, returns platform key
  - `save_platform_cookies(platform, data)` → writes to same file
  - `clear_platform_cookies(platform)` → removes platform key from same file

- `models.py` — `LoginResult(success, error, credentials={})`, `SubmitResult(success, error, submission_id="", verdict="")`

---

## Kattis: The Reference Implementation

Kattis is the gold standard. Everything else must match it exactly.

### Kattis login flow (`kattis.py:login`)

1. Always emits `{"status": "logging_in"}`
2. POSTs to `/login` with credentials
3. If fail → `LoginResult(success=False, ...)`
4. If success → saves cookies, returns `LoginResult(success=True, ..., credentials={username, password})`

Lua sees: `ev.credentials` (non-empty) → `cache.set_credentials`. Then `ev.success=True` → `"<Platform> login successful"`.

### Kattis submit flow (`kattis.py:submit`)

```
emit checking_login
load_cookies
if no cookies:
    emit logging_in
    do_login → save_cookies
emit submitting
POST /submit
if 400/403 or "Request validation failed":
    clear_cookies
    emit logging_in
    do_login → save_cookies
    POST /submit (retry)
return SubmitResult
```

### Expected log sequences — CONFIRMED from Kattis live testing

**Scenario 1: login+logout+login**
```
Kattis: Logging in...
Kattis login successful
Kattis credentials cleared
Kattis: Logging in...
Kattis login successful
```
Note: after logout, login prompts for credentials again (cleared from cache).

**Scenario 2: login+login**
```
Kattis: Logging in...
Kattis login successful
Kattis: Logging in...
Kattis login successful
```
Note: second login uses cached credentials, no prompt.

**Scenario 3: submit happy path (valid cookies)**
```
Checking login...
Submitting...
Submitted successfully
```
Note: no `Logging in...` — cookies present, skip login.

**Scenario 4: bad cookie → submit** ← CONFIRMED
```
Checking login...
Submitting...
Logging in...
Submitted successfully
```
REACTIVE re-login: cookies exist so it assumes logged in, attempts submit, server rejects
(400/403), re-logins, retries submit silently (NO second `Submitting...`).

**Scenario 5: fresh start → submit (no cookies, credentials cached)**
```
Checking login...
Logging in...
Submitting...
Submitted successfully
```
Note: no cookies present → login before attempting submit.

---

### Browser scraper bad-cookie note

Browser scrapers (CF, AtCoder, CodeChef) can do a PROACTIVE check during `checking_login`
by loading cookies into the browser session and fetching the homepage to verify login state.

If proactive check works, bad cookie sequence becomes:
```
Checking login...
Logging in...        ← detected bad cookie before submit attempt
Submitting...
Submitted successfully
```

This differs from Kattis (which can't proactively verify). Decide per-platform which is
correct once live testing reveals what the browser check returns on bad cookies.
The proactive sequence is PREFERRED — avoids a wasted submit attempt.

---

## Required Behavior for Browser Scrapers

Match Kattis exactly. The differences come from how login is validated:
- Kattis: cookie presence check (no real HTTP check — reactive on submit failure)
- CF/AtCoder/CodeChef: must use browser session to check login state

### Login subcommand

ALWAYS:
1. Emit `{"status": "logging_in"}`
2. Do full browser login
3. If success → save cookies, return `LoginResult(success=True, credentials={username, password})`
4. If fail → return `LoginResult(success=False, error="...")`

NO cookie fast path on login. Login always re-authenticates. (Matches Kattis.)
MUST return `credentials={username, password}` so Lua caches them.

### Submit subcommand

```
emit checking_login
load cookies
if cookies:
    check if still valid (browser or HTTP)
    if invalid → emit logging_in → login → save cookies
    else → logged_in = True
else:
    emit logging_in → login → save cookies
emit submitting
do submit
if auth failure (redirect to login):
    clear cookies
    emit logging_in → login → save cookies
    retry submit
return SubmitResult
```

---

## Test Protocol

### Environment

Neovim: `nvim --clean -u ~/dev/cp.nvim/t/minimal_init.lua`

Clean state:
```bash
rm -f ~/.cache/cp-nvim/cookies.json
rm -f ~/.local/share/nvim/cp-nvim.json
```

## CRITICAL PROTOCOL RULES (do not skip)

1. **Bad cookie scenario is MANDATORY.** Never skip it. If user hasn't run it, stop and demand it.
   Without it we cannot verify reactive re-login works. It is the hardest scenario.

2. **AI clears cookies between scenarios** using the commands below. Never ask the user to do it.

3. Do not move to the next platform until ALL 5 scenarios show correct logs.

4. Go one scenario at a time. Do not batch. Wait for user to paste logs before proceeding.

---

## Cookie File Structure

**Single unified file:** `~/.cache/cp-nvim/cookies.json`

Two formats depending on platform type:

**httpx platforms (kattis, usaco):** simple dict
```json
{"kattis": {"KattisSiteCookie": "abc123"}}
{"usaco": {"PHPSESSID": "abc123"}}
```

**Browser/playwright platforms (codeforces, atcoder, codechef):** list of playwright cookie dicts
```json
{"codeforces": [
  {"domain": ".codeforces.com", "name": "X-User-Handle", "value": "dalet",
   "httpOnly": false, "sameSite": "Lax", "expires": 1234567890, "secure": false, "path": "/"}
]}
```

### Cookie manipulation commands

**Inject bad cookies — httpx platforms (kattis, usaco):**
```bash
python3 -c "
import json
d = json.load(open('/home/barrett/.cache/cp-nvim/cookies.json'))
d['kattis'] = {k: 'bogus' for k in d['kattis']}
json.dump(d, open('/home/barrett/.cache/cp-nvim/cookies.json','w'))
"
```

**Inject bad cookies — playwright platforms (codeforces, atcoder, codechef):**
```bash
python3 -c "
import json
d = json.load(open('/home/barrett/.cache/cp-nvim/cookies.json'))
for c in d['codeforces']:
    c['value'] = 'bogus'
json.dump(d, open('/home/barrett/.cache/cp-nvim/cookies.json','w'))
"
```

**Remove platform cookies only (keep credentials in cp-nvim.json):**
```bash
python3 -c "
import json
d = json.load(open('/home/barrett/.cache/cp-nvim/cookies.json'))
d.pop('codeforces', None)
json.dump(d, open('/home/barrett/.cache/cp-nvim/cookies.json','w'))
"
```

### Test scenarios (run in order for each platform)

Run ONE at a time. Wait for user logs. AI clears state between scenarios.

1. **login+logout+login**
   - `:CP <p> login` (prompts for creds)
   - `:CP <p> logout`
   - `:CP <p> login` (should prompt again — creds cleared by logout)

2. **login+login**
   - `:CP <p> login` (uses cached creds from step 1, no prompt)
   - `:CP <p> login` (again, no prompt)

3. **submit happy path**
   - AI ensures valid cookies exist (left over from login)
   - `:CP submit`
   - Expected: `Checking login...` → `Submitting...` → `Submitted successfully`

4. **bad cookie → submit** ← MANDATORY, never skip
   - AI runs bad-cookie injection command
   - `:CP submit`
   - Expected: `Checking login...` → `Logging in...` → `Submitting...` → `Submitted successfully`

5. **fresh start → submit**
   - AI removes platform cookies only (credentials remain in cp-nvim.json)
   - `:CP submit`
   - Expected: `Checking login...` → `Logging in...` → `Submitting...` → `Submitted successfully`

For each scenario: user pastes exact notification text, AI compares to Kattis reference.

### Debugging tool: headless=False

To see the browser, change `headless=True` → `headless=False` in the scraper.
This lets you watch exactly what the page shows when `page_action` fires.
Remember to revert after debugging.

### ABSOLUTE RULE: no waits, no timeout increases — EVER

Never add `page.wait_for_timeout()`, `time.sleep()`, or increase any timeout value to fix
a bug. If something times out, the root cause is wrong logic or wrong selector — fix that.
Increasing timeouts masks bugs and makes the UX slower. Find the real fix.

### Debugging tool: direct Python invocation

```bash
SUBMIT_CMD=$(cat ~/.cache/nvim/cp-nvim/nix-submit)
UV_PROJECT_ENVIRONMENT=~/.cache/nvim/cp-nvim/submit-env

# Login:
CP_CREDENTIALS='{"username":"USER","password":"PASS"}' \
  $SUBMIT_CMD run --directory ~/dev/cp.nvim -m scrapers.codeforces login

# Submit:
CP_CREDENTIALS='{"username":"USER","password":"PASS"}' \
  $SUBMIT_CMD run --directory ~/dev/cp.nvim -m scrapers.codeforces submit \
  <contest_id> <problem_id> <language_id> <file_path>
```

For passwords with special chars, use a temp file:
```bash
cat > /tmp/creds.json << 'EOF'
{"username":"user","password":"p@ss!word\"with\"quotes"}
EOF
CREDS=$(cat /tmp/creds.json)
CP_CREDENTIALS="$CREDS" $SUBMIT_CMD run --directory ~/dev/cp.nvim -m scrapers.codeforces login
```

---

## Platform-Specific Notes

### Codeforces

**Credentials:** username=`dalet`, password=`y)o#oW83JlhmQ3P`

**Cookie file key:** `codeforces` (list of cookie dicts with playwright format)

**Cookie guard on save:** only saves if `X-User-Sha1` cookie present (NOT `X-User-Handle` — that cookie no longer exists). Verified 2026-03-07.

**Known issues:**
- CF has a custom Turnstile gate on `/enter`. It's a FULL PAGE redirect ("Verification"), not
  an embedded widget. It POSTs to `/data/turnstile` then reloads to show the actual login form.
  `page_action` is called by scrapling at page load, which may fire BEFORE the reload completes.
  Fix: add `page.wait_for_selector('input[name="handleOrEmail"]', timeout=60000)` as the FIRST
  line of every `login_action` that fills the CF login form.
- The same issue exists in BOTH `_login_headless_cf.login_action` and `_submit_headless.login_action`.
- The `check_login` on homepage uses `solve_cloudflare=True` (current diff). Verify this works.
- `needs_relogin` triggers if submit page redirects to `/enter` or `/login`.

**Submit page Turnstile:** The submit page (`/contest/{id}/submit`) has an EMBEDDED Turnstile
(not the full-page gate). `submit_action` correctly calls `_solve_turnstile(page)` for this.

**Cookie fast path for submit:**
- Load cookies → `StealthySession(cookies=saved_cookies)`
- If `_retried=False`: emit `checking_login`, fetch `/` with `solve_cloudflare=True`, check for "Logout"
- If not logged in: emit `logging_in`, fetch `/enter` with `solve_cloudflare=True` and `login_action`

**Test problem:** `:CP codeforces 2060` (recent educational round, has problems A-G)

**submit_action source injection:** uses `page.evaluate` to set CodeMirror + textarea directly.
This is correct — CF does not use file upload.

---

### AtCoder

**Credentials:** username=`barrettruth`, password=`vG\`kD)m31A8_`

**Cookie file key:** `atcoder` — BUT currently AtCoder NEVER saves cookies. Submit always
does a fresh full login. This is WRONG vs. Kattis model. Needs cookie fast path added.

**Current login flow:**
- `_login_headless`: Emits `logging_in`, does browser login, checks `/home` for "Sign Out".
  Does NOT save cookies. This means `:CP submit` always does full login (slow, wastes Turnstile solve).

**Current submit flow:**
- `_submit_headless`: Emits `logging_in` FIRST (no `checking_login`). Always does full browser login.
  No cookie fast path. This must change.

**Required submit flow (to match Kattis):**
```
emit checking_login
load_platform_cookies("atcoder")
if cookies:
    StealthySession(cookies=saved_cookies)
    check /home for "Sign Out"
    if not logged in: emit logging_in, do browser login
else:
    emit logging_in, do browser login (fresh StealthySession)
save cookies after login
emit submitting
do submit_action
if submit redirects to /login: clear cookies, retry once with full login
```

**Login flow must save cookies** so submit can use fast path.

**AtCoder Turnstile:** embedded in the login form itself (not a separate gate page).
`_solve_turnstile(page)` is called in `login_action` before filling fields. This is correct.
No `wait_for_selector` needed — the Turnstile is on the same page.

**Submit file upload:** uses `page.set_input_files("#input-open-file", {...buffer...})`.
In-memory buffer approach. Correct — no temp file needed.

**Submit nav timeout:** `BROWSER_SUBMIT_NAV_TIMEOUT["atcoder"]` currently = `BROWSER_NAV_TIMEOUT * 2` = 20s.
CLAUDE.md says it should be 40s (`* 4`). May need to increase if submit navigation is slow.

**Test problem:** `:CP atcoder abc394` (recent ABC, has problems A-G)

---

### CodeChef

**Credentials:** username=TBD, password=`pU5889'%c2IL`

**Cookie file key:** `codechef`

**Cookie guard on save:** saves any non-empty cookies — no meaningful guard. Should add one
(e.g., check for a session cookie name specific to CodeChef, or check logged_in state).

**Current login form selectors:** `input[name="name"]`, `input[name="pass"]`, `input.cc-login-btn`
These look like OLD Drupal-era selectors. Current CodeChef is React/Next.js. MUST VERIFY.
Use `headless=False` to see what the login page actually looks like.

**Current timeout:** 3000ms after clicking login button. Way too short for a React SPA navigation.

**No `solve_cloudflare`** on the login fetch. May or may not be needed. Verify with headless=False.

**`check_login` logic:** `"dashboard" in page.url or page.evaluate(_CC_CHECK_LOGIN_JS)`
where `_CC_CHECK_LOGIN_JS = "() => !!document.querySelector('a[href*=\"/users/\"]')"`.
Needs verification — does CC redirect to /dashboard after login? Does this selector exist?

**Submit flow:** has `PRACTICE_FALLBACK` logic — if contest says "not available for accepting
solutions", retries with `contest_id="PRACTICE"`. This is unique to CodeChef.

**Submit URL:** `/{contest_id}/submit/{problem_id}` or `/submit/{problem_id}` for PRACTICE.

**Submit selectors (need verification):**
- `[aria-haspopup="listbox"]` — language selector
- `[role="option"][data-value="{language_id}"]` — specific language option
- `.ace_editor` — code editor
- `#submit_btn` — submit button

**Test problem:** `:CP codechef START209` or similar recent Starters contest.

---

## Debugging Methodology

### Step-by-step for each issue

1. Identify the specific failure (wrong log, missing log, crash, wrong order)
2. Set `headless=False` to visually inspect what the browser shows
3. Run direct Python invocation to isolate from Neovim
4. Fix one thing at a time
5. Re-run ALL 5 test scenarios after each fix
6. Do NOT move to next platform until ALL 5 scenarios show correct logs

### When context runs low

Read this file first. Then read:
- `scrapers/kattis.py` — reference implementation
- `scrapers/<platform>.py` — current implementation being debugged
- `lua/cp/credentials.lua` — login Lua side
- `lua/cp/submit.lua` — submit Lua side

Current test status (update this section as work progresses):

| Scenario | Kattis | CF | AtCoder | CodeChef |
|---|---|---|---|---|
| login+logout+login | ✓ | ✓ | ? | ? |
| login+login | ✓ | ✓ | ? | ? |
| submit happy | ✓ | ✓ | ? | ? |
| bad cookie→submit | ✓ | ✓ | ? | ? |
| fresh→submit | ✓ | ✓ | ? | ? |

### CF confirmed log sequences

**login (no cookies):** `CodeForces: Logging in...` → `CodeForces login successful`
**login (valid cookies):** `CodeForces: Checking existing session...` → `CodeForces login successful`
**login (bad cookies):** `CodeForces: Checking existing session...` → `CodeForces: Logging in...` → `CodeForces login successful`
**submit happy:** `Checking login...` → `Submitting...` → `Submitted successfully`
**submit bad cookie:** `Checking login...` → `Logging in...` → `Submitting...` → `Submitted successfully`
**submit fresh:** `Checking login...` → `Logging in...` → `Submitting...` → `Submitted successfully`

Note: bad cookie and fresh start produce identical submit logs for CF (proactive check).
Kattis bad cookie is reactive (`Submitting...` before `Logging in...`). Issue #362 tracks alignment.

---

## Key Files

```
scrapers/base.py           — BaseScraper, cookie helpers, run_cli
scrapers/kattis.py         — REFERENCE IMPLEMENTATION
scrapers/codeforces.py     — browser scraper (CF Turnstile gate issue)
scrapers/atcoder.py        — browser scraper (_solve_turnstile, no cookie fast path)
scrapers/codechef.py       — browser scraper (selectors unverified)
scrapers/timeouts.py       — all timeout constants
lua/cp/scraper.lua         — run_scraper, ndjson event routing
lua/cp/credentials.lua     — login/logout commands
lua/cp/submit.lua          — submit command
lua/cp/cache.lua           — credential + cache storage
lua/cp/constants.lua       — COOKIE_FILE, PLATFORM_DISPLAY_NAMES
t/minimal_init.lua         — test Neovim config
```

---

## Open Questions (fill in as discovered)

- What are the actual CodeChef login form selectors on the current React site?
- Does CodeChef require `solve_cloudflare=True`?
- What is the correct CodeChef session cookie name to use as a guard?
- Does AtCoder cookie fast path work reliably (Cloudflare on /home without cookies)?
- What is the exact CodeChef username for credentials?
- Is `BROWSER_SUBMIT_NAV_TIMEOUT["atcoder"]` sufficient at 20s or does it need 40s?
