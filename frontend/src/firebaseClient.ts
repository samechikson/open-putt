import { initializeApp } from "firebase/app";
import { getAuth } from "firebase/auth";
import { getFirestore } from "firebase/firestore";

// Public Firebase web config. These values are safe to ship to the browser —
// access is governed by Firestore security rules (firestore.rules), which scope
// every read/write to the signed-in user (request.auth.uid == user_id). Values
// come from Vite build-time env (frontend/.env.local locally; injected by the
// deploy workflow in production).
const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY as string | undefined,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN as string | undefined,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID as string | undefined,
  appId: import.meta.env.VITE_FIREBASE_APP_ID as string | undefined,
  // Optional; present in the Firebase console config but not required here.
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET as
    | string
    | undefined,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID as
    | string
    | undefined,
};

if (
  !firebaseConfig.apiKey ||
  !firebaseConfig.authDomain ||
  !firebaseConfig.projectId ||
  !firebaseConfig.appId
) {
  throw new Error(
    "Missing Firebase config (VITE_FIREBASE_API_KEY / AUTH_DOMAIN / " +
      "PROJECT_ID / APP_ID). Set them in frontend/.env.local (dev) and the " +
      "deploy workflow env (prod).",
  );
}

export const firebaseApp = initializeApp(firebaseConfig);
export const auth = getAuth(firebaseApp);
// The web app reads and writes Firestore directly (not via a backend API); the
// hardware-gate ingest still goes through the backend's Admin SDK.
export const db = getFirestore(firebaseApp);

// The signed-in user's uid, used to scope every Firestore query. Waits for
// Firebase to finish restoring any persisted session first — on a cold page load
// `auth.currentUser` is briefly null while auth initializes. Throws when nobody
// is signed in (the app gates all data views behind auth, so this is a guard).
export async function currentUid(): Promise<string> {
  await auth.authStateReady();
  const user = auth.currentUser;
  if (!user) throw new Error("You're signed out. Sign in and try again.");
  return user.uid;
}
