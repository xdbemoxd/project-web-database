"""modelo físico: tablas, restricciones, índices, funciones, vista y triggers

Ejecuta migrations/sql/0002_modelo_fisico.sql, copia congelada de docs/base-de-datos/schema.sql.
Autogenerate no detecta funciones, triggers, configuraciones de texto ni índices por expresión,
por eso el DDL va escrito a mano (ver modelo-de-datos.md, sección 10).

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-28
"""

from collections.abc import Sequence
from pathlib import Path

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SQL_FILE = Path(__file__).resolve().parents[1] / "sql" / "0002_modelo_fisico.sql"

TABLES = (
    "moderacion",
    "archivo_por_borrar",
    "publicacion_etiqueta",
    "etiqueta",
    "imagen_publicacion",
    "publicacion",
    "categoria",
    "refresh_token",
    "sesion",
    "evento_cuenta",
    "solicitud_profesor",
    "usuario",
    "tipo_evento_cuenta",
    "accion_moderacion",
    "estado_solicitud",
    "estado_publicacion",
    "audiencia_rol",
    "audiencia",
    "rol",
)

FUNCTIONS = (
    "limpiar_datos_vencidos()",
    "trg_encolar_archivo_borrado()",
    "trg_historial_inmutable()",
    "trg_categoria_activa()",
    "trg_prohibir_borrado()",
    "trg_garantizar_admin_activo()",
    "trg_bloquear_cambios_admin()",
    "trg_solicitud_transicion()",
    "trg_columnas_inmutables()",
    "trg_fijar_actualizado_en()",
    "audiencia_visible_para(integer, integer)",
    "f_normalizar_etiqueta(text)",
    "publicacion_documento(text, text)",
    "f_unaccent(text)",
)


def _execute_script(sql: str) -> None:
    # Conexión psycopg cruda: sin parámetros no interpreta ':' ni '%' (hay "::regconfig" y
    # "LIKE '$argon2%'") y acepta varias sentencias en una sola llamada.
    op.get_bind().connection.driver_connection.execute(sql)


def upgrade() -> None:
    _execute_script(SQL_FILE.read_text(encoding="utf-8"))
    # alembic_version también vive en public: sin RLS, Supabase la marca como expuesta.
    op.execute("ALTER TABLE IF EXISTS alembic_version ENABLE ROW LEVEL SECURITY")


def downgrade() -> None:
    op.execute("DROP VIEW IF EXISTS v_publicacion_moderacion")
    for table in TABLES:
        op.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
    for function in FUNCTIONS:
        op.execute(f"DROP FUNCTION IF EXISTS public.{function}")
    op.execute("DROP TEXT SEARCH CONFIGURATION IF EXISTS public.es_unaccent")
