-- =============================================================================
-- Red FaCyT — Verificacion post-migracion del esquema hibrido (app / public)
-- =============================================================================
-- Autor del proyecto: Benjamin Marroquin
-- Se ejecuta DESPUES de aplicar las migraciones 0001, 0002 y 0003.
--   psql "$DATABASE_URL" -f migrations/sql/verificacion_esquema.sql
--
-- Cada bloque es una asercion: si algo no quedo como se espera, RAISE EXCEPTION
-- aborta con un mensaje claro. Si el script llega al final e imprime
-- "VERIFICACION OK", el esquema hibrido esta correctamente desplegado.
--
-- Que comprueba:
--   1. Existen los esquemas app, public y extensions.
--   2. Las 19 tablas de negocio/catalogo viven en app (y NINGUNA en public).
--   3. Las funciones de texto/utilidad viven en public; las de trigger, en app.
--   4. La vista v_publicacion_moderacion vive en app.
--   5. RLS esta activado en las 19 tablas de app.
--   6. uuid_generate_v7() produce UUIDs validos, version 7 y ordenables.
--   7. Las PK de negocio son uuid y las de catalogo siguen siendo enteras.
--   8. Los catalogos tienen los datos semilla (ids fijos) de la migracion 0003.
-- =============================================================================

DO $$
DECLARE
    -- Entidades de negocio: PK uuid.
    tablas_negocio text[] := ARRAY[
        'usuario', 'solicitud_profesor', 'evento_cuenta', 'sesion',
        'publicacion', 'imagen_publicacion', 'archivo_por_borrar', 'moderacion'
    ];
    -- Catalogos: PK entera (smallint/bigint).
    tablas_catalogo text[] := ARRAY[
        'rol', 'audiencia', 'audiencia_rol', 'estado_publicacion',
        'estado_solicitud', 'accion_moderacion', 'tipo_evento_cuenta',
        'categoria', 'etiqueta', 'publicacion_etiqueta', 'refresh_token'
    ];
    -- Funciones que DEBEN estar en public.
    funcs_public text[] := ARRAY[
        'uuid_generate_v7', 'f_unaccent', 'publicacion_documento',
        'f_normalizar_etiqueta', 'audiencia_visible_para', 'limpiar_datos_vencidos'
    ];
    -- Funciones de trigger que DEBEN estar en app.
    funcs_app text[] := ARRAY[
        'trg_fijar_actualizado_en', 'trg_columnas_inmutables',
        'trg_solicitud_transicion', 'trg_bloquear_cambios_admin',
        'trg_garantizar_admin_activo', 'trg_prohibir_borrado',
        'trg_categoria_activa', 'trg_historial_inmutable',
        'trg_encolar_archivo_borrado'
    ];
    t          text;
    fn         text;
    n          integer;
    tipo_pk    text;
    u1         uuid;
    u2         uuid;
    ver        integer;
BEGIN
    RAISE NOTICE '--- 1. Esquemas ---';
    FOREACH t IN ARRAY ARRAY['app', 'public', 'extensions'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = t) THEN
            RAISE EXCEPTION 'Falta el esquema %', t;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: existen app, public, extensions.';

    RAISE NOTICE '--- 2. Las 19 tablas viven en app (ninguna en public) ---';
    FOREACH t IN ARRAY (tablas_negocio || tablas_catalogo) LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_tables WHERE schemaname = 'app' AND tablename = t
        ) THEN
            RAISE EXCEPTION 'La tabla %.% no existe en el esquema app', 'app', t;
        END IF;
        IF EXISTS (
            SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = t
        ) THEN
            RAISE EXCEPTION 'La tabla % quedo en public (deberia estar solo en app)', t;
        END IF;
    END LOOP;
    SELECT count(*) INTO n FROM pg_tables WHERE schemaname = 'app';
    IF n <> 19 THEN
        RAISE EXCEPTION 'El esquema app tiene % tablas, se esperaban 19', n;
    END IF;
    RAISE NOTICE 'OK: 19 tablas en app, 0 en public.';

    RAISE NOTICE '--- 3. Funciones por esquema ---';
    FOREACH fn IN ARRAY funcs_public LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
            WHERE ns.nspname = 'public' AND p.proname = fn
        ) THEN
            RAISE EXCEPTION 'Falta la funcion public.%()', fn;
        END IF;
    END LOOP;
    FOREACH fn IN ARRAY funcs_app LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
            WHERE ns.nspname = 'app' AND p.proname = fn
        ) THEN
            RAISE EXCEPTION 'Falta la funcion de trigger app.%()', fn;
        END IF;
        -- Ninguna funcion de trigger debe haber quedado en public.
        IF EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
            WHERE ns.nspname = 'public' AND p.proname = fn
        ) THEN
            RAISE EXCEPTION 'La funcion de trigger % quedo en public (deberia estar solo en app)', fn;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: funciones de texto en public, triggers en app.';

    RAISE NOTICE '--- 4. Vista en app ---';
    IF NOT EXISTS (
        SELECT 1 FROM pg_views WHERE schemaname = 'app' AND viewname = 'v_publicacion_moderacion'
    ) THEN
        RAISE EXCEPTION 'Falta la vista app.v_publicacion_moderacion';
    END IF;
    RAISE NOTICE 'OK: app.v_publicacion_moderacion existe.';

    RAISE NOTICE '--- 5. RLS activado en las 19 tablas de app ---';
    FOREACH t IN ARRAY (tablas_negocio || tablas_catalogo) LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
            WHERE ns.nspname = 'app' AND c.relname = t AND c.relrowsecurity
        ) THEN
            RAISE EXCEPTION 'RLS NO esta activado en app.%', t;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: RLS activado en las 19 tablas.';

    RAISE NOTICE '--- 6. uuid_generate_v7(): validez, version 7 y orden ---';
    u1 := public.uuid_generate_v7();
    PERFORM pg_sleep(0.005);  -- 5 ms: garantiza timestamp distinto
    u2 := public.uuid_generate_v7();
    -- El nibble de version (digito 15 del hex, 1-based) debe ser '7'.
    ver := ('x' || substr(replace(u1::text, '-', ''), 13, 1))::bit(4)::int;
    IF ver <> 7 THEN
        RAISE EXCEPTION 'uuid_generate_v7 genero un UUID version % (se esperaba 7): %', ver, u1;
    END IF;
    -- Al ser v7 (timestamp al frente), el generado despues debe ordenar mayor.
    IF NOT (u2 > u1) THEN
        RAISE EXCEPTION 'Los UUIDv7 no son monotonos: % no es > %', u2, u1;
    END IF;
    RAISE NOTICE 'OK: UUIDv7 valido (version 7) y ordenable en el tiempo. Muestra: %', u1;

    RAISE NOTICE '--- 7. Tipos de PK (negocio=uuid, catalogo=entero) ---';
    FOREACH t IN ARRAY tablas_negocio LOOP
        SELECT format_type(a.atttypid, a.atttypmod) INTO tipo_pk
        FROM pg_attribute a
        JOIN pg_class c   ON c.oid = a.attrelid
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'app' AND c.relname = t AND a.attname = 'id';
        IF tipo_pk IS DISTINCT FROM 'uuid' THEN
            RAISE EXCEPTION 'La PK de app.% es % (se esperaba uuid)', t, tipo_pk;
        END IF;
    END LOOP;
    -- Catalogos con columna id entera (audiencia_rol, publicacion_etiqueta y
    -- refresh_token tienen PK compuesta/alterna: se omiten de esta comprobacion).
    FOREACH t IN ARRAY ARRAY['rol','audiencia','estado_publicacion','estado_solicitud',
                             'accion_moderacion','tipo_evento_cuenta','categoria','etiqueta'] LOOP
        SELECT format_type(a.atttypid, a.atttypmod) INTO tipo_pk
        FROM pg_attribute a
        JOIN pg_class c   ON c.oid = a.attrelid
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'app' AND c.relname = t AND a.attname = 'id';
        IF tipo_pk NOT IN ('smallint', 'bigint', 'integer') THEN
            RAISE EXCEPTION 'La PK de app.% es % (se esperaba smallint/bigint)', t, tipo_pk;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: PK de negocio uuid, PK de catalogo enteras.';

    RAISE NOTICE '--- 8. Datos semilla de catalogos (migracion 0003) ---';
    IF (SELECT count(*) FROM app.rol)                <> 3 THEN RAISE EXCEPTION 'rol: se esperaban 3 filas';                END IF;
    IF (SELECT count(*) FROM app.audiencia)          <> 4 THEN RAISE EXCEPTION 'audiencia: se esperaban 4 filas';          END IF;
    IF (SELECT count(*) FROM app.estado_publicacion) <> 3 THEN RAISE EXCEPTION 'estado_publicacion: se esperaban 3 filas'; END IF;
    IF (SELECT count(*) FROM app.estado_solicitud)   <> 3 THEN RAISE EXCEPTION 'estado_solicitud: se esperaban 3 filas';   END IF;
    IF (SELECT count(*) FROM app.accion_moderacion)  <> 4 THEN RAISE EXCEPTION 'accion_moderacion: se esperaban 4 filas';  END IF;
    IF (SELECT count(*) FROM app.tipo_evento_cuenta) <> 3 THEN RAISE EXCEPTION 'tipo_evento_cuenta: se esperaban 3 filas'; END IF;
    IF (SELECT count(*) FROM app.categoria)          <> 10 THEN RAISE EXCEPTION 'categoria: se esperaban 10 filas';        END IF;
    -- Un id fijo clave: rol administrador = 3 (lo usan CHECK e indices parciales).
    IF NOT EXISTS (SELECT 1 FROM app.rol WHERE id = 3 AND codigo = 'administrador') THEN
        RAISE EXCEPTION 'El rol administrador debe tener id = 3 (seed)';
    END IF;
    RAISE NOTICE 'OK: catalogos sembrados con los ids fijos esperados.';

    RAISE NOTICE '==============================================';
    RAISE NOTICE 'VERIFICACION OK: esquema hibrido app/public correcto.';
    RAISE NOTICE '==============================================';
END
$$;
