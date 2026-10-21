from supabase import create_client
import json

with open('config.public.json') as f:
    public = json.load(f)

# Connect with the publishable key (the current equivalent of the anon key).
client = create_client(public['SUPABASE_URL'], public['SUPABASE_PUBLISHABLE_KEY'])

# This should work because page_views has a public SELECT policy.
result = client.table('page_views').select('*').limit(5).execute()
print(f"page_views: {len(result.data)} rows")

# Without a signed-in user, RLS should prevent reading sentence_embeddings.
result = client.table('sentence_embeddings').select('*').limit(5).execute()
print(f"sentence_embeddings: {len(result.data)} rows (expected: 0)")
