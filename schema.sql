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

-- Accelerate cosine-distance searches used by match_sentences().
CREATE INDEX IF NOT EXISTS sentence_embeddings_embedding_hnsw_idx
ON sentence_embeddings USING hnsw (embedding vector_cosine_ops);

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
  WHERE sentence_embeddings.embedding IS NOT NULL
  ORDER BY sentence_embeddings.embedding <=> query_embedding
  LIMIT match_count;
$$;

-- Similarity search for RAG that narrows results when the question
-- contains a speaker name stored in sentence_embeddings.speaker.
CREATE OR REPLACE FUNCTION match_sentences_by_question(
  query_embedding vector(1536),
  match_count int DEFAULT 20,
  question_text text DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  talk_id uuid,
  title text,
  speaker text,
  url text,
  text text,
  similarity float
)
LANGUAGE sql STABLE
AS $$
  WITH mentioned_speakers AS (
    SELECT DISTINCT se.speaker
    FROM sentence_embeddings AS se
    WHERE se.speaker IS NOT NULL
      AND btrim(se.speaker) <> ''
      AND question_text IS NOT NULL
      AND position(lower(btrim(se.speaker)) IN lower(question_text)) > 0
  )
  SELECT
    se.id,
    se.talk_id,
    se.title,
    se.speaker,
    se.url,
    se.text,
    1 - (se.embedding <=> query_embedding) AS similarity
  FROM sentence_embeddings AS se
  WHERE se.embedding IS NOT NULL
    AND (
      NOT EXISTS (SELECT 1 FROM mentioned_speakers)
      OR se.speaker IN (SELECT speaker FROM mentioned_speakers)
    )
  ORDER BY se.embedding <=> query_embedding
  LIMIT match_count;
$$;
