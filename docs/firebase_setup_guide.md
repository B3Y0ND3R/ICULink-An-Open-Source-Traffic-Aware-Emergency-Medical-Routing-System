# JoldiBed — Manual Firebase/Firestore Setup Guide

This guide covers everything that **must be done by hand** in the Firebase Console
and on your local machine before the new authentication/notifications features
will work. Nothing here can be automated by code — these are account, billing,
and console-level steps.

Do these **in order**. Steps 1–4 are needed before login/registration will work
at all. Step 5 is only needed later, once push notifications are being set up
(you'll be told explicitly when that's needed — skip it for now).

---

## 0. Get access to the Firebase project

The app is already wired to an existing Firebase project:
- **Project ID:** `joldibed`
- **Project number:** `952659446152`

You need to be added as a member of this project before you can change anything.
Ask whoever created the project to:
1. Go to [console.firebase.google.com](https://console.firebase.google.com/)
2. Open the **joldibed** project
3. Click the gear icon (⚙️) next to "Project Overview" → **Users and permissions**
4. Click **Add member**, enter your Google account email, give you the **Editor** role
5. Accept the invite email that arrives

Once you can open `console.firebase.google.com` and see **joldibed** in the project list, continue below.

---

## 1. Enable sign-in methods (Email/Password + Phone)

1. Open the **joldibed** project in the Firebase Console.
2. In the left sidebar, click **Build → Authentication**.
3. If this is the first time anyone has opened Authentication for this project, click **Get started**.
4. Go to the **Sign-in method** tab.
5. In the **Additional providers** list, click **Email/Password**.
   - Toggle **Enable** to ON.
   - Leave "Email link (passwordless sign-in)" OFF — not used.
   - Click **Save**.
6. Back on the Sign-in method tab, click **Phone**.
   - Toggle **Enable** to ON.
   - Click **Save**.

You should now see both **Email/Password** and **Phone** listed with status "Enabled" on the Sign-in method page.

---

## 2. Register your Android app's SHA fingerprints (needed for Phone sign-in)

Phone number sign-in on Android needs to verify the app is genuine using a SHA
certificate fingerprint. Without this, phone OTP sign-in will fail or fall back
to a reCAPTCHA web view.

### 2a. Get the debug SHA-1 and SHA-256 fingerprints

Open a terminal in the project's `android` folder and run:

**Windows (PowerShell):**
```powershell
cd D:\joldibed\android
.\gradlew signingReport
```

**Mac/Linux:**
```bash
cd /path/to/joldibed/android
./gradlew signingReport
```

Wait for it to finish (can take a minute). Scroll up in the output to find a
block that looks like this, under `Variant: debug`:

```
Variant: debug
Config: debug
Store: C:\Users\<you>\.android\debug.keystore
Alias: AndroidDebugKey
MD5: ...
SHA1: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
SHA-256: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
```

Copy the **SHA1** and **SHA-256** values (the long colon-separated hex strings).

### 2b. Add them to the Firebase Console

1. In the Firebase Console, click the gear icon (⚙️) → **Project settings**.
2. Scroll down to the **Your apps** section and find the Android app (package name `com.example.joldibed`).
3. Click **Add fingerprint**.
4. Paste the **SHA1** value, click **Save**.
5. Click **Add fingerprint** again, paste the **SHA-256** value, click **Save**.

### 2c. Re-download `google-services.json`

After adding fingerprints, the config file needs to be refreshed:
1. Still in **Project settings → Your apps → Android app**, click **google-services.json** to download the updated file.
2. Replace `D:\joldibed\android\app\google-services.json` with the newly downloaded file.

*(If you skip this step, the app will still build, but phone sign-in may not recognize the fingerprints until this file is refreshed.)*

---

## 3. Add test phone numbers (so you can test without real SMS)

Real SMS costs money and requires a real phone. For development, Firebase lets
you register fake phone numbers with a fixed OTP code that always works, no
SMS sent.

1. Firebase Console → **Build → Authentication → Sign-in method** tab.
2. Click **Phone** (you already enabled it in step 1).
3. Scroll down to **Phone numbers for testing (for development purposes)**.
4. Click **Add phone number**.
5. Enter a fake number, e.g. `+8801700000099`, and a fixed 6-digit code, e.g. `123456`.
6. Click **Add**. Repeat for 2–3 numbers if you want to test multiple accounts (e.g. one driver, one hospital staff).

When you sign in with `+8801700000099` in the app during testing, it will accept `123456` as the OTP without sending a real text.

---

## 4. Install the Firebase CLI and log in

This is needed later to deploy Firestore security rules (and eventually Cloud
Functions for push notifications). Install it now so it's ready.

1. Install [Node.js](https://nodejs.org/) (LTS version) if you don't already have it — the Firebase CLI runs on Node.
2. Open a terminal and run:
   ```
   npm install -g firebase-tools
   ```
3. Confirm it installed:
   ```
   firebase --version
   ```
4. Log in with the same Google account that has access to the `joldibed` project:
   ```
   firebase login
   ```
   This opens a browser window — sign in and approve access, then return to the terminal.
5. Confirm you can see the project:
   ```
   firebase projects:list
   ```
   You should see `joldibed` in the list.

**Do not run `firebase deploy` or `firebase init` yet** — that will happen once the security rules files exist in the repo (a later step, not part of this manual setup guide).

---

## 5. (Later — skip for now) Upgrade to the Blaze plan

This step is **only needed for push notifications** (Cloud Functions require it)
and is **not needed** for login, hospital management, or the core app to work.
You'll be told explicitly when it's time for this step — for now, skip it.

When the time comes:
1. Firebase Console → gear icon (⚙️) → **Usage and billing**.
2. Click **Modify plan** (or **Upgrade**) → select **Blaze (Pay as you go)**.
3. You'll need to attach a billing account/payment method. At this app's scale (a handful of users, a few notifications), actual usage cost is expected to be effectively $0/month, but Google requires billing to be enabled to use Cloud Functions at all, even within the free tier of included usage.

---

## Checklist summary

Before telling the team "setup is done," confirm:

- [ ] You (and your friend, if they're doing this) can log into `console.firebase.google.com` and see the **joldibed** project
- [ ] **Email/Password** shows "Enabled" under Authentication → Sign-in method
- [ ] **Phone** shows "Enabled" under Authentication → Sign-in method
- [ ] SHA-1 and SHA-256 fingerprints are listed under Project settings → Your apps → Android app
- [ ] `google-services.json` in `android/app/` has been re-downloaded after adding fingerprints
- [ ] At least one test phone number + fixed OTP code is registered
- [ ] `firebase --version` works in a terminal
- [ ] `firebase login` succeeded and `firebase projects:list` shows `joldibed`

Once all boxes are checked, the app's authentication code can be built and tested end-to-end.
