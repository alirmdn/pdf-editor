"""List this app's uploads and builds in App Store Connect, with Apple's processing state and
errors, as annotations on the workflow run. Reads ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 and
BUNDLE_ID from the environment."""
import json, os, time, urllib.request, urllib.error
import jwt

key_id, issuer, p8, bundle = (os.environ[k] for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "BUNDLE_ID"))
now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, p8, algorithm="ES256", headers={"kid": key_id})

def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode()[:1500]}

def say(level, msg):
    print(f"::{level}::{msg}".replace("\n", " "))

apps = get(f"/v1/apps?filter[bundleId]={bundle}")
if "http_error" in apps:
    say("error", f"apps: HTTP {apps['http_error']} {apps['body']}")
    raise SystemExit(1)
if not apps.get("data"):
    say("error", f"No App Store Connect app has the bundle ID {bundle}")
    raise SystemExit(1)
app = apps["data"][0]
say("notice", f"App {app['attributes'].get('name')} (id {app['id']}, bundle {app['attributes'].get('bundleId')})")

ups = get(f"/v1/apps/{app['id']}/buildUploads?limit=20")
if "http_error" in ups:
    say("warning", f"buildUploads: HTTP {ups['http_error']} {ups['body']}")
else:
    for u in ups.get("data", []):
        a = u["attributes"]
        say("notice", "upload " + json.dumps({k: a.get(k) for k in ("cfBundleVersion", "cfBundleShortVersionString", "state", "createdDate")}))
        st = a.get("state") or {}
        for kind in ("errors", "warnings", "infos"):
            for item in (st.get(kind) or []) if isinstance(st, dict) else []:
                say("error" if kind == "errors" else "warning", f"upload {a.get('cfBundleVersion')}: {item.get('code')} {item.get('description')}")

builds = get(f"/v1/builds?filter[app]={app['id']}&limit=20&sort=-uploadedDate")
if "http_error" in builds:
    say("warning", f"builds: HTTP {builds['http_error']} {builds['body']}")
else:
    if not builds.get("data"):
        say("warning", "No builds are listed for this app")
    for b in builds.get("data", []):
        a = b["attributes"]
        say("notice", "build " + json.dumps({k: a.get(k) for k in ("version", "processingState", "uploadedDate", "expired")}))
