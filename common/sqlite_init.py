import os
import hashlib
import json
import datetime
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

    def take_teacher_data(self, user_id: int, term_id: int) -> bool:
        """
        Récupère les données du professeur depuis PostgreSQL (Intranet)
        pour les 3 tables modifiables et les insère dans SQLite.
        Retourne True si réussi, False sinon.
        """
        conn_pg = db.server_conn
        conn_sqlite = db.local_conn
        if conn_pg is None or conn_sqlite is None:
            return False

        try:
            with conn_pg.cursor() as cur:
                # 1. larcauth_evaluation
                cur.execute("""
                    SELECT e.*
                    FROM public.larcauth_evaluation e
                    JOIN public.larcauth_classroom_termsubject cts ON cts.id = e.fk_classroom_termsubject_id
                    JOIN public.larcauth_classroom c ON c.id = cts.fk_classroom_id
                    WHERE cts.fk_teacher_id = %s
                      AND cts.fk_term_id = %s
                      AND cts.enabled = true
                      AND c.enabled = true
                """, (user_id, term_id))
                eval_rows = cur.fetchall()
                eval_cols = [desc[0] for desc in cur.description]

                # 2. larcauth_learnerpei_has_termsubjectpei
                cur.execute("""
                    SELECT pei.*
                    FROM public.larcauth_learnerpei_has_termsubjectpei pei
                    JOIN public.larcauth_learner_has_termsubject lht ON lht.id = pei.learner_has_termsubject_ptr_id
                    JOIN public.larcauth_classroom_termsubject cts ON cts.id = lht.fk_classroom_termsubject_id
                    JOIN public.larcauth_classroom c ON c.id = cts.fk_classroom_id
                    JOIN public.larcauth_student s ON s.aecuser_ptr_id = lht.fk_student_id
                    WHERE cts.fk_teacher_id = %s
                      AND cts.fk_term_id = %s
                      AND cts.enabled = true
                      AND c.enabled = true
                      AND s.enabled = true
                """, (user_id, term_id))
                pei_rows = cur.fetchall()
                pei_cols = [desc[0] for desc in cur.description]

                # 3. larcauth_learnerdp_has_termsubjectdp
                cur.execute("""
                    SELECT dp.*
                    FROM public.larcauth_learnerdp_has_termsubjectdp dp
                    JOIN public.larcauth_learner_has_termsubject lht ON lht.id = dp.learner_has_termsubject_ptr_id
                    JOIN public.larcauth_classroom_termsubject cts ON cts.id = lht.fk_classroom_termsubject_id
                    JOIN public.larcauth_classroom c ON c.id = cts.fk_classroom_id
                    JOIN public.larcauth_student s ON s.aecuser_ptr_id = lht.fk_student_id
                    WHERE cts.fk_teacher_id = %s
                      AND cts.fk_term_id = %s
                      AND cts.enabled = true
                      AND c.enabled = true
                      AND s.enabled = true
                """, (user_id, term_id))
                dp_rows = cur.fetchall()
                dp_cols = [desc[0] for desc in cur.description]

            # Insérer dans SQLite
            cursor_sqlite = conn_sqlite.cursor()
            cursor_sqlite.execute("PRAGMA foreign_keys = OFF")
            try:
                # Table larcauth_evaluation
                self._create_table_from_data(cursor_sqlite, 'larcauth_evaluation', eval_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_evaluation', eval_cols, eval_rows)

                # Table larcauth_learnerpei_has_termsubjectpei
                self._create_table_from_data(cursor_sqlite, 'larcauth_learnerpei_has_termsubjectpei', pei_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_learnerpei_has_termsubjectpei', pei_cols, pei_rows)

                # Table larcauth_learnerdp_has_termsubjectdp
                self._create_table_from_data(cursor_sqlite, 'larcauth_learnerdp_has_termsubjectdp', dp_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_learnerdp_has_termsubjectdp', dp_cols, dp_rows)

                conn_sqlite.commit()
            finally:
                cursor_sqlite.execute("PRAGMA foreign_keys = ON")

            return True

        except Exception as e:
            print(f"Erreur take_teacher_data: {e}")
            return False

    def _create_table_from_data(self, cursor, table_name: str, columns: list) -> None:
        """Crée une table avec des colonnes TEXT pour toutes les colonnes."""
        col_defs = ", ".join(f'"{col}" TEXT' for col in columns)
        sql = f'CREATE TABLE IF NOT EXISTS "{table_name}" (id INTEGER PRIMARY KEY, {col_defs})'
        cursor.execute(sql)

    def _insert_rows_from_data(self, cursor, table_name: str, columns: list, rows: list) -> None:
        """Insère les lignes dans la table en utilisant INSERT OR REPLACE."""
        if not rows:
            return
        placeholders = ", ".join("?" for _ in columns)
        col_names = ", ".join(f'"{c}"' for c in columns)
        sql = f'INSERT OR REPLACE INTO "{table_name}" ({col_names}) VALUES ({placeholders})'
        for row in rows:
            # Convertir les types spéciaux (datetime, etc.)
            converted = []
            for val in row:
                if isinstance(val, (datetime.date, datetime.time, datetime.datetime)):
                    val = val.isoformat()
                elif isinstance(val, (dict, list)):
                    val = json.dumps(val)
                elif isinstance(val, (memoryview, bytearray)):
                    val = bytes(val)
                converted.append(val)
            cursor.execute(sql, converted)

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
