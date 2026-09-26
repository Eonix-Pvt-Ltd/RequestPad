# Support replies — support@eonix.lk

Reply templates for the support inbox (`docs/RELEASE_RUNBOOK.md` §12).

**Targets:**
- First reply within **2 business days**.
- P1 reports (crash, data loss, a purchase not unlocking) the same business day.

**Rules for every reply:**
- Personalise it, and answer the actual question first.
- Never ask for passwords, tokens, API keys or request contents.
- If a user sends secrets anyway, tell them to rotate those credentials, and delete the email after the issue is
  resolved.
- Refunds are handled only by Apple; the developer cannot issue them.
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

## Pro isn't unlocked after purchase, or on a new device

> Thanks for purchasing RequestPad Pro! Pro unlocks on every iPhone, iPad and Mac signed in to the same Apple
> Account. If it isn't showing yet:
> 1. Open RequestPad → Settings → RequestPad Pro → Restore Purchases.
> 2. Make sure the device is signed in to the Apple Account used for the purchase (Settings → [your name] on iPhone
>    and iPad; App Store → Account on Mac).
> 3. If the purchase needed approval (Ask to Buy), Pro unlocks as soon as it is approved.
>
> If it still doesn't unlock, reply with the device and OS version and we'll investigate.

*Note:* Family Sharing is **not** enabled for RequestPad Pro (the products are not family-shareable), so family
members need their own purchase.

## Cancel a subscription

> You can cancel at any time; Pro stays active until the end of the period you've paid for.
> - iPhone or iPad: Settings → [your name] → Subscriptions → RequestPad Pro.
> - Mac: App Store → your account → Account Settings → Subscriptions → Manage.
> - Or in RequestPad: Settings → RequestPad Pro → Manage Subscription.
>
> Cancel at least 24 hours before the renewal date to avoid being charged for the next period.

## Refund request

> We're sorry RequestPad didn't work out for you. Purchases are processed by Apple, so refunds are requested
> directly from Apple at https://reportaproblem.apple.com. Sign in, find RequestPad, choose "Request a refund" and
> pick a reason. Apple usually replies within 48 hours.
>
> If something wasn't working, we'd really like to know what happened so we can fix it.

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

> RequestPad Pro opens Bruno collection folders directly: choose sidebar + → Open Collection Folder… and select the
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
