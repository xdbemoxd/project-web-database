"""base: extensiones de Postgres

- citext:   correo único sin distinguir mayúsculas (F1.1).
- unaccent: búsqueda sin tildes (F3.4).
- pg_trgm:  búsqueda por similitud de texto (F3.4).

Se instalan en el esquema `extensions`, igual que en Supabase, y ese esquema se agrega al
search_path de la base para que en local los tipos y funciones se resuelvan igual que en prod.

Revision ID: 0001
Revises:
Create Date: 2026-09-27
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

EXTENSIONS = ("citext", "unaccent", "pg_trgm")


def upgrade() -> None:
    op.execute("CREATE SCHEMA IF NOT EXISTS extensions")
    for ext in EXTENSIONS:
        op.execute(f'CREATE EXTENSION IF NOT EXISTS "{ext}" WITH SCHEMA extensions')
    # En Supabase el search_path ya incluye `extensions` y el rol puede no tener permiso
    # para cambiarlo: en ese caso se ignora.
    op.execute(
        """
        DO $body$
        BEGIN
            EXECUTE format(
                'ALTER DATABASE %I SET search_path TO "$user", public, extensions',
                current_database()
            );
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'search_path no modificado (sin privilegios)';
        END
        $body$;
        """
    )
    op.execute('SET search_path TO "$user", public, extensions')


def downgrade() -> None:
    for ext in reversed(EXTENSIONS):
        op.execute(f'DROP EXTENSION IF EXISTS "{ext}"')
