# Regression checks

Run the dependency-free worker and typing-presence checks with Node 22 or later:

```sh
node --test tests/worker.test.mjs
```

To include real HTTP checks, start the local Postman simulation in one terminal:

```sh
/Users/aisu/.local/bin/postman simulation run postman/simulations/regression.sim.yaml --port 4499 --output ndjson --no-history
```

Then run:

```sh
SIMULATION_URL=http://127.0.0.1:4499 node --test tests/worker.test.mjs
```

The simulation fixtures follow the agent-messaging 2.1.0 OpenAPI schemas used by
this app (available in the sibling `cf-agent-messaging/worker/api/openapi.yaml`
checkout). A published owner mock could not be discovered because the search
API was unreachable. These local fixtures cover only the exercised endpoints;
unmodeled calls return 501. The `fault-*` bearer suffixes are synthetic failure
cases, and all mailbox identities and tokens are test data. No real service or
credentials are used.

The HTTP checks run the actual Worker handler with a service-binding adapter
that sends native fetch requests to the simulation. TypingPresence state and
socket callbacks are tested in memory. These checks do not replace deployment
verification in the Cloudflare runtime or testing focus zoom on a physical iOS
device.

## Keyboard viewport layout

With Playwright and its Chromium browser installed, run:

```sh
node tests/viewport.browser.mjs
```

`PLAYWRIGHT_MODULE` can point to an existing Playwright module, and
`CHROME_EXECUTABLE` can select a locally installed Chrome binary. This test serves
only static files, without credentials or an API dependency. It simulates Safari's
visual viewport resize and pan events while retaining the full layout viewport.
It checks sidebar fields, header and composer visibility, message scroll position,
keyboard dismissal, landscape, and preservation of native pinch zoom. It also
simulates Safari's Page Zoom measurements at 50%, 75%, 85%, 100%, and 125%, checking
that text controls remain at least 16 screen points.

To check continuous composer focus during sends, run the Postman simulation above,
then:

```sh
SIMULATION_URL=http://127.0.0.1:4499 node tests/composer.browser.mjs
```

This runs the UI and actual Worker proxy against the local HTTP fixture. It checks
touch and Enter submission, editability during pending requests, preservation of
new drafts, deliberate focus changes, and failed sends. It also checks overlapping
incoming/outgoing mailbox IDs, retained history, and immediate visibility after
repeated sends in a long conversation. The browser uses the same
optional `PLAYWRIGHT_MODULE` and `CHROME_EXECUTABLE` settings. Physical Safari
keyboard behavior and device-specific viewport reporting remain unverified.

## Full non-iOS audit checks

The browser audit covers exact send recovery across refresh, message DOM stability,
foreground/background polling, new conversation threads and final-summary replies,
storage failures, expired tokens, modal dismissal, admin login/detail races, and
unsaved registry edits:

```sh
SIMULATION_URL=http://127.0.0.1:4499 node tests/audit.browser.mjs
```

Python state checks run without dependencies. Set `SIMULATION_URL` to include real
HTTP tests for inbox acknowledgement, outgoing recovery, redirects, and bridge
restart without regenerating a saved reply:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
SIMULATION_URL=http://127.0.0.1:4499 python3 -m unittest discover -s tests -p 'test_*.py'
```

Run HTTP suites sequentially against the shared simulation: audit and Python checks
reset its synthetic state through `/simulation/*`. Those control endpoints exist
only in the local fixture. The browser audit uses the same optional Playwright and
Chrome settings as the other browser scripts. `AUDIT_SCREENSHOT` and
`COMPOSER_SCREENSHOT` can capture optional visual QA images from their respective
browser suites.
