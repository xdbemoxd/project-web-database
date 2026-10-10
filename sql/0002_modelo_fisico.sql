-- Copia congelada de docs/base-de-datos/schema.sql (2026-09-28) para la migración 0002,



-- sin BEGIN/COMMIT: Alembic ya ejecuta la migración dentro de una transacción.



-- No se edita: los cambios posteriores al modelo van en migraciones nuevas.



-- =============================================================================



-- Red FaCyT — Modelo físico (PostgreSQL 17 local / Supabase)



-- =============================================================================



-- Normalizado hasta 3FN. La justificación de cada tabla, sus dependencias



-- funcionales y las decisiones de diseño están en modelo-de-datos.md.



--



-- Requisitos previos: extensiones citext, unaccent y pg_trgm en el esquema



-- `extensions` (migración Alembic 0001). Este script las crea si faltan.



--



-- Orden de ejecución:  schema.sql  →  seed.sql  →  (opcional) verificacion.sql



--



-- Convenciones



--   · Tablas y columnas en español, singular, snake_case.



--   · PK de negocio: UUID (versión 7) con DEFAULT uuid_generate_v7().



--     Arquitectura Híbrida de Claves: las entidades de negocio usan UUIDv7



--     (ordenables en el tiempo, sin exponer conteos ni permitir scraping por



--     id secuencial en la API); los catálogos mantienen smallint/bigint.



--   · PK de catálogos: smallint con valores FIJOS (seed.sql). Algunos CHECK,



--     índices parciales y triggers usan esos valores; cada uso lleva un



--     comentario con el código, y verificacion.sql comprueba que id ↔ código



--     coinciden con el seed.



--   · Fechas: timestamptz (UTC en la BD, zona horaria en el cliente).



--   · Nombres de restricciones iguales a NAMING_CONVENTION de app/core/db.py.



--   · Funciones de trigger con search_path fijo (lint 0011 de Supabase).



-- =============================================================================











CREATE SCHEMA IF NOT EXISTS extensions;



CREATE EXTENSION IF NOT EXISTS citext   WITH SCHEMA extensions;



CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;



CREATE EXTENSION IF NOT EXISTS pg_trgm  WITH SCHEMA extensions;



CREATE SCHEMA IF NOT EXISTS app;



COMMENT ON SCHEMA app IS 'Esquema privado de la aplicacion: fuera del alcance de la Data API de Supabase (PostgREST solo expone public).';







-- -----------------------------------------------------------------------------



-- 0. Generación de UUIDv7 (Arquitectura Híbrida de Claves)



-- -----------------------------------------------------------------------------



-- PostgreSQL 17 no trae uuidv7() de forma nativa (llega en PostgreSQL 18). Se



-- implementa aquí en PL/pgSQL siguiendo el borrador RFC 9562 (versión 7):



--   · 48 bits de timestamp Unix en milisegundos (big-endian), ordenables.



--   · 4 bits de versión = 7.



--   · 2 bits de variante = 10 (RFC 4122).



--   · El resto, bits aleatorios tomados de gen_random_uuid() (sin extensiones).



-- Al ser crecientes en el tiempo, los UUIDv7 producen índices B-tree compactos



-- (a diferencia de uuidv4), y al no ser secuenciales no exponen el número de



-- filas ni permiten enumerar recursos (anti-scraping) en la API pública.



CREATE OR REPLACE FUNCTION public.uuid_generate_v7()



RETURNS uuid



LANGUAGE plpgsql



VOLATILE PARALLEL SAFE



SET search_path = pg_catalog



AS $$



DECLARE



    unix_ts_ms  bigint;



    uuid_bytes  bytea;



BEGIN



    -- Milisegundos desde la época Unix (48 bits).



    unix_ts_ms := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;







    -- 16 bytes aleatorios a partir de gen_random_uuid() (nativo de PostgreSQL,



    -- sin extensiones): sus 122 bits aleatorios bastan como base; luego se



    -- sobreescriben timestamp, version y variante.



    uuid_bytes := uuid_send(gen_random_uuid());







    -- Bytes 0..5: timestamp de 48 bits en big-endian.



    uuid_bytes := set_byte(uuid_bytes, 0, (unix_ts_ms >> 40) & 255);



    uuid_bytes := set_byte(uuid_bytes, 1, (unix_ts_ms >> 32) & 255);



    uuid_bytes := set_byte(uuid_bytes, 2, (unix_ts_ms >> 24) & 255);



    uuid_bytes := set_byte(uuid_bytes, 3, (unix_ts_ms >> 16) & 255);



    uuid_bytes := set_byte(uuid_bytes, 4, (unix_ts_ms >>  8) & 255);



    uuid_bytes := set_byte(uuid_bytes, 5,  unix_ts_ms        & 255);







    -- Byte 6: nibble alto = versión (7); nibble bajo = aleatorio original.



    uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);







    -- Byte 8: dos bits altos = variante RFC 4122 (10); resto aleatorio.



    uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);







    RETURN encode(uuid_bytes, 'hex')::uuid;



END



$$;



COMMENT ON FUNCTION public.uuid_generate_v7() IS



    'Genera un UUID versión 7 (RFC 9562): timestamp ms + aleatorio. PK de negocio.';







-- -----------------------------------------------------------------------------



-- 0b. Funciones de texto



-- -----------------------------------------------------------------------------



-- Estas funciones NO llevan SET search_path a propósito: con esa cláusula



-- PostgreSQL no puede incrustarlas (inlining) en la consulta. En su lugar, todo



-- nombre que usan va calificado con su esquema.







-- Búsqueda sin tildes (F3.4). unaccent() es STABLE (busca su diccionario por



-- search_path) y no se puede usar en un índice. Se envuelve en una función



-- IMMUTABLE con esquema y diccionario escritos explícitamente.



CREATE OR REPLACE FUNCTION public.f_unaccent(text)



RETURNS text



LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT



AS $$ SELECT extensions.unaccent('extensions.unaccent'::regdictionary, $1) $$;







-- Configuración de texto completo en español que además quita tildes.



-- Si se modifica esta configuración o las reglas de unaccent, hay que ejecutar



-- REINDEX INDEX ix_publicacion_busqueda (el índice guarda el resultado antiguo).



DO $$



BEGIN



    IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname = 'es_unaccent') THEN



        CREATE TEXT SEARCH CONFIGURATION public.es_unaccent (COPY = pg_catalog.spanish);



        ALTER TEXT SEARCH CONFIGURATION public.es_unaccent



            ALTER MAPPING FOR hword, hword_part, word



            WITH extensions.unaccent, spanish_stem;



    END IF;



END



$$;







-- Documento de búsqueda de una publicación. Se indexa por expresión (no se



-- guarda en una columna) para no almacenar un dato derivado de titulo/contenido.



-- La consulta del muro debe usar EXACTAMENTE esta función para aprovechar el índice.



CREATE OR REPLACE FUNCTION public.publicacion_documento(titulo text, contenido text)



RETURNS tsvector



LANGUAGE sql IMMUTABLE PARALLEL SAFE



AS $$



    SELECT setweight(to_tsvector('public.es_unaccent'::regconfig, coalesce(titulo, '')), 'A')



        || setweight(to_tsvector('public.es_unaccent'::regconfig, coalesce(contenido, '')), 'B')



$$;







-- Normalización de etiquetas (F2.5): minúsculas, sin espacios ni tildes, pero



-- conservando la ñ ("año" no es "ano"). Solo quedan letras, dígitos, ñ y guiones



-- simples entre palabras. "Jornadas 2026" → "jornadas2026", "Diseño Web" → "diseñoweb".



-- El servicio la usa para normalizar lo que escribe el autor, y el CHECK de



-- etiqueta la usa para rechazar lo que no esté normalizado: una sola regla.



CREATE OR REPLACE FUNCTION public.f_normalizar_etiqueta(texto text)



RETURNS text



LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT



AS $$



    SELECT pg_catalog.btrim(



               pg_catalog.regexp_replace(



                   pg_catalog.regexp_replace(



                       pg_catalog.translate(



                           pg_catalog.lower(texto),



                           'áéíóúüàèìòùÁÉÍÓÚÜÀÈÌÒÙÑ',



                           'aeiouuaeiouaeiouuaeiouñ'),



                       '[^a-z0-9ñ-]+', '', 'g'),



                   '-{2,}', '-', 'g'),



               '-')



$$;







-- =============================================================================



-- 1. CATÁLOGOS



-- =============================================================================







CREATE TABLE app.rol (



    id          smallint    NOT NULL,



    codigo      varchar(20) NOT NULL,



    nombre      varchar(50) NOT NULL,



    CONSTRAINT pk_rol PRIMARY KEY (id),



    CONSTRAINT uq_rol_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.rol IS 'Roles de usuario: estudiante, profesor, administrador (F1.1, F5.4).';







CREATE TABLE app.audiencia (



    id                  smallint     NOT NULL,



    codigo              varchar(20)  NOT NULL,



    nombre              varchar(50)  NOT NULL,



    descripcion         varchar(200) NOT NULL,



    visible_sin_sesion  boolean      NOT NULL DEFAULT false,



    CONSTRAINT pk_audiencia PRIMARY KEY (id),



    CONSTRAINT uq_audiencia_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.audiencia IS 'Audiencias de una publicación (F2.3).';



COMMENT ON COLUMN app.audiencia.visible_sin_sesion IS 'Columna "Visitante" de la Tabla 1 (F3.2, F3.7).';







-- Matriz de visibilidad (Tabla 1 del documento de requisitos) guardada como dato:



-- una fila = "el rol R puede ver publicaciones con audiencia A".



CREATE TABLE app.audiencia_rol (



    audiencia_id  smallint NOT NULL,



    rol_id        smallint NOT NULL,



    CONSTRAINT pk_audiencia_rol PRIMARY KEY (audiencia_id, rol_id),



    CONSTRAINT fk_audiencia_rol_audiencia_id_audiencia



        FOREIGN KEY (audiencia_id) REFERENCES app.audiencia (id) ON DELETE CASCADE,



    CONSTRAINT fk_audiencia_rol_rol_id_rol



        FOREIGN KEY (rol_id) REFERENCES app.rol (id) ON DELETE CASCADE



);



COMMENT ON TABLE app.audiencia_rol IS 'Qué rol ve qué audiencia (F3.2, Tabla 1).';







CREATE TABLE app.estado_publicacion (



    id      smallint    NOT NULL,



    codigo  varchar(20) NOT NULL,



    nombre  varchar(50) NOT NULL,



    CONSTRAINT pk_estado_publicacion PRIMARY KEY (id),



    CONSTRAINT uq_estado_publicacion_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.estado_publicacion IS 'Visible, Oculta por el autor, Oculta por moderación (F2.8, F4.3).';







CREATE TABLE app.estado_solicitud (



    id      smallint    NOT NULL,



    codigo  varchar(20) NOT NULL,



    nombre  varchar(50) NOT NULL,



    CONSTRAINT pk_estado_solicitud PRIMARY KEY (id),



    CONSTRAINT uq_estado_solicitud_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.estado_solicitud IS 'Pendiente, Aprobada, Rechazada (F1.2, F5.2, F5.3).';







CREATE TABLE app.accion_moderacion (



    id      smallint    NOT NULL,



    codigo  varchar(20) NOT NULL,



    nombre  varchar(50) NOT NULL,



    CONSTRAINT pk_accion_moderacion PRIMARY KEY (id),



    CONSTRAINT uq_accion_moderacion_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.accion_moderacion IS 'Revisar, Ocultar, Restaurar, Eliminar (F4.2–F4.5). Qué acción exige motivo lo define ck_moderacion_motivo.';







CREATE TABLE app.tipo_evento_cuenta (



    id      smallint    NOT NULL,



    codigo  varchar(20) NOT NULL,



    nombre  varchar(50) NOT NULL,



    CONSTRAINT pk_tipo_evento_cuenta PRIMARY KEY (id),



    CONSTRAINT uq_tipo_evento_cuenta_codigo UNIQUE (codigo)



);



COMMENT ON TABLE app.tipo_evento_cuenta IS 'Cambio de rol, Desactivación, Reactivación (F5.4–F5.6).';







-- Regla de visibilidad por audiencia (F3.2, Tabla 1) en un solo lugar.



-- p_rol_id NULL = visitante sin sesión. El repository del módulo posts la usa en



-- el muro, la búsqueda, el detalle y las sugerencias de etiquetas.



-- Parámetros integer: las columnas smallint se convierten solas, y así acepta



-- los enteros que envía el driver sin un cast explícito.



CREATE OR REPLACE FUNCTION public.audiencia_visible_para(p_audiencia_id integer, p_rol_id integer)



RETURNS boolean



LANGUAGE sql STABLE PARALLEL SAFE



AS $$



    SELECT CASE



        WHEN p_rol_id IS NULL THEN



            coalesce((SELECT a.visible_sin_sesion FROM app.audiencia a WHERE a.id = p_audiencia_id), false)



        ELSE



            EXISTS (SELECT 1 FROM app.audiencia_rol ar



                    WHERE ar.audiencia_id = p_audiencia_id AND ar.rol_id = p_rol_id)



    END



$$;







-- =============================================================================



-- 2. IDENTIDAD Y ACCESO (módulo identity)



-- =============================================================================







CREATE TABLE app.usuario (



    id                     uuid              PRIMARY KEY DEFAULT uuid_generate_v7(),



    nombre_completo        varchar(120)      NOT NULL,



    correo                 extensions.citext NOT NULL,



    password_hash          varchar(255)      NOT NULL,



    rol_id                 smallint          NOT NULL DEFAULT 1,  -- 1 = estudiante



    activo                 boolean           NOT NULL DEFAULT true,



    debe_cambiar_password  boolean           NOT NULL DEFAULT false,



    foto_ruta              varchar(255),



    creado_en              timestamptz       NOT NULL DEFAULT now(),



    actualizado_en         timestamptz       NOT NULL DEFAULT now(),



    CONSTRAINT uq_usuario_correo UNIQUE (correo),



    CONSTRAINT fk_usuario_rol_id_rol



        FOREIGN KEY (rol_id) REFERENCES app.rol (id) ON DELETE RESTRICT,



    CONSTRAINT ck_usuario_nombre_no_vacio CHECK (length(btrim(nombre_completo)) >= 2),



    CONSTRAINT ck_usuario_correo_formato  CHECK (correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),



    CONSTRAINT ck_usuario_correo_longitud CHECK (length(correo) <= 254),  -- RFC 5321



    CONSTRAINT ck_usuario_hash_argon2     CHECK (password_hash LIKE '$argon2%')



);



-- Administradores activos: los cuenta el trigger del último administrador (F5.4)



-- y los lista la administración.



CREATE INDEX ix_usuario_admin_activo ON app.usuario (id) WHERE rol_id = 3 AND activo;  -- 3 = administrador



-- Búsqueda de usuarios por nombre en la administración (F5.4).



CREATE INDEX ix_usuario_nombre_trgm



    ON app.usuario USING gin (public.f_unaccent(lower(nombre_completo)) extensions.gin_trgm_ops);



COMMENT ON TABLE app.usuario IS 'Cuenta de un miembro de la comunidad (F1.1–F1.7). No se borra: se desactiva (F5.5).';



COMMENT ON COLUMN app.usuario.password_hash IS 'Hash argon2; la contraseña nunca se guarda (F1.3).';



COMMENT ON COLUMN app.usuario.debe_cambiar_password IS 'Obliga a cambiarla en el primer acceso (F5.10).';







CREATE TABLE app.solicitud_profesor (



    id              uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    usuario_id      uuid         NOT NULL,



    estado_id       smallint     NOT NULL DEFAULT 1,  -- 1 = pendiente



    creada_en       timestamptz  NOT NULL DEFAULT now(),



    resuelta_por    uuid,



    resuelta_en     timestamptz,



    motivo_rechazo  varchar(500),



    CONSTRAINT fk_solicitud_profesor_usuario_id_usuario



        FOREIGN KEY (usuario_id) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    CONSTRAINT fk_solicitud_profesor_estado_id_estado_solicitud



        FOREIGN KEY (estado_id) REFERENCES app.estado_solicitud (id) ON DELETE RESTRICT,



    CONSTRAINT fk_solicitud_profesor_resuelta_por_usuario



        FOREIGN KEY (resuelta_por) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    -- 1 = pendiente: sin resolver. 2 = aprobada, 3 = rechazada: con responsable y fecha (F5.2).



    CONSTRAINT ck_solicitud_profesor_resolucion CHECK (



        (estado_id = 1 AND resuelta_por IS NULL AND resuelta_en IS NULL)



        OR (estado_id IN (2, 3) AND resuelta_por IS NOT NULL AND resuelta_en IS NOT NULL)



    ),



    -- Solo el rechazo (3) lleva motivo, y es obligatorio (F5.3).



    CONSTRAINT ck_solicitud_profesor_motivo CHECK (



        (estado_id = 3) = (motivo_rechazo IS NOT NULL AND length(btrim(motivo_rechazo)) > 0)



    ),



    CONSTRAINT ck_solicitud_profesor_fechas CHECK (resuelta_en IS NULL OR resuelta_en >= creada_en)



);



-- Una sola solicitud pendiente (1) por usuario, segura ante concurrencia (F1.2, HU-02).



CREATE UNIQUE INDEX uq_solicitud_profesor_pendiente



    ON app.solicitud_profesor (usuario_id) WHERE estado_id = 1;



-- Estado de la solicitud en el perfil (F1.7).



CREATE INDEX ix_solicitud_profesor_usuario_id ON app.solicitud_profesor (usuario_id);



-- Bandeja de solicitudes: pendientes de la más antigua a la más reciente (F5.1).



CREATE INDEX ix_solicitud_profesor_estado_creada ON app.solicitud_profesor (estado_id, creada_en);



COMMENT ON TABLE app.solicitud_profesor IS 'Pedido del rol de profesor y su resolución (F1.2, F5.1–F5.3). Una solicitud resuelta no cambia (HU-23).';







CREATE TABLE app.evento_cuenta (



    id               uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    usuario_id       uuid         NOT NULL,



    tipo_evento_id   smallint     NOT NULL,



    realizado_por    uuid         NOT NULL,



    rol_anterior_id  smallint,



    rol_nuevo_id     smallint,



    solicitud_id     uuid,



    motivo           varchar(500),



    fecha            timestamptz  NOT NULL DEFAULT now(),



    CONSTRAINT fk_evento_cuenta_usuario_id_usuario



        FOREIGN KEY (usuario_id) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    CONSTRAINT fk_evento_cuenta_tipo_evento_id_tipo_evento_cuenta



        FOREIGN KEY (tipo_evento_id) REFERENCES app.tipo_evento_cuenta (id) ON DELETE RESTRICT,



    CONSTRAINT fk_evento_cuenta_realizado_por_usuario



        FOREIGN KEY (realizado_por) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    CONSTRAINT fk_evento_cuenta_rol_anterior_id_rol



        FOREIGN KEY (rol_anterior_id) REFERENCES app.rol (id) ON DELETE RESTRICT,



    CONSTRAINT fk_evento_cuenta_rol_nuevo_id_rol



        FOREIGN KEY (rol_nuevo_id) REFERENCES app.rol (id) ON DELETE RESTRICT,



    CONSTRAINT fk_evento_cuenta_solicitud_id_solicitud_profesor



        FOREIGN KEY (solicitud_id) REFERENCES app.solicitud_profesor (id) ON DELETE RESTRICT,



    -- Una aprobación produce un solo cambio de rol.



    CONSTRAINT uq_evento_cuenta_solicitud_id UNIQUE (solicitud_id),



    -- 1 = cambio de rol: ambos roles y distintos. Otros eventos: sin roles.



    CONSTRAINT ck_evento_cuenta_roles CHECK (



        (tipo_evento_id = 1 AND rol_anterior_id IS NOT NULL AND rol_nuevo_id IS NOT NULL



                            AND rol_anterior_id <> rol_nuevo_id)



        OR (tipo_evento_id <> 1 AND rol_anterior_id IS NULL AND rol_nuevo_id IS NULL)



    ),



    -- Un cambio de rol que viene de una solicitud aprobada lleva a profesor (2) (F5.2).



    CONSTRAINT ck_evento_cuenta_solicitud CHECK (



        solicitud_id IS NULL OR (tipo_evento_id = 1 AND rol_nuevo_id = 2)



    ),



    -- 2 = desactivación: exige motivo (F5.5).



    CONSTRAINT ck_evento_cuenta_motivo CHECK (



        tipo_evento_id <> 2 OR (motivo IS NOT NULL AND length(btrim(motivo)) > 0)



    ),



    -- Un administrador no se desactiva (F5.5) ni se quita el rol de administrador (3) (F5.4).



    CONSTRAINT ck_evento_cuenta_autoservicio CHECK (



        realizado_por <> usuario_id



        OR (tipo_evento_id <> 2 AND NOT (tipo_evento_id = 1 AND rol_anterior_id = 3))



    )



);



-- Historial de una cuenta (F5.4–F5.6).



CREATE INDEX ix_evento_cuenta_usuario_fecha ON app.evento_cuenta (usuario_id, fecha DESC);



COMMENT ON TABLE app.evento_cuenta IS 'Registro inmutable de cambios de cuenta con autor y fecha (F5.2, F5.4–F5.6).';



COMMENT ON COLUMN app.evento_cuenta.solicitud_id IS 'Solicitud de profesor que originó el cambio de rol, si la hay (F5.2).';







-- Sesión = una familia de refresh tokens que nace en un inicio de sesión (F1.4)



-- y muere al cerrar sesión, al desactivar la cuenta o al detectar un token reusado.



-- El access token lleva su id (claim "sid") y la API la valida en cada petición,



-- así el cierre de sesión rige al instante aunque alguien haya copiado el token (F1.6).



CREATE TABLE app.sesion (



    id                  uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    usuario_id          uuid         NOT NULL,



    creada_en           timestamptz  NOT NULL DEFAULT now(),



    expira_absoluta_en  timestamptz  NOT NULL,



    revocada_en         timestamptz,



    motivo_revocacion   varchar(20),



    CONSTRAINT fk_sesion_usuario_id_usuario



        FOREIGN KEY (usuario_id) REFERENCES app.usuario (id) ON DELETE CASCADE,



    CONSTRAINT ck_sesion_vigencia CHECK (expira_absoluta_en > creada_en),



    CONSTRAINT ck_sesion_revocacion CHECK ((revocada_en IS NULL) = (motivo_revocacion IS NULL)),



    CONSTRAINT ck_sesion_motivo CHECK (



        motivo_revocacion IN ('logout', 'reuso', 'desactivacion', 'cambio_password')



    )



);



-- Revocar todas las sesiones activas de un usuario (desactivación, cambio de contraseña).



CREATE INDEX ix_sesion_usuario_activa ON app.sesion (usuario_id) WHERE revocada_en IS NULL;



-- Limpieza de sesiones vencidas.



CREATE INDEX ix_sesion_expira_absoluta_en ON app.sesion (expira_absoluta_en);



COMMENT ON TABLE app.sesion IS 'Sesión iniciada; su id viaja en el access token como "sid" (F1.4, F1.6, ADR 0004).';



COMMENT ON COLUMN app.sesion.expira_absoluta_en IS 'Tope absoluto: la rotación de tokens no lo extiende.';







-- Refresh token opaco (32 bytes aleatorios). Solo se guarda su SHA-256: una copia



-- de la base no sirve para abrir sesiones. Cada uso lo rota: se marca usado_en y



-- se emite otro. Si llega un token ya usado, se revoca toda la sesión (reúso).



CREATE TABLE app.refresh_token (



    token_hash  bytea        NOT NULL,



    sesion_id   uuid         NOT NULL,



    emitido_en  timestamptz  NOT NULL DEFAULT now(),



    expira_en   timestamptz  NOT NULL,



    usado_en    timestamptz,



    CONSTRAINT pk_refresh_token PRIMARY KEY (token_hash),



    CONSTRAINT fk_refresh_token_sesion_id_sesion



        FOREIGN KEY (sesion_id) REFERENCES app.sesion (id) ON DELETE CASCADE,



    CONSTRAINT ck_refresh_token_hash_sha256 CHECK (octet_length(token_hash) = 32),



    CONSTRAINT ck_refresh_token_vigencia CHECK (expira_en > emitido_en),



    CONSTRAINT ck_refresh_token_uso CHECK (usado_en IS NULL OR usado_en >= emitido_en)



);



-- Un solo token vigente por sesión: dos renovaciones simultáneas no abren dos ramas.



CREATE UNIQUE INDEX uq_refresh_token_sesion_vigente ON app.refresh_token (sesion_id) WHERE usado_en IS NULL;



-- Tokens de una sesión (revocación en cascada) y limpieza de vencidos.



CREATE INDEX ix_refresh_token_sesion_id ON app.refresh_token (sesion_id);



CREATE INDEX ix_refresh_token_expira_en ON app.refresh_token (expira_en);



COMMENT ON TABLE app.refresh_token IS 'Refresh tokens rotativos de una sesión, guardados como hash (F1.6, ADR 0004).';



COMMENT ON COLUMN app.refresh_token.expira_en IS 'Vencimiento por inactividad: cada rotación emite un token nuevo con su propio plazo.';







-- =============================================================================



-- 3. PUBLICACIONES, MURO Y CATEGORÍAS (módulo posts)



-- =============================================================================







CREATE TABLE app.categoria (



    id           smallint GENERATED ALWAYS AS IDENTITY,



    nombre       varchar(60)  NOT NULL,



    descripcion  varchar(200) NOT NULL DEFAULT '',



    color        char(7)      NOT NULL DEFAULT '#1E40AF',



    activa       boolean      NOT NULL DEFAULT true,



    creada_en    timestamptz  NOT NULL DEFAULT now(),



    CONSTRAINT pk_categoria PRIMARY KEY (id),



    CONSTRAINT ck_categoria_nombre_no_vacio CHECK (length(btrim(nombre)) >= 2),



    CONSTRAINT ck_categoria_color_hex CHECK (color ~ '^#[0-9A-Fa-f]{6}$')



);



-- Nombre único sin distinguir mayúsculas: "Avisos" = "avisos" (F5.7, HU-25).



CREATE UNIQUE INDEX uq_categoria_nombre_ci ON app.categoria (lower(nombre));



COMMENT ON TABLE app.categoria IS 'Catálogo de categorías administrado desde la plataforma (F2.2, F5.7–F5.9).';



COMMENT ON COLUMN app.categoria.color IS 'Color de la plantilla de la tarjeta sin imagen (F6.2).';







CREATE TABLE app.publicacion (



    id            uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    autor_id      uuid         NOT NULL,



    categoria_id  smallint     NOT NULL,



    audiencia_id  smallint     NOT NULL DEFAULT 2,  -- 2 = comunidad



    estado_id     smallint     NOT NULL DEFAULT 1,  -- 1 = visible



    titulo        varchar(150) NOT NULL,



    contenido     text         NOT NULL,



    revisada      boolean      NOT NULL DEFAULT false,



    publicada_en  timestamptz  NOT NULL DEFAULT now(),



    editada_en    timestamptz,



    CONSTRAINT fk_publicacion_autor_id_usuario



        FOREIGN KEY (autor_id) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    CONSTRAINT fk_publicacion_categoria_id_categoria



        FOREIGN KEY (categoria_id) REFERENCES app.categoria (id) ON DELETE RESTRICT,



    CONSTRAINT fk_publicacion_audiencia_id_audiencia



        FOREIGN KEY (audiencia_id) REFERENCES app.audiencia (id) ON DELETE RESTRICT,



    CONSTRAINT fk_publicacion_estado_id_estado_publicacion



        FOREIGN KEY (estado_id) REFERENCES app.estado_publicacion (id) ON DELETE RESTRICT,



    CONSTRAINT ck_publicacion_titulo_longitud    CHECK (length(btrim(titulo)) BETWEEN 3 AND 150),



    CONSTRAINT ck_publicacion_contenido_longitud CHECK (length(btrim(contenido)) BETWEEN 1 AND 10000),



    CONSTRAINT ck_publicacion_editada_en         CHECK (editada_en IS NULL OR editada_en >= publicada_en),



    -- 3 = oculta por moderación: ya pasó por un administrador, así que está revisada.



    -- Evita que aparezca a la vez en "Sin revisar" y en "Oculta por moderación" (F4.1).



    CONSTRAINT ck_publicacion_moderacion         CHECK (estado_id <> 3 OR revisada)



);



-- Muro: solo visibles (1), de la más reciente a la más antigua, con id como



-- desempate para la paginación por cursor (keyset) del scroll infinito (F3.1).



CREATE INDEX ix_publicacion_muro ON app.publicacion (publicada_en DESC, id DESC) WHERE estado_id = 1;



-- Filtros por categoría y por autor (F3.3) y "mis publicaciones" (F2.8).



CREATE INDEX ix_publicacion_categoria_fecha ON app.publicacion (categoria_id, publicada_en DESC, id DESC);



CREATE INDEX ix_publicacion_autor_fecha ON app.publicacion (autor_id, publicada_en DESC, id DESC);



-- Bandeja de moderación: sin revisar primero (F4.1).



CREATE INDEX ix_publicacion_sin_revisar ON app.publicacion (publicada_en DESC, id DESC) WHERE NOT revisada;



-- Búsqueda por texto sin tildes ni mayúsculas en el histórico (F3.4).



CREATE INDEX ix_publicacion_busqueda



    ON app.publicacion USING gin (public.publicacion_documento(titulo, contenido));



COMMENT ON TABLE app.publicacion IS 'Publicación del muro (F2.1–F2.9, F3.1–F3.6). autor_id y publicada_en no cambian (F2.1, F2.7).';



COMMENT ON COLUMN app.publicacion.revisada IS 'Estado de moderación vigente: false = "Sin revisar" (F4.1, F4.2).';



COMMENT ON COLUMN app.publicacion.editada_en IS 'Marca "Editada" con la fecha de la última edición (F2.7).';







CREATE TABLE app.imagen_publicacion (



    id                   uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    publicacion_id       uuid         NOT NULL,



    ruta_almacenamiento  varchar(255) NOT NULL,



    tipo_mime            varchar(20)  NOT NULL,



    tamano_bytes         integer      NOT NULL,



    orden                smallint     NOT NULL,



    creada_en            timestamptz  NOT NULL DEFAULT now(),



    CONSTRAINT uq_imagen_publicacion_ruta_almacenamiento UNIQUE (ruta_almacenamiento),



    -- Diferible: permite reordenar (intercambiar posiciones) en una transacción.



    CONSTRAINT uq_imagen_publicacion_publicacion_id_orden



        UNIQUE (publicacion_id, orden) DEFERRABLE INITIALLY IMMEDIATE,



    CONSTRAINT fk_imagen_publicacion_publicacion_id_publicacion



        FOREIGN KEY (publicacion_id) REFERENCES app.publicacion (id) ON DELETE CASCADE,



    CONSTRAINT ck_imagen_publicacion_tipo_mime CHECK (tipo_mime IN ('image/jpeg', 'image/png', 'image/webp')),



    CONSTRAINT ck_imagen_publicacion_tamano    CHECK (tamano_bytes BETWEEN 1 AND 5242880),



    -- Máximo de imágenes por publicación [POR CONFIRMAR]: 5 (F2.4).



    CONSTRAINT ck_imagen_publicacion_orden     CHECK (orden BETWEEN 1 AND 5)



);



COMMENT ON TABLE app.imagen_publicacion IS 'Imágenes de una publicación; la de menor orden es la portada (F2.4, F6.2).';



COMMENT ON COLUMN app.imagen_publicacion.ruta_almacenamiento IS 'Nombre asignado por el sistema en el almacenamiento, no el original.';







CREATE TABLE app.etiqueta (



    id         bigint GENERATED ALWAYS AS IDENTITY,



    -- COLLATE "C": el índice único también sirve para buscar por prefijo (LIKE 'jorn%').



    nombre     varchar(30) COLLATE "C" NOT NULL,



    creada_en  timestamptz NOT NULL DEFAULT now(),



    CONSTRAINT pk_etiqueta PRIMARY KEY (id),



    CONSTRAINT uq_etiqueta_nombre UNIQUE (nombre),



    -- Normalizada con f_normalizar_etiqueta: "Jornadas 2026" → "jornadas2026" (F2.5).



    CONSTRAINT ck_etiqueta_nombre_normalizado CHECK (



        nombre = public.f_normalizar_etiqueta(nombre)



        AND nombre ~ '^[a-z0-9ñ]+(-[a-z0-9ñ]+)*$'



    )



);



COMMENT ON TABLE app.etiqueta IS 'Etiqueta libre normalizada (F2.5, F3.5).';







CREATE TABLE app.publicacion_etiqueta (



    publicacion_id  uuid     NOT NULL,



    etiqueta_id     bigint   NOT NULL,



    posicion        smallint NOT NULL,



    CONSTRAINT pk_publicacion_etiqueta PRIMARY KEY (publicacion_id, etiqueta_id),



    -- Con posicion 1..5 y única por publicación, el límite de 5 etiquetas es declarativo.



    CONSTRAINT uq_publicacion_etiqueta_publicacion_id_posicion



        UNIQUE (publicacion_id, posicion) DEFERRABLE INITIALLY IMMEDIATE,



    CONSTRAINT fk_publicacion_etiqueta_publicacion_id_publicacion



        FOREIGN KEY (publicacion_id) REFERENCES app.publicacion (id) ON DELETE CASCADE,



    CONSTRAINT fk_publicacion_etiqueta_etiqueta_id_etiqueta



        FOREIGN KEY (etiqueta_id) REFERENCES app.etiqueta (id) ON DELETE RESTRICT,



    CONSTRAINT ck_publicacion_etiqueta_posicion CHECK (posicion BETWEEN 1 AND 5)



);



-- Filtro del muro por etiqueta (F3.5) y limpieza de etiquetas huérfanas.



CREATE INDEX ix_publicacion_etiqueta_etiqueta_id ON app.publicacion_etiqueta (etiqueta_id);



COMMENT ON TABLE app.publicacion_etiqueta IS 'Relación N:M publicación–etiqueta, máximo 5 por publicación (F2.5).';







-- Archivos que hay que borrar del almacenamiento (Supabase Storage). La base no



-- puede borrar archivos: los triggers anotan la ruta en la misma transacción que



-- borra la fila, y la API los borra con la API de Storage y quita la fila.



-- Si la transacción se revierte, la anotación también, así nunca se borra un



-- archivo que sigue en uso (F2.9, F4.5, F1.7).



CREATE TABLE app.archivo_por_borrar (



    id         uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    ruta       varchar(255) NOT NULL,



    creado_en  timestamptz  NOT NULL DEFAULT now(),



    intentos   smallint     NOT NULL DEFAULT 0,



    CONSTRAINT ck_archivo_por_borrar_intentos CHECK (intentos >= 0)



);



CREATE INDEX ix_archivo_por_borrar_creado_en ON app.archivo_por_borrar (creado_en);



COMMENT ON TABLE app.archivo_por_borrar IS 'Cola de archivos de Storage pendientes de borrar (F2.9, F4.5, F1.7).';







-- =============================================================================



-- 4. MODERACIÓN (módulo moderation)



-- =============================================================================







CREATE TABLE app.moderacion (



    id                   uuid         PRIMARY KEY DEFAULT uuid_generate_v7(),



    publicacion_id       uuid,



    accion_id            smallint     NOT NULL,



    moderador_id         uuid         NOT NULL,



    motivo               varchar(500),



    titulo_al_momento    varchar(150) NOT NULL,



    autor_id_al_momento  uuid         NOT NULL,



    fecha                timestamptz  NOT NULL DEFAULT now(),



    -- SET NULL: el historial sobrevive a la eliminación de la publicación (F4.5, HU-22).



    CONSTRAINT fk_moderacion_publicacion_id_publicacion



        FOREIGN KEY (publicacion_id) REFERENCES app.publicacion (id) ON DELETE SET NULL,



    CONSTRAINT fk_moderacion_accion_id_accion_moderacion



        FOREIGN KEY (accion_id) REFERENCES app.accion_moderacion (id) ON DELETE RESTRICT,



    CONSTRAINT fk_moderacion_moderador_id_usuario



        FOREIGN KEY (moderador_id) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    CONSTRAINT fk_moderacion_autor_id_al_momento_usuario



        FOREIGN KEY (autor_id_al_momento) REFERENCES app.usuario (id) ON DELETE RESTRICT,



    -- 2 = ocultar y 4 = eliminar exigen motivo (F4.3, F4.5). Única fuente de esta regla.



    CONSTRAINT ck_moderacion_motivo CHECK (



        accion_id NOT IN (2, 4) OR (motivo IS NOT NULL AND length(btrim(motivo)) > 0)



    )



);



-- Historial de una publicación, por administrador y completo por fecha (F4.6).



CREATE INDEX ix_moderacion_publicacion_fecha ON app.moderacion (publicacion_id, fecha DESC);



CREATE INDEX ix_moderacion_moderador_fecha ON app.moderacion (moderador_id, fecha DESC);



CREATE INDEX ix_moderacion_fecha ON app.moderacion (fecha DESC);



COMMENT ON TABLE app.moderacion IS 'Historial inmutable de acciones de moderación (F4.6).';



COMMENT ON COLUMN app.moderacion.titulo_al_momento IS 'Título en el momento de la acción; se conserva si la publicación se elimina.';







-- Vista: motivo vigente del ocultamiento por moderación (F2.8, F4.3). El motivo no se



-- duplica en publicacion; se deriva del último evento "ocultar" (2) de una



-- publicación oculta por moderación (3).



-- security_invoker: la vista respeta los permisos de quien consulta (aviso de Supabase).



CREATE OR REPLACE VIEW app.v_publicacion_moderacion WITH (security_invoker = true) AS



SELECT DISTINCT ON (m.publicacion_id)



       m.publicacion_id,



       m.motivo      AS motivo_ocultamiento,



       m.moderador_id,



       m.fecha       AS ocultada_en



FROM app.moderacion m



JOIN app.publicacion p ON p.id = m.publicacion_id AND p.estado_id = 3



WHERE m.accion_id = 2



ORDER BY m.publicacion_id, m.fecha DESC, m.id DESC;



COMMENT ON VIEW app.v_publicacion_moderacion IS 'Motivo y responsable del ocultamiento vigente.';







-- =============================================================================



-- 5. REGLAS QUE LA BASE GARANTIZA CON TRIGGERS



-- =============================================================================







-- 5.1 actualizado_en automático en usuario.



CREATE OR REPLACE FUNCTION app.trg_fijar_actualizado_en()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    NEW.actualizado_en := now();



    RETURN NEW;



END



$$;







CREATE TRIGGER tg_usuario_actualizado_en



    BEFORE UPDATE ON app.usuario



    FOR EACH ROW EXECUTE FUNCTION app.trg_fijar_actualizado_en();







-- 5.2 Columnas que no cambian después de insertar la fila. Los nombres de las



-- columnas llegan como argumentos del trigger.



CREATE OR REPLACE FUNCTION app.trg_columnas_inmutables()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



DECLARE



    columna text;



BEGIN



    FOREACH columna IN ARRAY TG_ARGV LOOP



        IF (to_jsonb(NEW) -> columna) IS DISTINCT FROM (to_jsonb(OLD) -> columna) THEN



            RAISE EXCEPTION 'La columna %.% no se puede modificar', TG_TABLE_NAME, columna



                USING ERRCODE = 'check_violation';



        END IF;



    END LOOP;



    RETURN NEW;



END



$$;







-- El autor y la fecha de publicación los asigna el sistema y no cambian (F2.1, F2.7).



CREATE TRIGGER tg_publicacion_inmutable



    BEFORE UPDATE OF autor_id, publicada_en ON app.publicacion



    FOR EACH ROW EXECUTE FUNCTION app.trg_columnas_inmutables('autor_id', 'publicada_en');







CREATE TRIGGER tg_usuario_inmutable



    BEFORE UPDATE OF creado_en ON app.usuario



    FOR EACH ROW EXECUTE FUNCTION app.trg_columnas_inmutables('creado_en');







CREATE TRIGGER tg_solicitud_profesor_inmutable



    BEFORE UPDATE OF usuario_id, creada_en ON app.solicitud_profesor



    FOR EACH ROW EXECUTE FUNCTION app.trg_columnas_inmutables('usuario_id', 'creada_en');







-- 5.3 Una solicitud de profesor solo se resuelve una vez (F5.2, HU-23): se permite



-- pendiente (1) → aprobada (2) o rechazada (3), y nada más.



CREATE OR REPLACE FUNCTION app.trg_solicitud_transicion()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    IF OLD.estado_id <> 1 THEN



        RAISE EXCEPTION 'La solicitud % ya fue resuelta y no se puede modificar', OLD.id



            USING ERRCODE = 'check_violation';



    END IF;



    RETURN NEW;



END



$$;







CREATE TRIGGER tg_solicitud_profesor_transicion



    BEFORE UPDATE ON app.solicitud_profesor



    FOR EACH ROW EXECUTE FUNCTION app.trg_solicitud_transicion();







-- 5.4 Nunca quedarse sin administradores activos (F5.4, HU-24).



-- Paso 1, por sentencia: un candado de transacción serializa los cambios de rol y



-- de estado. Se toma antes de que la sentencia bloquee ninguna fila, así dos



-- degradaciones simultáneas esperan en fila en vez de terminar en un deadlock.



CREATE OR REPLACE FUNCTION app.trg_bloquear_cambios_admin()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    PERFORM pg_advisory_xact_lock(hashtext('red_facyt.administrador_activo'));



    RETURN NULL;



END



$$;







CREATE TRIGGER tg_usuario_admin_candado



    BEFORE UPDATE OF rol_id, activo ON app.usuario



    FOR EACH STATEMENT EXECUTE FUNCTION app.trg_bloquear_cambios_admin();







-- Paso 2, por fila: si el cambio deja de contar a un administrador (3) activo,



-- debe quedar otro. FOR UPDATE cubre además los niveles REPEATABLE READ y



-- SERIALIZABLE: si otro administrador cambió, la transacción falla por serialización.



CREATE OR REPLACE FUNCTION app.trg_garantizar_admin_activo()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    IF OLD.rol_id = 3 AND OLD.activo AND NOT (NEW.rol_id = 3 AND NEW.activo) THEN



        PERFORM 1 FROM app.usuario



        WHERE rol_id = 3 AND activo AND id <> NEW.id



        FOR UPDATE;



        IF NOT FOUND THEN



            RAISE EXCEPTION 'Debe existir al menos un administrador activo'



                USING ERRCODE = 'check_violation';



        END IF;



    END IF;



    RETURN NEW;



END



$$;







CREATE TRIGGER tg_usuario_admin_activo



    BEFORE UPDATE OF rol_id, activo ON app.usuario



    FOR EACH ROW EXECUTE FUNCTION app.trg_garantizar_admin_activo();







-- 5.5 Las cuentas no se borran, se desactivan (F5.5). Así tampoco se puede borrar



-- al último administrador ni perder la autoría del histórico.



CREATE OR REPLACE FUNCTION app.trg_prohibir_borrado()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    RAISE EXCEPTION 'Las filas de % no se borran', TG_TABLE_NAME



        USING ERRCODE = 'insufficient_privilege';



END



$$;







CREATE TRIGGER tg_usuario_sin_borrado



    BEFORE DELETE ON app.usuario



    FOR EACH ROW EXECUTE FUNCTION app.trg_prohibir_borrado();







-- 5.6 Solo se publica en categorías activas (F2.2, F5.9). Una publicación antigua



-- conserva su categoría aunque se desactive: la regla solo mira el valor nuevo.



CREATE OR REPLACE FUNCTION app.trg_categoria_activa()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    IF TG_OP = 'INSERT' OR NEW.categoria_id IS DISTINCT FROM OLD.categoria_id THEN



        IF (SELECT c.activa FROM app.categoria c WHERE c.id = NEW.categoria_id) IS FALSE THEN



            RAISE EXCEPTION 'La categoría % está desactivada', NEW.categoria_id



                USING ERRCODE = 'check_violation';



        END IF;



    END IF;



    RETURN NEW;



END



$$;







CREATE TRIGGER tg_publicacion_categoria_activa



    BEFORE INSERT OR UPDATE OF categoria_id ON app.publicacion



    FOR EACH ROW EXECUTE FUNCTION app.trg_categoria_activa();







-- 5.7 Historiales inmutables (F4.6, F5.4): no se editan, no se borran, no se vacían.



-- Única excepción: el UPDATE que genera ON DELETE SET NULL al eliminar la publicación.



CREATE OR REPLACE FUNCTION app.trg_historial_inmutable()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'moderacion' THEN



        IF OLD.publicacion_id IS NOT NULL AND NEW.publicacion_id IS NULL



           AND (to_jsonb(NEW) - 'publicacion_id') = (to_jsonb(OLD) - 'publicacion_id') THEN



            RETURN NEW;



        END IF;



    END IF;



    RAISE EXCEPTION 'El historial % no se puede modificar ni borrar', TG_TABLE_NAME



        USING ERRCODE = 'insufficient_privilege';



END



$$;







CREATE TRIGGER tg_moderacion_inmutable



    BEFORE UPDATE OR DELETE ON app.moderacion



    FOR EACH ROW EXECUTE FUNCTION app.trg_historial_inmutable();







CREATE TRIGGER tg_moderacion_sin_vaciado



    BEFORE TRUNCATE ON app.moderacion



    FOR EACH STATEMENT EXECUTE FUNCTION app.trg_historial_inmutable();







CREATE TRIGGER tg_evento_cuenta_inmutable



    BEFORE UPDATE OR DELETE ON app.evento_cuenta



    FOR EACH ROW EXECUTE FUNCTION app.trg_historial_inmutable();







CREATE TRIGGER tg_evento_cuenta_sin_vaciado



    BEFORE TRUNCATE ON app.evento_cuenta



    FOR EACH STATEMENT EXECUTE FUNCTION app.trg_historial_inmutable();







-- 5.8 Cola de archivos por borrar (F2.9, F4.5, F1.7). El trigger de imágenes también



-- se dispara con el ON DELETE CASCADE que genera eliminar la publicación.



CREATE OR REPLACE FUNCTION app.trg_encolar_archivo_borrado()



RETURNS trigger LANGUAGE plpgsql



SET search_path = app, public, pg_catalog



AS $$



BEGIN



    IF TG_TABLE_NAME = 'imagen_publicacion' THEN



        INSERT INTO app.archivo_por_borrar (ruta) VALUES (OLD.ruta_almacenamiento);



    ELSIF OLD.foto_ruta IS NOT NULL THEN



        INSERT INTO app.archivo_por_borrar (ruta) VALUES (OLD.foto_ruta);



    END IF;



    RETURN NULL;



END



$$;







CREATE TRIGGER tg_imagen_publicacion_encolar_borrado



    AFTER DELETE ON app.imagen_publicacion



    FOR EACH ROW EXECUTE FUNCTION app.trg_encolar_archivo_borrado();







CREATE TRIGGER tg_usuario_encolar_foto



    AFTER UPDATE OF foto_ruta ON app.usuario



    FOR EACH ROW WHEN (OLD.foto_ruta IS DISTINCT FROM NEW.foto_ruta)



    EXECUTE FUNCTION app.trg_encolar_archivo_borrado();







-- =============================================================================



-- 6. MANTENIMIENTO



-- =============================================================================



-- Borra lo que ya no sirve: tokens vencidos, sesiones terminadas hace más de 7



-- días y etiquetas que ninguna publicación usa desde hace más de 1 día. Se ejecuta



-- a diario con pg_cron en Supabase (ver modelo-de-datos.md, sección 9) o desde la API.



CREATE OR REPLACE FUNCTION public.limpiar_datos_vencidos()



RETURNS void LANGUAGE sql



SET search_path = app, public, pg_catalog



AS $$



    DELETE FROM app.refresh_token WHERE expira_en < now();



    DELETE FROM app.sesion



    WHERE expira_absoluta_en < now() - interval '7 days'



       OR revocada_en < now() - interval '7 days';



    DELETE FROM app.etiqueta e



    WHERE e.creada_en < now() - interval '1 day'



      AND NOT EXISTS (SELECT 1 FROM app.publicacion_etiqueta pe WHERE pe.etiqueta_id = e.id);



$$;







-- =============================================================================



-- 7. SUPABASE: cerrar la API automática (PostgREST)



-- =============================================================================



-- Todo el acceso pasa por la API FastAPI, que se conecta con el rol dueño de las



-- tablas (ignora RLS). Tres capas, de la más fuerte a la más débil:



--   1. Desactivar la Data API en el panel de Supabase (Settings → API).



--   2. Quitar los permisos que Supabase da por defecto a anon y authenticated.



--   3. RLS activado sin políticas: aunque quedara algún permiso, no se ve ninguna fila.



DO $$



DECLARE



    t text;



BEGIN



    FOREACH t IN ARRAY ARRAY[



        'rol', 'audiencia', 'audiencia_rol', 'estado_publicacion', 'estado_solicitud',



        'accion_moderacion', 'tipo_evento_cuenta', 'usuario', 'solicitud_profesor',



        'evento_cuenta', 'sesion', 'refresh_token', 'categoria', 'publicacion',



        'imagen_publicacion', 'etiqueta', 'publicacion_etiqueta', 'archivo_por_borrar',



        'moderacion'



    ] LOOP



        EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);



    END LOOP;



END



$$;







-- Las funciones se pueden llamar por /rest/v1/rpc; nadie más que el dueño las necesita.



REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;



REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;







-- Los roles anon y authenticated solo existen en Supabase.



DO $$



BEGIN



    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')



       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN



        REVOKE ALL ON ALL TABLES    IN SCHEMA app FROM anon, authenticated;



        REVOKE ALL ON ALL SEQUENCES IN SCHEMA app FROM anon, authenticated;



        REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated;



        REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app    FROM anon, authenticated;



        ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ALL ON TABLES    FROM anon, authenticated;



        ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ALL ON SEQUENCES FROM anon, authenticated;



        ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;



        ALTER DEFAULT PRIVILEGES IN SCHEMA app    REVOKE ALL ON FUNCTIONS FROM anon, authenticated;



    END IF;



END



$$;



