// Public config — the anon key is designed to be exposed client-side.
// Row Level Security on the database is what actually enforces access:
// - exam tables: anonymous INSERT allowed, SELECT blocked
// - only an authenticated admin session can SELECT results
const SUPABASE_URL = "https://wcrpzpumzismcyretfvx.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_H9XRabeXjUZYtLyB79UTSQ_2_4dIqPC";

// Public VAPID key only; never place the private VAPID key in this file.
// This is the same public key already used by the existing notification flow.
window.PUSH_VAPID_PUBLIC_KEY = window.PUSH_VAPID_PUBLIC_KEY || "BHR4AjTK5YFuR9MdG2hV9KVwgGxAfJgzPDQZnCCVBM-H4jGqq14whodFnVTZc4Ah7k6Y9QUM5BNyTCXcBj9rzGg";
