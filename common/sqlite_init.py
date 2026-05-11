import os
import hashlib
from typing import Optional

from .session import AuthResult
from .database import db


_DDL = """
CREATE TABLE IF NOT EXISTS session_cache (
    user_id    INTEGER PRIMARY KEY,
    email      TEXT    NOT NULL,
    full_name  TEXT    NOT NULL,
    role       TEXT    NOT NULL,
    term_id    INTEGER DEFAULT 0,
    term_label TEXT    DEFAULT '',
    pin_hash   TEXT,
    updated_at TEXT    DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sync_cursor (
    table_name TEXT    PRIMARY KEY,
    max_rev    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS module_config (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    annee_scolaire TEXT NOT NULL,
    trimestre_courant INTEGER NOT NULL,
    nom_professeur TEXT NOT NULL,
    email_professeur TEXT NOT NULL,
    date_creation_module TEXT NOT NULL DEFAULT (datetime('now')),
    derniere_synchronisation TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


class SQLiteInit:
    def init(self, db_path: str = '') -> bool:
        if not db_path:
            db_path = os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), '..', 'elarc.db'
            ))
        if not db.connect_sqlite(db_path):
            return False
        conn = db.local_conn
        if conn is None:
            return False
        conn.executescript(_DDL)
        conn.commit()
        return True

    def save_session(self, result: AuthResult, pin: str = '') -> None:
        conn = db.local_conn
        if conn is None:
            return
        pin_hash = hashlib.sha256(pin.encode('utf-8')).hexdigest() if pin else None
        conn.execute(
            """INSERT INTO session_cache
                   (user_id, email, full_name, role, term_id, term_label, pin_hash, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
               ON CONFLICT(user_id) DO UPDATE SET
                   email      = excluded.email,
                   full_name  = excluded.full_name,
                   role       = excluded.role,
                   term_id    = excluded.term_id,
                   term_label = excluded.term_label,
                   pin_hash   = COALESCE(excluded.pin_hash, pin_hash),
                   updated_at = excluded.updated_at""",
            (result.user_id, result.email, result.full_name,
             result.role.value, result.term_id, result.term_label, pin_hash)
        )
        conn.commit()

    def init_module_config(self, annee_scolaire: str,
                           trimestre_courant: int,
                           nom_professeur: str,
                           email_professeur: str) -> None:
        """Insère ou met à jour la ligne unique de module_config."""
        conn = db.local_conn
        if conn is None:
            return
        conn.execute('''
            INSERT INTO module_config (id, annee_scolaire, trimestre_courant,
                                       nom_professeur, email_professeur,
                                       date_creation_module, derniere_synchronisation)
            VALUES (1, ?, ?, ?, ?, datetime('now'), datetime('now'))
            ON CONFLICT(id) DO UPDATE SET
                annee_scolaire = excluded.annee_scolaire,
                trimestre_courant = excluded.trimestre_courant,
                nom_professeur = excluded.nom_professeur,
                email_professeur = excluded.email_professeur,
                derniere_synchronisation = excluded.derniere_synchronisation
        ''', (annee_scolaire, trimestre_courant, nom_professeur, email_professeur))
        conn.commit()

    def read_cursor(self, table: str) -> int:
        conn = db.local_conn
        if conn is None:
            return 0
        row = conn.execute(
            "SELECT max_rev FROM sync_cursor WHERE table_name = ?", (table,)
        ).fetchone()
        return int(row[0]) if row else 0

    def update_cursor(self, table: str, max_rev: int) -> None:
        conn = db.local_conn
        if conn is None:
            return
        conn.execute(
            """INSERT INTO sync_cursor (table_name, max_rev) VALUES (?, ?)
               ON CONFLICT(table_name) DO UPDATE SET max_rev = excluded.max_rev""",
            (table, max_rev)
        )
        conn.commit()


sqlite_init = SQLiteInit()
