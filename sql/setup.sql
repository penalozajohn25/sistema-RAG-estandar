-- =====================================================================
-- Sistema RAG de Estándar - Script de configuración de base de datos
-- Requiere PostgreSQL con la extensión pgvector disponible.
-- =====================================================================

-- 1. Habilitar extensiones
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid() en PostgreSQL < 13

-- 2. Tabla de control de archivos ingeridos
--    El nodo "Insertar Documento" hace upsert usando file_id.
CREATE TABLE IF NOT EXISTS public.ingested_files (
    file_id        TEXT PRIMARY KEY,
    name           TEXT,
    mime_type      TEXT,
    md5_checksum   TEXT,
    modified_time  TIMESTAMPTZ,
    last_ingested  TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Tabla de vectores (estructura por defecto del nodo PGVector de n8n)
--    + columna file_id para trazabilidad.
--    text-embedding-3-large => 3072 dimensiones.
CREATE TABLE IF NOT EXISTS public.n8n_vectors (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    text       TEXT,
    metadata   JSONB,
    embedding  VECTOR(3072),
    file_id    TEXT
);

-- Si n8n_vectors ya existía (creada automáticamente por n8n),
-- asegúrate de que tenga la columna file_id:
ALTER TABLE public.n8n_vectors ADD COLUMN IF NOT EXISTS file_id TEXT;

-- 4. Índices
CREATE INDEX IF NOT EXISTS idx_n8n_vectors_file_id
    ON public.n8n_vectors (file_id);

CREATE INDEX IF NOT EXISTS idx_ingested_files_md5
    ON public.ingested_files (file_id, md5_checksum);

-- =====================================================================
-- Opcional: reiniciar la indexación completa (descomentar si se necesita)
-- =====================================================================
-- TRUNCATE public.n8n_vectors;
-- TRUNCATE public.ingested_files;
