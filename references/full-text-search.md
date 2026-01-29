# Full-Text Search Patterns

This document covers PostgreSQL's built-in full-text search capabilities, including tsvector/tsquery design, indexing strategies, ranking, and multi-language support.

## Table of Contents

1. [Overview](#overview)
2. [Core Concepts](#core-concepts)
3. [Schema Design for FTS](#schema-design-for-fts)
4. [Indexing Strategies](#indexing-strategies)
5. [Query Patterns](#query-patterns)
6. [Search Ranking](#search-ranking)
7. [Multi-Language Support](#multi-language-support)
8. [Advanced Patterns](#advanced-patterns)
9. [Performance Optimization](#performance-optimization)

## Overview

### When to Use PostgreSQL FTS

| Use Case | PostgreSQL FTS | External Search (Elasticsearch) |
|----------|----------------|--------------------------------|
| Simple text search | ✅ Excellent | Overkill |
| Blog/CMS content | ✅ Good | Good |
| Product search | ✅ Good | Better for facets |
| Log analysis | ⚠️ Limited | ✅ Better |
| Real-time search | ✅ Good | ✅ Good |
| Fuzzy matching | ⚠️ pg_trgm addon | ✅ Built-in |
| Multi-language | ✅ Good | ✅ Better |
| Operational complexity | ✅ None (built-in) | ❌ High |

### FTS vs LIKE/ILIKE

```sql
-- BAD: LIKE with wildcards - cannot use B-tree index
SELECT * FROM data.articles WHERE title ILIKE '%postgresql%';

-- GOOD: Full-text search - uses GIN index
SELECT * FROM data.articles
WHERE to_tsvector('english', title) @@ to_tsquery('english', 'postgresql');
```

## Core Concepts

### tsvector - Document Representation

```sql
-- tsvector: normalized document representation
SELECT to_tsvector('english', 'The quick brown foxes jumped over the lazy dogs');
-- Result: 'brown':3 'dog':9 'fox':4 'jump':5 'lazi':8 'quick':2

-- Features:
-- - Lowercased
-- - Stop words removed ('the', 'over')
-- - Stemmed ('foxes' → 'fox', 'jumped' → 'jump')
-- - Position information stored
```

### tsquery - Search Query

```sql
-- Basic query
SELECT to_tsquery('english', 'quick & brown');
-- Result: 'quick' & 'brown'

-- Query operators:
-- &  AND
-- |  OR
-- !  NOT
-- <-> FOLLOWED BY (phrase)
-- <N> FOLLOWED BY within N words

-- Phrase search
SELECT to_tsquery('english', 'quick <-> brown');
-- Result: 'quick' <-> 'brown' (must be adjacent)

-- Proximity search
SELECT to_tsquery('english', 'quick <2> fox');
-- Result: 'quick' <2> 'fox' (within 2 words)
```

### Match Operator (@@)

```sql
-- Check if document matches query
SELECT to_tsvector('english', 'The quick brown fox')
    @@ to_tsquery('english', 'quick & fox');
-- Result: true

SELECT to_tsvector('english', 'The quick brown fox')
    @@ to_tsquery('english', 'quick & cat');
-- Result: false
```

## Schema Design for FTS

### Option 1: Computed Column (Recommended)

```sql
-- Store precomputed tsvector as generated column
CREATE TABLE data.articles (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    title           text NOT NULL,
    body            text NOT NULL,
    author_id       uuid NOT NULL REFERENCES data.users(id),

    -- Generated tsvector column (stored)
    search_vector   tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(body, '')), 'B')
    ) STORED,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- GIN index on the tsvector column
CREATE INDEX articles_search_idx ON data.articles USING gin(search_vector);
```

### Option 2: Trigger-Maintained Column

```sql
-- For more complex logic or PostgreSQL < 12
CREATE TABLE data.products (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    name            text NOT NULL,
    description     text,
    category        text NOT NULL,
    tags            text[],
    search_vector   tsvector,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Trigger to maintain search vector
CREATE FUNCTION private.products_search_vector_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.category, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.tags, ' '), '')), 'C');
    RETURN NEW;
END;
$$;

CREATE TRIGGER products_search_vector_trg
    BEFORE INSERT OR UPDATE OF name, description, category, tags
    ON data.products
    FOR EACH ROW
    EXECUTE FUNCTION private.products_search_vector_trigger();

CREATE INDEX products_search_idx ON data.products USING gin(search_vector);
```

### Option 3: On-the-Fly (Simple Cases)

```sql
-- No stored vector - compute at query time
-- Only suitable for small tables or infrequent searches
CREATE TABLE data.notes (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    content     text NOT NULL,
    user_id     uuid NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Expression index (computed at index time, not stored in table)
CREATE INDEX notes_content_search_idx
    ON data.notes USING gin(to_tsvector('english', content));

-- Query must match index expression exactly
SELECT * FROM data.notes
WHERE to_tsvector('english', content) @@ to_tsquery('english', 'search & term');
```

## Indexing Strategies

### GIN Index (Recommended)

```sql
-- Standard GIN index for full-text search
CREATE INDEX articles_search_idx ON data.articles USING gin(search_vector);

-- Pros:
-- - Fast lookups
-- - Efficient for many unique terms
-- - Good for read-heavy workloads

-- Cons:
-- - Slower index updates than GiST
-- - Larger index size
```

### GiST Index (Alternative)

```sql
-- GiST index - faster updates, slower lookups
CREATE INDEX articles_search_gist_idx ON data.articles USING gist(search_vector);

-- Use when:
-- - Write-heavy workload
-- - Smaller document corpus
-- - Combined with geometric/range queries
```

### Partial Index for Common Filters

```sql
-- Index only published articles
CREATE INDEX articles_search_published_idx
    ON data.articles USING gin(search_vector)
    WHERE status = 'published';

-- Smaller index, faster queries for common case
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql')
  AND status = 'published';
```

### Multi-Column Index

```sql
-- Combine FTS with other filters
CREATE INDEX articles_author_search_idx
    ON data.articles USING gin(author_id, search_vector);

-- Efficient for: WHERE author_id = X AND search_vector @@ query
```

## Query Patterns

### Basic Search

```sql
-- Simple word search
SELECT id, title, ts_headline('english', body, q) AS snippet
FROM data.articles, to_tsquery('english', 'postgresql') AS q
WHERE search_vector @@ q
ORDER BY ts_rank(search_vector, q) DESC
LIMIT 20;
```

### Phrase Search

```sql
-- Exact phrase: words must be adjacent
SELECT * FROM data.articles
WHERE search_vector @@ phraseto_tsquery('english', 'database optimization');

-- Equivalent to:
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'database <-> optimization');
```

### Boolean Operators

```sql
-- AND: both terms required
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql & performance');

-- OR: either term
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql | mysql');

-- NOT: exclude term
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql & !mysql');

-- Complex boolean
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', '(postgresql | postgres) & (performance | optimization) & !beginner');
```

### Prefix Search

```sql
-- Prefix matching with :*
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postg:*');
-- Matches: postgresql, postgres, postgis, etc.

-- Combine with other terms
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postg:* & index:*');
```

### Web-Style Search Input

```sql
-- Convert user input to tsquery
-- websearch_to_tsquery handles quotes, -, OR naturally

SELECT * FROM data.articles
WHERE search_vector @@ websearch_to_tsquery('english', 'postgresql "query optimization" -beginner');
-- Interprets as: postgresql AND "query optimization" AND NOT beginner

-- User-friendly search function
CREATE FUNCTION api.search_articles(in_query text, in_limit integer DEFAULT 20)
RETURNS TABLE (
    id uuid,
    title text,
    snippet text,
    rank real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT
        a.id,
        a.title,
        ts_headline('english', a.body, q, 'MaxFragments=2, MaxWords=30') AS snippet,
        ts_rank(a.search_vector, q) AS rank
    FROM data.articles a,
         websearch_to_tsquery('english', in_query) AS q
    WHERE a.search_vector @@ q
      AND a.status = 'published'
    ORDER BY ts_rank(a.search_vector, q) DESC
    LIMIT in_limit;
$$;
```

### Combining FTS with Other Filters

```sql
-- FTS with category filter
SELECT * FROM data.articles
WHERE search_vector @@ websearch_to_tsquery('english', 'postgresql')
  AND category = 'tutorials'
  AND created_at > now() - interval '1 year'
ORDER BY ts_rank(search_vector, websearch_to_tsquery('english', 'postgresql')) DESC
LIMIT 20;

-- FTS with pagination (keyset)
SELECT id, title, ts_rank(search_vector, q) AS rank
FROM data.articles, websearch_to_tsquery('english', 'postgresql') AS q
WHERE search_vector @@ q
  AND (ts_rank(search_vector, q), id) < (0.5, 'last-seen-uuid')
ORDER BY ts_rank(search_vector, q) DESC, id DESC
LIMIT 20;
```

## Search Ranking

### ts_rank - Basic Ranking

```sql
-- ts_rank: considers term frequency
SELECT
    title,
    ts_rank(search_vector, query) AS rank
FROM data.articles,
     to_tsquery('english', 'postgresql & performance') AS query
WHERE search_vector @@ query
ORDER BY rank DESC;

-- Normalization options (bitmask):
-- 0: default
-- 1: divide by 1 + log(document length)
-- 2: divide by document length
-- 4: divide by mean harmonic distance between extents
-- 8: divide by number of unique words
-- 16: divide by 1 + log(unique words)
-- 32: divide by itself + 1

SELECT ts_rank(search_vector, query, 1|4) AS normalized_rank
FROM data.articles, to_tsquery('english', 'postgresql') AS query
WHERE search_vector @@ query;
```

### ts_rank_cd - Cover Density Ranking

```sql
-- ts_rank_cd: considers proximity of matching terms
-- Better for phrase-like queries
SELECT
    title,
    ts_rank_cd(search_vector, query) AS rank
FROM data.articles,
     to_tsquery('english', 'postgresql & performance & tuning') AS query
WHERE search_vector @@ query
ORDER BY rank DESC;
```

### Weighted Ranking

```sql
-- Weights for A, B, C, D categories (default: {0.1, 0.2, 0.4, 1.0})
SELECT
    title,
    ts_rank(search_vector, query, '{0.1, 0.2, 0.4, 1.0}') AS rank
FROM data.articles,
     to_tsquery('english', 'postgresql') AS query
WHERE search_vector @@ query
ORDER BY rank DESC;

-- Custom weights: prioritize title (A) and category (C)
SELECT
    title,
    ts_rank(search_vector, query, '{1.0, 0.4, 0.8, 0.1}') AS rank
FROM data.articles,
     to_tsquery('english', 'postgresql') AS query
WHERE search_vector @@ query
ORDER BY rank DESC;
```

### Combined Ranking with Other Factors

```sql
-- Combine FTS rank with recency
SELECT
    id,
    title,
    ts_rank(search_vector, query) *
        (1 + 1.0 / (extract(epoch from now() - created_at) / 86400 + 1)) AS combined_rank
FROM data.articles,
     to_tsquery('english', 'postgresql') AS query
WHERE search_vector @@ query
ORDER BY combined_rank DESC;

-- Boost by view count
SELECT
    id,
    title,
    ts_rank(search_vector, query) * (1 + ln(view_count + 1) * 0.1) AS boosted_rank
FROM data.articles,
     to_tsquery('english', 'postgresql') AS query
WHERE search_vector @@ query
ORDER BY boosted_rank DESC;
```

## Multi-Language Support

### Available Dictionaries

```sql
-- List available text search configurations
SELECT cfgname FROM pg_ts_config;
-- simple, danish, dutch, english, finnish, french, german, hungarian,
-- italian, norwegian, portuguese, romanian, russian, spanish, swedish, turkish

-- Check default configuration
SHOW default_text_search_config;
```

### Language-Specific Search

```sql
-- Create table with language column
CREATE TABLE data.content (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    title       text NOT NULL,
    body        text NOT NULL,
    language    text NOT NULL DEFAULT 'english',
    search_vector tsvector,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Dynamic language trigger
CREATE FUNCTION private.content_search_vector_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    l_config regconfig;
BEGIN
    -- Map language to config (with fallback)
    l_config := CASE NEW.language
        WHEN 'en' THEN 'english'::regconfig
        WHEN 'de' THEN 'german'::regconfig
        WHEN 'fr' THEN 'french'::regconfig
        WHEN 'es' THEN 'spanish'::regconfig
        ELSE 'simple'::regconfig
    END;

    NEW.search_vector :=
        setweight(to_tsvector(l_config, coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector(l_config, coalesce(NEW.body, '')), 'B');

    RETURN NEW;
END;
$$;

CREATE TRIGGER content_search_trg
    BEFORE INSERT OR UPDATE OF title, body, language
    ON data.content
    FOR EACH ROW
    EXECUTE FUNCTION private.content_search_vector_trigger();
```

### Multi-Language Search Function

```sql
CREATE FUNCTION api.search_content(
    in_query text,
    in_language text DEFAULT 'english',
    in_limit integer DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    title text,
    snippet text,
    rank real
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_config regconfig;
BEGIN
    l_config := CASE in_language
        WHEN 'en' THEN 'english'::regconfig
        WHEN 'de' THEN 'german'::regconfig
        WHEN 'fr' THEN 'french'::regconfig
        WHEN 'es' THEN 'spanish'::regconfig
        ELSE 'simple'::regconfig
    END;

    RETURN QUERY
    SELECT
        c.id,
        c.title,
        ts_headline(l_config, c.body, websearch_to_tsquery(l_config, in_query)) AS snippet,
        ts_rank(c.search_vector, websearch_to_tsquery(l_config, in_query)) AS rank
    FROM data.content c
    WHERE c.search_vector @@ websearch_to_tsquery(l_config, in_query)
      AND c.language = in_language
    ORDER BY ts_rank(c.search_vector, websearch_to_tsquery(l_config, in_query)) DESC
    LIMIT in_limit;
END;
$$;
```

### Unaccented Search

```sql
-- Install unaccent extension
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Create custom text search configuration with unaccent
CREATE TEXT SEARCH CONFIGURATION french_unaccent (COPY = french);
ALTER TEXT SEARCH CONFIGURATION french_unaccent
    ALTER MAPPING FOR hword, hword_part, word
    WITH unaccent, french_stem;

-- Now "café" matches "cafe"
SELECT to_tsvector('french_unaccent', 'Le café est délicieux');
-- 'cafe':2 'delicieux':4

SELECT to_tsvector('french_unaccent', 'Le café est délicieux')
    @@ to_tsquery('french_unaccent', 'cafe');
-- true
```

## Advanced Patterns

### Highlighting Search Results

```sql
-- ts_headline: generate highlighted snippets
SELECT
    title,
    ts_headline(
        'english',
        body,
        to_tsquery('english', 'postgresql & performance'),
        'StartSel=<mark>, StopSel=</mark>, MaxFragments=3, MaxWords=30, MinWords=10'
    ) AS highlighted_snippet
FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql & performance');

-- Options:
-- StartSel, StopSel: highlight markers
-- MaxFragments: max number of fragments (0 = entire field)
-- MaxWords: max words per fragment
-- MinWords: min words per fragment
-- ShortWord: words shorter than this are dropped at fragment start/end
-- HighlightAll: highlight all words even if not in query
-- FragmentDelimiter: separator between fragments (default: " ... ")
```

### Synonym Support

```sql
-- Create synonym dictionary file: /usr/share/postgresql/tsearch_data/my_synonyms.syn
-- Contents:
-- postgres postgresql
-- psql postgresql
-- pg postgresql
-- db database

-- Create text search dictionary
CREATE TEXT SEARCH DICTIONARY my_synonyms (
    TEMPLATE = synonym,
    SYNONYMS = my_synonyms
);

-- Create custom configuration
CREATE TEXT SEARCH CONFIGURATION english_syn (COPY = english);
ALTER TEXT SEARCH CONFIGURATION english_syn
    ALTER MAPPING FOR asciiword, asciihword, hword_asciipart
    WITH my_synonyms, english_stem;

-- Now "pg" matches "postgresql"
SELECT to_tsvector('english_syn', 'pg optimization tips');
-- 'optim':2 'postgresql':1 'tip':3
```

### Fuzzy Matching with pg_trgm

```sql
-- For typo-tolerant search, combine FTS with trigram similarity
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Trigram index for fuzzy matching
CREATE INDEX articles_title_trgm_idx ON data.articles USING gin(title gin_trgm_ops);

-- Combined search: exact FTS + fuzzy fallback
CREATE FUNCTION api.search_articles_fuzzy(
    in_query text,
    in_limit integer DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    title text,
    match_type text,
    score real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    -- Exact FTS matches
    SELECT id, title, 'exact'::text AS match_type, ts_rank(search_vector, q) AS score
    FROM data.articles, websearch_to_tsquery('english', in_query) AS q
    WHERE search_vector @@ q

    UNION ALL

    -- Fuzzy title matches (not already in exact results)
    SELECT id, title, 'fuzzy'::text, similarity(title, in_query) AS score
    FROM data.articles
    WHERE similarity(title, in_query) > 0.3
      AND id NOT IN (
          SELECT a.id FROM data.articles a, websearch_to_tsquery('english', in_query) AS q
          WHERE a.search_vector @@ q
      )

    ORDER BY score DESC
    LIMIT in_limit;
$$;
```

### Search Suggestions (Autocomplete)

```sql
-- Table for search terms
CREATE TABLE data.search_terms (
    term        text PRIMARY KEY,
    frequency   integer NOT NULL DEFAULT 1,
    last_used   timestamptz NOT NULL DEFAULT now()
);

-- Trigram index for prefix matching
CREATE INDEX search_terms_trgm_idx ON data.search_terms USING gin(term gin_trgm_ops);

-- Track searches
CREATE PROCEDURE api.track_search(in_term text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    INSERT INTO data.search_terms (term, frequency, last_used)
    VALUES (lower(trim(in_term)), 1, now())
    ON CONFLICT (term) DO UPDATE
    SET frequency = search_terms.frequency + 1,
        last_used = now();
$$;

-- Autocomplete function
CREATE FUNCTION api.search_suggestions(in_prefix text, in_limit integer DEFAULT 10)
RETURNS TABLE (term text, frequency integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT term, frequency
    FROM data.search_terms
    WHERE term LIKE lower(in_prefix) || '%'
    ORDER BY frequency DESC, last_used DESC
    LIMIT in_limit;
$$;
```

### Faceted Search

```sql
-- Get search results with category counts
CREATE FUNCTION api.search_with_facets(in_query text)
RETURNS TABLE (
    results jsonb,
    facets jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    WITH search_results AS (
        SELECT id, title, category, ts_rank(search_vector, q) AS rank
        FROM data.articles, websearch_to_tsquery('english', in_query) AS q
        WHERE search_vector @@ q
    ),
    result_data AS (
        SELECT jsonb_agg(
            jsonb_build_object('id', id, 'title', title, 'category', category)
            ORDER BY rank DESC
        ) AS results
        FROM (SELECT * FROM search_results LIMIT 20) sub
    ),
    facet_data AS (
        SELECT jsonb_object_agg(category, cnt) AS facets
        FROM (
            SELECT category, count(*) AS cnt
            FROM search_results
            GROUP BY category
            ORDER BY cnt DESC
        ) sub
    )
    SELECT result_data.results, facet_data.facets
    FROM result_data, facet_data;
$$;
```

## Performance Optimization

### Index Maintenance

```sql
-- Check index size
SELECT
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE indexrelname LIKE '%search%';

-- Reindex if bloated
REINDEX INDEX CONCURRENTLY articles_search_idx;
```

### Query Optimization

```sql
-- EXPLAIN ANALYZE your searches
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM data.articles
WHERE search_vector @@ to_tsquery('english', 'postgresql')
ORDER BY ts_rank(search_vector, to_tsquery('english', 'postgresql')) DESC
LIMIT 20;

-- Should show: Bitmap Index Scan on articles_search_idx
```

### Limit Result Set Early

```sql
-- BAD: Rank all matches then limit
SELECT *, ts_rank(search_vector, q) AS rank
FROM data.articles, to_tsquery('english', 'common') AS q
WHERE search_vector @@ q
ORDER BY rank DESC
LIMIT 20;

-- BETTER: Use threshold to reduce ranking work
SELECT *, ts_rank(search_vector, q) AS rank
FROM data.articles, to_tsquery('english', 'common') AS q
WHERE search_vector @@ q
  AND ts_rank(search_vector, q) > 0.01  -- Filter low-relevance early
ORDER BY rank DESC
LIMIT 20;
```

### Avoid ts_headline on Large Result Sets

```sql
-- BAD: Generate snippets for all results
SELECT id, title, ts_headline('english', body, q) AS snippet
FROM data.articles, to_tsquery('english', 'postgresql') AS q
WHERE search_vector @@ q;

-- GOOD: Generate snippets only for displayed results
WITH ranked AS (
    SELECT id, title, body, ts_rank(search_vector, q) AS rank
    FROM data.articles, to_tsquery('english', 'postgresql') AS q
    WHERE search_vector @@ q
    ORDER BY rank DESC
    LIMIT 20
)
SELECT
    id,
    title,
    ts_headline('english', body, to_tsquery('english', 'postgresql')) AS snippet
FROM ranked;
```

### Statistics and Monitoring

```sql
-- Most common search terms (from pg_stat_statements)
SELECT query, calls, mean_exec_time
FROM pg_stat_statements
WHERE query LIKE '%@@%tsquery%'
ORDER BY calls DESC
LIMIT 20;

-- tsvector statistics
SELECT
    word,
    ndoc,
    nentry
FROM ts_stat('SELECT search_vector FROM data.articles')
ORDER BY nentry DESC
LIMIT 50;
```
