# Support replies — support@eonix.lk

Reply templates for the support inbox (`docs/RELEASE_RUNBOOK.md` §12).

**Targets:**
- First reply within **2 business days**.
- P1 reports (crash, data loss) the same business day.

**Rules for every reply:**
- Personalise it, and answer the actual question first.
- Never ask for passwords, tokens, API keys or request contents.
- If a user sends secrets anyway, tell them to rotate those credentials, and delete the email after the issue is
  resolved.
- Check every statement against the current version before sending.

Log each conversation in one line under "Operations" in `docs/SDLC_LOG.md`: date, category, P-level, outcome — no
personal details. Recurring questions go into `SUPPORT.md` (FAQ) and the roadmap.

---

## Asking for details about a problem

> Thanks for getting in touch, and sorry for the trouble. So we can look into it, could you send:
> - your device (iPhone, iPad or Mac model), its OS version, and the RequestPad version (shown at the bottom of
>   Settings);
> - the steps that lead to the problem, and what you expected instead;
> - if possible, the diagnostics file from Settings → Support → Export Diagnostics. It contains no secrets, request
>   bodies, file contents or full URLs.
>
> Please don't include passwords, tokens or API keys.

## Is RequestPad free?

> Yes. RequestPad is free and every feature is included: unlimited collections, folder (`.bru`) collections,
> OpenAPI and Postman import, GraphQL, OAuth 2.0, the collection runner and more. There are no in-app purchases, no
> subscriptions and no ads.

## Plain `http://` request fails

> Apple's App Transport Security requires encrypted `https://` connections to internet hosts, so RequestPad can't
> send plain `http://` requests to public addresses. Plain `http://` does work for `localhost`, `.local` names and
> private network addresses (192.168.x.x, 10.x.x.x, 172.16–31.x.x). For a public server, please use `https://`.
> A local server reached through a DNS name such as `myserver.lan` also needs `https://`. Use its IP address or its
> `.local` name for plain `http://`.

## Request to a device on my network fails (iPhone or iPad)

> Requests to devices on your own network need the Local Network permission. On iPhone or iPad, open
> Settings → Privacy & Security → Local Network and turn on RequestPad, then try again. Requests to internet
> servers don't need it.

## Bruno collection or `.bru` file questions

> RequestPad opens Bruno collection folders directly: choose sidebar + → Open Collection Folder… and select the
> folder that contains `bruno.json`. RequestPad reads and writes the `.bru` files in place, so git keeps working.
> JavaScript in `.bru` files (scripts and tests) is kept unchanged but is not run: RequestPad has no script engine.
> Its assertions and extraction rules cover the most common uses.

*If a specific file doesn't open:* ask for a copy with secrets removed. Check it against `BruRequestCodec`, add it as
a fixture test, and fix it in the next 1.0.x release.

## Feature request

> Thanks for the suggestion! We've added it to our list for future versions. We can't promise dates, but requests
> like yours decide what we build next.

*Then:* add it to the roadmap table in `docs/RELEASE_RUNBOOK.md` §14 with a count, or bump its count.

## Bug confirmed, fix coming

> Thank you — we've reproduced the problem and a fix is on its way in the next update (RequestPad [version]). Until
> then, [workaround if any]. We'll let you know when it's available.

*Then:* follow the hotfix path (`docs/RELEASE_RUNBOOK.md` §11) for P1 issues; otherwise plan it for the next
release. Reply again when it ships.

## Security report

> Thank you for reporting this responsibly. We've received your report and will follow up with our assessment.
> Confirmed high-severity issues are fixed within 14 days. Please keep the details private until a fix is released;
> we're happy to credit you.

*Then:* this reply is the acknowledgement `SECURITY.md` promises within 2 business days. Follow `SECURITY.md`.
