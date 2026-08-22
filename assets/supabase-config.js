// Public config — the anon key is designed to be exposed client-side.
// Row Level Security on the database is what actually enforces access:
// - exam tables: anonymous INSERT allowed, SELECT blocked
// - only an authenticated admin session can SELECT results
const SUPABASE_URL = "https://wcrpzpumzismcyretfvx.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndjcnB6cHVtemlzbWN5cmV0ZnZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODczMjIxMTksImV4cCI6MjEwMjg5ODExOX0.Ec29Z[...]";
