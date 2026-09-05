// Public config — the anon key is designed to be exposed client-side.
// Row Level Security on the database is what actually enforces access:
// - exam tables: anonymous INSERT allowed, SELECT blocked
// - only an authenticated admin session can SELECT results
const SUPABASE_URL = "https://wcrpzpumzismcyretfvx.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_H9XRabeXjUZYtLyB79UTSQ_2_4dIqPC";

// Public VAPID key only; never place the private VAPID key in this file.
// Set it after generating the key pair used by api/send-notification.js.
window.PUSH_VAPID_PUBLIC_KEY = window.PUSH_VAPID_PUBLIC_KEY || "";
