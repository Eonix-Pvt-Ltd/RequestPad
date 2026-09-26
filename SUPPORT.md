# RequestPad Support

_Published at https://requestpad.eonix.lk/support._

Email **support@eonix.lk**. We reply within two business days.

When reporting a problem, please include your device, OS version and RequestPad version (shown at the bottom of Settings). If
asked, attach the file from Settings → Export Diagnostics — it contains no secrets, request bodies or file contents.

## FAQ

**Do I need an account?** No. RequestPad has no sign-in, and nothing you create is uploaded anywhere.

**Why does a plain `http://` request to a public website fail?** Apple's App Transport Security requires encrypted
`https://` connections to internet hosts. Plain `http://` works for `localhost`, `.local` names, and private network
addresses (such as 192.168.x.x or 10.x.x.x). Use `https://` for public servers.

**Can I use my Bruno collections?** Yes, with RequestPad Pro: choose Open Collection Folder and select the folder
containing `bruno.json`. RequestPad reads and writes the `.bru` files there, so you can keep using git. JavaScript
scripts in `.bru` files are preserved but not run.

**Where are my secrets stored?** In your device's Keychain. Secret variables are never written to `.bru` files,
exports or history.

**How do I try RequestPad without a server?** Settings → Try It Out → Load Sample Data starts Local Echo, a test
server inside the app, and creates a sample collection that targets it.

**How do I restore my purchase on a new device?** Open the paywall or Settings and tap Restore Purchases.

**How do I cancel my subscription?** iPhone/iPad: Settings → Apple Account → Subscriptions. Mac: App Store →
Account → Subscriptions. RequestPad's Settings also has a Manage Subscription button.

**How do I delete my data?** Settings → Erase All Data. Folder collections are your files and are left in place.
