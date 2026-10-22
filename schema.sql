-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create sentence_embeddings table
CREATE TABLE IF NOT EXISTS sentence_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    talk_id UUID NOT NULL,
    title TEXT NOT NULL,
    speaker TEXT,
    first_name TEXT,
    middle_name TEXT,
    last_name TEXT,
    calling TEXT,
    year INTEGER,
    season TEXT,
    url TEXT,
    sentence_num INTEGER,
    text TEXT NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add the name columns to existing installations too.
ALTER TABLE sentence_embeddings ADD COLUMN IF NOT EXISTS first_name TEXT;
ALTER TABLE sentence_embeddings ADD COLUMN IF NOT EXISTS middle_name TEXT;
ALTER TABLE sentence_embeddings ADD COLUMN IF NOT EXISTS last_name TEXT;

-- Backfill existing rows from the scraped speaker label. This lets the
-- speaker filter work before the data is imported again.
WITH cleaned_speakers AS (
    SELECT
        id,
        regexp_replace(
            regexp_replace(btrim(speaker), ',?\s+(Jr|Sr|II|III|IV)\.?$', '', 'i'),
            '^(President|Elder|Sister|Brother|Bishop|Apostle|Seventy)\s+',
            '',
            'i'
        ) AS cleaned_name
    FROM sentence_embeddings
    WHERE speaker IS NOT NULL
      AND first_name IS NULL
),
name_parts AS (
    SELECT id, regexp_split_to_array(btrim(cleaned_name), '\s+') AS parts
    FROM cleaned_speakers
),
parsed_speakers AS (
    SELECT
        id,
        parts[1] AS first_name,
        CASE WHEN cardinality(parts) > 2
             THEN array_to_string(parts[2:cardinality(parts) - 1], ' ')
             ELSE NULL
        END AS middle_name,
        regexp_replace(parts[cardinality(parts)], '\.$', '') AS last_name
    FROM name_parts
    WHERE cardinality(parts) >= 2
)
UPDATE sentence_embeddings AS se
SET first_name = parsed.first_name,
    middle_name = parsed.middle_name,
    last_name = parsed.last_name
FROM parsed_speakers AS parsed
WHERE se.id = parsed.id;

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
-- contains a speaker's first and last names. Middle names are ignored.
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
  WITH question_words AS (
    SELECT lower(regexp_replace(word, '\.$', '')) AS word
    FROM regexp_split_to_table(
      coalesce(question_text, ''),
      '[^[:alnum:]''’_-]+'
    ) AS question_word(word)
  ),
  mentioned_speakers AS (
    SELECT DISTINCT se.first_name, se.last_name
    FROM sentence_embeddings AS se
    WHERE se.first_name IS NOT NULL
      AND se.last_name IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM question_words
        WHERE question_words.word = lower(regexp_replace(btrim(se.first_name), '\.$', ''))
      )
      AND EXISTS (
        SELECT 1 FROM question_words
        WHERE question_words.word = lower(regexp_replace(btrim(se.last_name), '\.$', ''))
      )
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
      OR EXISTS (
        SELECT 1
        FROM mentioned_speakers AS ms
        WHERE ms.first_name = se.first_name
          AND ms.last_name = se.last_name
      )
    )
  ORDER BY se.embedding <=> query_embedding
  LIMIT match_count;
$$;

-- Resolve exactly which stored speaker names appear in a question.
-- The client uses this first so it can skip embedding/search when no name
-- is present, or ask for clarification if several speakers match.
CREATE OR REPLACE FUNCTION find_speakers_in_question(question_text text)
RETURNS TABLE (
  first_name text,
  middle_name text,
  last_name text,
  speaker text
)
LANGUAGE sql STABLE
AS $$
  WITH question_words AS (
    SELECT lower(regexp_replace(word, '\.$', '')) AS word
    FROM regexp_split_to_table(
      coalesce(question_text, ''),
      '[^[:alnum:]''’_-]+'
    ) AS question_word(word)
  )
  SELECT DISTINCT se.first_name, se.middle_name, se.last_name, se.speaker
  FROM sentence_embeddings AS se
  WHERE se.first_name IS NOT NULL
    AND se.last_name IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM question_words
      WHERE question_words.word = lower(regexp_replace(btrim(se.first_name), '\.$', ''))
    )
    AND EXISTS (
      SELECT 1 FROM question_words
      WHERE question_words.word = lower(regexp_replace(btrim(se.last_name), '\.$', ''))
    );
$$;

-- Strict vector search for a resolved speaker. Unlike the general RAG
-- function, this never falls back to results from other speakers.
CREATE OR REPLACE FUNCTION match_sentences_for_speaker(
  query_embedding vector(1536),
  match_count int,
  speaker_first_name text,
  speaker_last_name text
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
    AND lower(btrim(se.first_name)) = lower(btrim(speaker_first_name))
    AND lower(btrim(se.last_name)) = lower(btrim(speaker_last_name))
  ORDER BY se.embedding <=> query_embedding
  LIMIT match_count;
$$;
