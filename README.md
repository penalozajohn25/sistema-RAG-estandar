# Sistema RAG de Estándar — Asistente Legal con n8n

Sistema de **Retrieval-Augmented Generation (RAG)** construido en [n8n](https://n8n.io) que sincroniza documentos desde Google Drive, los vectoriza en **PostgreSQL + PGVector** y los expone a través de un **agente de IA conversacional** que funciona como asistente legal: responde preguntas basándose únicamente en los documentos cargados e indica la fuente utilizada.

---

## Tabla de contenidos

- [Características](#características)
- [Arquitectura](#arquitectura)
- [Flujo 1: Ingesta de documentos](#flujo-1-ingesta-de-documentos)
- [Flujo 2: Consulta con el agente](#flujo-2-consulta-con-el-agente)
- [Requisitos](#requisitos)
- [Configuración de la base de datos](#configuración-de-la-base-de-datos)
- [Instalación](#instalación)
- [Credenciales](#credenciales)
- [Uso](#uso)
- [Nodos alternativos incluidos](#nodos-alternativos-incluidos)
- [Personalización](#personalización)
- [Solución de problemas](#solución-de-problemas)
- [Estructura del repositorio](#estructura-del-repositorio)

---

## Características

- **Sincronización incremental desde Google Drive**: recorre una carpeta (incluidas sus subcarpetas) y solo procesa archivos nuevos o modificados.
- **Detección de cambios por checksum MD5**: evita re-vectorizar documentos que no cambiaron.
- **Re-indexación limpia**: si un archivo cambió, borra sus vectores anteriores antes de insertar los nuevos.
- **Trazabilidad**: cada fragmento vectorizado queda asociado al `file_id` de Google Drive.
- **Agente de IA con memoria**: mantiene el contexto de los últimos 10 mensajes de la conversación.
- **Respuestas fundamentadas**: el agente cita el documento y la sección/cláusula usada y responde explícitamente cuando no encuentra la información.

---

## Arquitectura

```
┌──────────────────────────── INGESTA ────────────────────────────┐
│                                                                  │
│  Manual / Schedule ─► Google Drive (listar carpeta)              │
│                            │                                     │
│                     ¿Es un archivo? ──No──► Listar subcarpeta ─┐ │
│                            │ Sí                   ▲            │ │
│                            ▼                      └────────────┘ │
│                  Postgres: ¿ya fue cargado? (id + md5)           │
│                       │ Sí ─► No Operation                       │
│                       │ No                                       │
│                       ▼                                          │
│               Extraer variables                                  │
│                       ├─► Borrar vectores previos (n8n_vectors)  │
│                       ▼                                          │
│               Esperar eliminación (Merge)                        │
│                       ▼                                          │
│               Registrar en ingested_files                        │
│                       ▼                                          │
│               Descargar archivo (Google Drive)                   │
│                       ▼                                          │
│     PGVector Store (insert) ◄── Data Loader ◄── Text Splitter    │
│                       ▲  ◄── OpenAI Embeddings                   │
│                       ▼                                          │
│               Asociar file_id a los vectores                     │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────── CONSULTA ───────────────────────────┐
│                                                                  │
│  Chat Trigger ─► AI Agent (Asistente Legal)                      │
│                    ├── OpenAI Chat Model (gpt-5-mini)            │
│                    ├── Simple Memory (10 mensajes)               │
│                    └── Tool: Answer questions with vector store  │
│                              ├── PGVector Store (lectura)        │
│                              │      └── OpenAI Embeddings        │
│                              └── OpenAI Chat Model (gpt-5-mini)  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Flujo 1: Ingesta de documentos

| # | Nodo | Función |
|---|------|---------|
| 1 | **When clicking 'Execute workflow'** / **Schedule Trigger** | Inicia la sincronización de forma manual o programada. |
| 2 | **Buscar Archivos / Directorios** | Lista todos los elementos de la carpeta de Google Drive configurada. |
| 3 | **¿Es un Archivo?** | Si el `mimeType` no es carpeta, continúa; si es carpeta, la recorre con **Search files and folders** y vuelve a evaluar (recorrido recursivo). |
| 4 | **Obtener Carga Previa** | Consulta `ingested_files` buscando el mismo `file_id` y `md5_checksum`. |
| 5 | **¿Fue Previamente Cargado?** | Si ya existe con el mismo checksum, se ignora; si no, se procesa. |
| 6 | **Extraer Variables** | Normaliza `id`, `md5Checksum`, `mimeType`, `modifiedTime` y `name`. |
| 7 | **Borrar Referencias** | Elimina de `n8n_vectors` los fragmentos previos de ese archivo. |
| 8 | **Esperar Eliminación** | Merge que garantiza que el borrado termine antes de continuar. |
| 9 | **Insertar Documento** | Registra el archivo en `ingested_files`. |
| 10 | **Descargar Archivo** | Descarga el binario desde Google Drive. |
| 11 | **Postgres PGVector Store** (insert) | Divide el documento (**Recursive Character Text Splitter**, solapamiento de 250), lo carga (**Default Data Loader**) y genera embeddings con **OpenAI `text-embedding-3-large`**. |
| 12 | **Execute a SQL query** | Asigna el `file_id` a los vectores recién insertados (los que tienen `file_id` nulo). |

---

## Flujo 2: Consulta con el agente

| Nodo | Función |
|------|---------|
| **When chat message received** | Punto de entrada del chat (chat público o integrado de n8n). |
| **AI Agent** | Agente con rol de *Asistente Legal*; respuestas cortas, formales y con referencia al documento. |
| **OpenAI Chat Model** | Modelo `gpt-5-mini` para el razonamiento del agente. |
| **Simple Memory** | Memoria de ventana con los últimos 10 mensajes. |
| **Answer questions with a vector store** | Herramienta que consulta la base vectorial y resume los fragmentos relevantes. |
| **Postgres PGVector Store1** | Lectura de la tabla `n8n_vectors`. |
| **OpenAI Chat Model1** | Modelo `gpt-5-mini` usado por la herramienta de consulta. |

Si el agente no encuentra la información responde:

```
No puedo encontrar la respuesta en los recursos disponibles.
```

---

## Requisitos

- **n8n** (Cloud o self-hosted) con soporte para nodos de LangChain / IA.
- **PostgreSQL** con la extensión [`pgvector`](https://github.com/pgvector/pgvector) (por ejemplo Supabase, Neon o una instancia propia).
- **Cuenta de OpenAI** con acceso a:
  - `text-embedding-3-large` (embeddings)
  - `gpt-5-mini` (chat)
- **Cuenta de Google** con una carpeta de Google Drive que contenga los documentos (PDF recomendado).

---

## Configuración de la base de datos

Ejecuta el siguiente script en tu base de datos PostgreSQL antes de importar el workflow:

```sql
-- 1. Habilitar pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Tabla de control de archivos ingeridos
CREATE TABLE IF NOT EXISTS public.ingested_files (
    file_id        TEXT PRIMARY KEY,
    name           TEXT,
    mime_type      TEXT,
    md5_checksum   TEXT,
    modified_time  TIMESTAMPTZ,
    last_ingested  TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Tabla de vectores (estructura por defecto del nodo PGVector de n8n
--    + columna file_id para trazabilidad)
--    text-embedding-3-large genera vectores de 3072 dimensiones.
CREATE TABLE IF NOT EXISTS public.n8n_vectors (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    text       TEXT,
    metadata   JSONB,
    embedding  VECTOR(3072),
    file_id    TEXT
);

CREATE INDEX IF NOT EXISTS idx_n8n_vectors_file_id
    ON public.n8n_vectors (file_id);
```

> **Nota:** si la tabla `n8n_vectors` ya fue creada automáticamente por n8n, basta con añadir la columna:
> ```sql
> ALTER TABLE public.n8n_vectors ADD COLUMN IF NOT EXISTS file_id TEXT;
> ```

> **Importante:** como `Insertar Documento` registra cada archivo sin columnas de coincidencia, si un archivo se modifica se intentará insertar de nuevo el mismo `file_id`. Si usas `file_id` como `PRIMARY KEY`, considera cambiar ese nodo a la operación **Insert or Update (upsert)** usando `file_id` como columna de coincidencia, o eliminar la restricción de clave primaria.

---

## Instalación

1. Clona este repositorio:
   ```bash
   https://github.com/penalozajohn25/sistema-RAG-estandar.git
   ```
2. En n8n, ve a **Workflows → Import from File** y selecciona `Sistema RAG de Estandar.json`.
3. Ejecuta el script SQL de la sección anterior.
4. Configura las credenciales (ver siguiente sección) en cada nodo que las requiera.
5. En los nodos **Buscar Archivos / Directorios** (y opcionalmente **Google Drive Trigger**), selecciona tu propia carpeta de Google Drive.
6. Guarda el workflow.

---

## Credenciales

| Servicio | Tipo de credencial en n8n | Nodos que la usan |
|----------|---------------------------|-------------------|
| OpenAI | `OpenAI API` | Embeddings OpenAI, OpenAI Chat Model, OpenAI Chat Model1 |
| PostgreSQL | `Postgres` | Obtener Carga Previa, Borrar Referencias, Insertar Documento, Execute a SQL query, Postgres PGVector Store, Postgres PGVector Store1 |
| Google Drive | `Google Drive OAuth2 API` | Buscar Archivos / Directorios, Search files and folders, Descargar Archivo, Google Drive Trigger |

> **Seguridad:** el JSON exportado de n8n **no incluye los secretos** de las credenciales, solo sus referencias. Aun así, revisa el archivo antes de subirlo y **nunca** publiques claves de API, contraseñas ni cadenas de conexión en el repositorio.

---

## Uso

### Cargar / sincronizar documentos

1. Sube tus documentos a la carpeta de Google Drive configurada (se admiten subcarpetas).
2. Ejecuta el workflow manualmente desde **When clicking 'Execute workflow'**, o publica el workflow para que el **Schedule Trigger** sincronice automáticamente.
3. Solo los archivos nuevos o modificados serán vectorizados.

### Consultar al asistente

1. Abre el chat del nodo **When chat message received** (botón *Open chat* en n8n, o la URL pública si habilitas el chat público).
2. Escribe tu consulta, por ejemplo:
   > ¿Cuál es el procedimiento de terminación anticipada del contrato de arrendamiento?
3. El agente responderá con un resumen y la referencia al documento y cláusula.

---

## Nodos alternativos incluidos

El workflow contiene algunos nodos **desconectados** que se conservan como alternativas o pruebas:

| Nodo | Propósito |
|------|-----------|
| **On form submission** | Formulario para subir PDFs manualmente (alternativa a Google Drive). |
| **Google Drive Trigger** | Disparo automático al crear un archivo en la carpeta (alternativa al Schedule Trigger). |
| **Simple Vector Store** / **Simple Vector Store1** | Almacén vectorial en memoria, útil para pruebas sin PostgreSQL (los datos se pierden al reiniciar n8n). |

Puedes conectarlos o eliminarlos según tus necesidades.

---

## Personalización

- **Prompt del agente**: edita el *System Message* del nodo **AI Agent** para adaptar el rol (legal, soporte, RR. HH., etc.).
- **Modelo**: cambia `gpt-5-mini` en los nodos *OpenAI Chat Model* por otro modelo disponible en tu cuenta.
- **Fragmentación**: ajusta `chunkSize` y `chunkOverlap` en **Recursive Character Text Splitter**.
- **Frecuencia de sincronización**: modifica el intervalo del **Schedule Trigger**.
- **Memoria**: ajusta `contextWindowLength` en **Simple Memory**.

> Si cambias el modelo de embeddings, ajusta la dimensión de la columna `embedding` y **re-indexa todos los documentos** (vacía `ingested_files` y `n8n_vectors`).

---

## Solución de problemas

| Problema | Posible causa / solución |
|----------|--------------------------|
| `column "file_id" does not exist` | Falta añadir la columna `file_id` a `n8n_vectors`. |
| `relation "ingested_files" does not exist` | Ejecuta el script SQL de configuración. |
| `duplicate key value violates unique constraint` | Un archivo modificado se intenta registrar de nuevo; usa *upsert* en **Insertar Documento**. |
| `expected N dimensions, not 3072` | La columna `embedding` fue creada con otra dimensión; recréala como `VECTOR(3072)`. |
| El agente siempre responde que no encuentra la información | Verifica que la ingesta se haya ejecutado y que ambos nodos PGVector usen la misma tabla y el mismo modelo de embeddings. |
| Se procesan archivos de la papelera | El nodo **Buscar Archivos / Directorios** tiene activada la opción *Include Trashed*; desactívala si no deseas incluirlos. |

---

## Estructura del repositorio

```
.
├── README.md
├── Sistema RAG de Estandar.json   # Workflow exportado desde n8n
├── contrato_laboral_ventas.pdf    # Documento de Prueba
├── drive n8n                      # Documentos de carga en drive
└── sql/
    └── setup.sql                  # Script de creación de tablas (opcional)
```

Para exportar el workflow desde n8n: abre el workflow → menú **(...)** → **Download**.

---

## Autor

**John Peñaloza**