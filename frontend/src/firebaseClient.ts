import { initializeApp } from "firebase/app";
import { getAuth } from "firebase/auth";

// Public Firebase web config. Like the Supabase anon key before it, these values
// are safe to ship to the browser — access is governed server-side (the backend
// verifies Firebase ID tokens). Values come from Vite build-time env
// (frontend/.env.local locally; injected by the deploy workflow in production).
const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY as string | undefined,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN as string | undefined,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID as string | undefined,
  appId: import.meta.env.VITE_FIREBASE_APP_ID as string | undefined,
  // Optional; present in the Firebase console config but not required for Auth.
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
