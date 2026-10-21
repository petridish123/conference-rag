-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create sentence_embeddings table
CREATE TABLE IF NOT EXISTS sentence_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    talk_id UUID NOT NULL,
    title TEXT NOT NULL,
    speaker TEXT,
    calling TEXT,
    year INTEGER,
    season TEXT,
    url TEXT,
    sentence_num INTEGER,
    text TEXT NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create index for talk_id grouping
CREATE INDEX IF NOT EXISTS sentence_embeddings_talk_id_idx 
ON sentence_embeddings(talk_id);

-- Enable Row Level Security
ALTER TABLE sentence_embeddings ENABLE ROW LEVEL SECURITY;

-- RLS policy: authenticated users can read
DROP POLICY IF EXISTS "Allow authenticated users to read" ON sentence_embeddings;
CREATE POLICY "Allow authenticated users to read"
ON sentence_embeddings FOR SELECT
TO authenticated
USING (true);

-- ============================================
-- Page Views table (PUBLIC access for RLS demo)
-- ============================================
-- This table intentionally has PUBLIC policies so students can
-- contrast it with sentence_embeddings (auth-only).

CREATE TABLE IF NOT EXISTS page_views (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visited_at TIMESTAMPTZ DEFAULT NOW(),
    page_url TEXT,
    user_agent TEXT
);

ALTER TABLE page_views ENABLE ROW LEVEL SECURITY;

-- Anyone (including unauthenticated visitors) can insert page views
DROP POLICY IF EXISTS "Allow public inserts" ON page_views;
CREATE POLICY "Allow public inserts"
ON page_views FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Anyone can read page views (for the counter)
DROP POLICY IF EXISTS "Allow public reads" ON page_views;
CREATE POLICY "Allow public reads"
ON page_views FOR SELECT
TO anon, authenticated
USING (true);

-- Create function for similarity search
CREATE OR REPLACE FUNCTION match_sentences(
  query_embedding vector(1536),
  match_count int DEFAULT 20
)
RETURNS TABLE (
  id uuid,
  talk_id uuid,
  title text,
  speaker text,
  text text,
  similarity float
)
LANGUAGE sql STABLE
AS $$
  SELECT
    sentence_embeddings.id,
    sentence_embeddings.talk_id,
    sentence_embeddings.title,
    sentence_embeddings.speaker,
    sentence_embeddings.text,
    1 - (sentence_embeddings.embedding <=> query_embedding) as similarity
  FROM sentence_embeddings
  ORDER BY sentence_embeddings.embedding <=> query_embedding
  LIMIT match_count;
$$;
