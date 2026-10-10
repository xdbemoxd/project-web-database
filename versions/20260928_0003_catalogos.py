"""catálogos: ids fijos, matriz de visibilidad y diez categorías base (F5.10)

Mismos datos que docs/base-de-datos/seed.sql, salvo el administrador inicial, que se crea con
`python -m app.modules.identity.cli crear-admin`. Van en una migración porque el esquema los
necesita: CHECK, índices parciales, triggers y valores por defecto usan estos ids.

Revision ID: 0003
Revises: 0002
Create Date: 2026-09-28
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

CATALOGOS_SQL = """
INSERT INTO app.rol (id, codigo, nombre) VALUES
    (1, 'estudiante',    'Estudiante'),
    (2, 'profesor',      'Profesor / Investigador'),
    (3, 'administrador', 'Administrador / Moderador')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app.audiencia (id, codigo, nombre, descripcion, visible_sin_sesion) VALUES
    (1, 'publica',          'Pública',          'Todos, incluso sin iniciar sesión',        true),
    (2, 'comunidad',        'Comunidad',        'Cualquier usuario con sesión iniciada',    false),
    (3, 'solo_profesores',  'Solo profesores',  'Solo profesores y administradores',        false),
    (4, 'solo_estudiantes', 'Solo estudiantes', 'Solo estudiantes y administradores',       false)
ON CONFLICT (id) DO NOTHING;

-- Tabla 1 del documento de requisitos (F3.2). El visitante se cubre con
-- audiencia.visible_sin_sesion porque no es un rol.
INSERT INTO app.audiencia_rol (audiencia_id, rol_id) VALUES
    (1, 1), (1, 2), (1, 3),   -- Pública
    (2, 1), (2, 2), (2, 3),   -- Comunidad
            (3, 2), (3, 3),   -- Solo profesores
    (4, 1),         (4, 3)    -- Solo estudiantes
ON CONFLICT DO NOTHING;

INSERT INTO app.estado_publicacion (id, codigo, nombre) VALUES
    (1, 'visible',           'Visible'),
    (2, 'oculta_autor',      'Oculta por el autor'),
    (3, 'oculta_moderacion', 'Oculta por moderación')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app.estado_solicitud (id, codigo, nombre) VALUES
    (1, 'pendiente', 'Pendiente'),
    (2, 'aprobada',  'Aprobada'),
    (3, 'rechazada', 'Rechazada')
ON CONFLICT (id) DO NOTHING;

-- Ocultar (2) y Eliminar (4) exigen motivo: lo garantiza ck_moderacion_motivo.
INSERT INTO app.accion_moderacion (id, codigo, nombre) VALUES
    (1, 'revisar',   'Marcar como revisada'),
    (2, 'ocultar',   'Ocultar'),
    (3, 'restaurar', 'Restaurar'),
    (4, 'eliminar',  'Eliminar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app.tipo_evento_cuenta (id, codigo, nombre) VALUES
    (1, 'cambio_rol',   'Cambio de rol'),
    (2, 'desactivacion', 'Desactivación'),
    (3, 'reactivacion', 'Reactivación')
ON CONFLICT (id) DO NOTHING;

-- Diez categorías base tomadas del enunciado (F5.10, HU-26).
INSERT INTO app.categoria (nombre, descripcion, color) VALUES
    ('Eventos académicos',           'Congresos, seminarios y encuentros académicos',  '#1E40AF'),
    ('Actividades de la facultad',   'Actividades institucionales de la FaCyT',        '#0F766E'),
    ('Proyectos estudiantiles',      'Proyectos desarrollados por estudiantes',        '#7C3AED'),
    ('Defensas de TEG',              'Defensas de Trabajos Especiales de Grado',       '#B91C1C'),
    ('Talleres, charlas y jornadas', 'Talleres, charlas y jornadas abiertas',          '#C2410C'),
    ('Avisos',                       'Avisos de interés para la comunidad',            '#A16207'),
    ('Logros',                       'Logros de estudiantes y profesores',             '#15803D'),
    ('Investigación',                'Iniciativas y resultados de investigación',      '#0369A1'),
    ('Vida estudiantil',             'Cultura, deporte y vida en el campus',           '#BE185D'),
    ('Departamentos y laboratorios', 'Información de departamentos y laboratorios',    '#4B5563')
ON CONFLICT DO NOTHING;

"""


def upgrade() -> None:
    # Conexión psycopg cruda: varias sentencias en una llamada, sin interpretar ':' ni '%'.
    op.get_bind().connection.driver_connection.execute(CATALOGOS_SQL)


def downgrade() -> None:
    op.execute("DELETE FROM app.categoria")
    for table in (
        "audiencia_rol",
        "tipo_evento_cuenta",
        "accion_moderacion",
        "estado_solicitud",
        "estado_publicacion",
        "audiencia",
        "rol",
    ):
        op.execute(f"DELETE FROM app.{table}")
