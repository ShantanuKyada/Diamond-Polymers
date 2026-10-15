# Signing the APK, so updates install over the old build

## The problem this solves

Installing a new build over an existing one failed with:

> App not installed as package conflicts with an existing package.

Uninstalling first and then installing worked. That combination is the signature
of a **signature mismatch**, not a version problem.

Android will only let an APK replace an installed one when both are signed with
the **same key**. The Flutter project template signs release builds with the
*debug* key:

```kotlin
buildTypes {
    release {
        // TODO: Add your own signing config for the release build.
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

and a debug keystore is generated per machine, on first use. Every GitHub
Actions run is a brand-new machine, so **every build was signed with a different
key**. Each APK was therefore a stranger to the one already on the phone.

This was a defect in how the app was shipped, present since the first CI build.

## The fix

`android/app/build.gradle.kts` now reads `android/key.properties`, and signs
release builds with the key it names. CI writes that file from repository
secrets. Neither the keystore nor the passwords go anywhere near the repository
— `.gitignore` already excludes `key.properties`, `*.jks` and `*.keystore`.

Without a key the build still works and falls back to the debug key, so
`flutter run --release` is unaffected on a developer machine. CI warns when that
happens and names the artifact `…-UNSIGNED-fresh-install-only`, so an APK that
cannot update an installed one says so before it reaches a phone.

---

## One-time setup

### 1. Create the keystore

On your machine, with the JDK that Android Studio or Flutter installed:

```bash
keytool -genkey -v -keystore diamond-polymers.jks -keyalg RSA -keysize 2048 -validity 10000 -alias diamond
```

It asks for a password, then some name and address fields. The fields do not
matter for an app distributed by hand; the password does.

> **Keep this file and its password safe, and back them up somewhere other than
> the machine that made them.**
>
> Every future update has to be signed with this exact key. If it is lost, the
> only way to install a new build is to uninstall the old one on every phone —
> which is the problem you are reading this to fix. There is no recovery and no
> reset.

### 2. Turn it into one line of text

```bash
base64 -w 0 diamond-polymers.jks > keystore.base64.txt
```

On Windows PowerShell:

```bash
[Convert]::ToBase64String([IO.File]::ReadAllBytes("diamond-polymers.jks")) | Out-File -Encoding ascii keystore.base64.txt
```

### 3. Add four repository secrets

GitHub → the repository → **Settings → Secrets and variables → Actions → New
repository secret**. Add these four:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the whole contents of `keystore.base64.txt` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password from step 1 |
| `ANDROID_KEY_ALIAS` | `diamond` (the `-alias` from step 1) |
| `ANDROID_KEY_PASSWORD` | the key password — the same as the keystore password unless you set a different one |

Then delete `keystore.base64.txt`. Keep the `.jks` itself backed up.

### 4. Build once more

Run the **Build APK** workflow. The artifact should be named
`diamond-polymers-<sha>` with no `UNSIGNED` on the end.

---

## The one unavoidable uninstall

Every build handed out so far was signed with a throwaway key, so **the first
properly signed build still cannot install over them.** Uninstall the app once
on each phone, install the new one, and every update after that works normally.

The app keeps nothing on the phone — profiles, entries, payroll and stock all
live in Supabase — so uninstalling loses only the login, which is one screen to
redo.

---

## While you are in the secrets screen

Adding `SUPABASE_URL` and `SUPABASE_ANON_KEY` at the same time would be worth
it. Without them the workflow refuses to build on a push, which is why every
commit shows a red cross in GitHub and why the APK has to be triggered by hand
with the values pasted in each time.

| Secret | Value |
|---|---|
| `SUPABASE_URL` | `https://rlldysoukevcumhmtmdm.supabase.co` |
| `SUPABASE_ANON_KEY` | the publishable key — the one that already ships inside the APK, not the service-role key |

The service-role key must never be added here, or anywhere else that reaches the
app: it bypasses every row level security policy in the database.
