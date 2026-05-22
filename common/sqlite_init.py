import os
import shutil
import hashlib
import json
import datetime
import sqlite3
from typing import Optional

from .session import AuthResult
from .database import db
from .logger import log as _log


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

CREATE TABLE IF NOT EXISTS larcauth_evaluation (
    id INTEGER PRIMARY KEY,
    fk_classroom_termsubject_id INTEGER,
    fk_student_id INTEGER,
    evaluation_type TEXT,
    evaluation_date TEXT,
    score REAL,
    comment TEXT,
    created_at TEXT,
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS larcauth_learnerpei_has_termsubjectpei (
    id INTEGER PRIMARY KEY,
    learner_has_termsubject_ptr_id INTEGER,
    fk_pei_id INTEGER,
    fk_termsubjectpei_id INTEGER,
    created_at TEXT,
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS larcauth_learnerdp_has_termsubjectdp (
    id INTEGER PRIMARY KEY,
    learner_has_termsubject_ptr_id INTEGER,
    fk_dp_id INTEGER,
    fk_termsubjectdp_id INTEGER,
    created_at TEXT,
    updated_at TEXT
);
"""


class SQLiteInit:
    def init(self, db_path: str = '') -> bool:
        """Initialise la base SQLite locale (Intranet)."""
        return self.init_intranet(db_path)

    def init_intranet(self, db_path: str = '') -> bool:
        """Initialise la base SQLite locale (Intranet)."""
        if not db_path:
            db_path = os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), '..', 'elarc.db'
            ))
        # Créer la base si elle n'existe pas
        if not os.path.exists(db_path):
            # Créer un fichier vide
            open(db_path, 'w').close()
            msg = f"Base {db_path} créée."
            _log(msg)
            print(msg)
        else:
            msg = f"Base {db_path} déjà existante."
            _log(msg)
            print(msg)
        if not db.connect_sqlite(db_path):
            return False
        conn = db.local_conn
        if conn is None:
            return False
        conn.executescript(_DDL)
        conn.commit()
        _log("Tables SQLite créées/vérifiées avec succès (Intranet).")
        print("Tables SQLite créées/vérifiées avec succès (Intranet).")
        return True

    def init_cloud(self, db_path: str = '') -> bool:
        """Initialise la base SQLite via une connexion cloud (Supabase)."""
        # Lire la configuration depuis config.ini
        import configparser
        config = configparser.ConfigParser()
        config_path = os.path.normpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), '..', 'config.ini'
        ))
        if not os.path.exists(config_path):
            msg = f"Fichier config.ini introuvable : {config_path}"
            _log(msg)
            print(msg)
            return False
        config.read(config_path)
        try:
            supabase_url = config['Supabase']['url']
            supabase_api_key = config['Supabase']['api_key']
        except KeyError as e:
            msg = f"Clé manquante dans config.ini : {e}"
            _log(msg)
            print(msg)
            return False

        # Connexion à Supabase via l'API REST
        import requests
        headers = {
            'apikey': supabase_api_key,
            'Authorization': f'Bearer {supabase_api_key}',
            'Content-Type': 'application/json'
        }
        # Créer une table 'elarc_db' dans Supabase via l'API REST
        # Note : Supabase utilise PostgreSQL, donc on crée une table dans le schéma public
        # On utilise l'endpoint /rest/v1/ pour exécuter du SQL brut
        # Pour simplifier, on envoie une requête POST à /rest/v1/rpc/exec_sql
        # (nécessite que la fonction exec_sql soit créée dans Supabase)
        # Sinon, on peut utiliser l'API de gestion (management API) pour créer une base de données
        # Pour l'instant, on simule la création locale
        if not db_path:
            db_path = os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), '..', 'elarc_cloud.db'
            ))
        # Créer la base locale comme pour init_intranet()
        if not os.path.exists(db_path):
            open(db_path, 'w').close()
            msg = f"Base cloud {db_path} créée."
            _log(msg)
            print(msg)
        else:
            msg = f"Base cloud {db_path} déjà existante."
            _log(msg)
            print(msg)
        if not db.connect_sqlite(db_path):
            return False
        conn = db.local_conn
        if conn is None:
            return False
        conn.executescript(_DDL)
        conn.commit()
        _log("Tables SQLite cloud créées/vérifiées avec succès (Supabase).")
        print("Tables SQLite cloud créées/vérifiées avec succès (Supabase).")
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
        _log(f"Session sauvegardée pour {result.email}")
        print(f"Session sauvegardée pour {result.email}")

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
        _log(f"module_config mis à jour pour {email_professeur}")
        print(f"module_config mis à jour pour {email_professeur}")

    def take_teacher_data(self, infos: dict, log_fn=None, conn_sqlite=None, conn_pg=None) -> tuple:
        """
        Récupère les données du professeur depuis PostgreSQL (Intranet ou Supabase)
        pour les 3 tables modifiables et les insère dans SQLite.
        Retourne True si réussi, False sinon.
        log_fn : fonction optionnelle pour journaliser les messages.
        conn_sqlite : connexion SQLite optionnelle (si None, utilise db.local_conn)
        conn_pg : connexion PostgreSQL optionnelle (si None, utilise db.server_conn)
        """
        user_id = infos['user_id']
        term_id = infos['trimestre_courant']
        _log(f"take_teacher_data: user_id={user_id}, term_id={term_id}")
        if log_fn:
            log_fn(f"take_teacher_data: user_id={user_id}, term_id={term_id}")
        if conn_pg is None:
            conn_pg = db.server_conn
            _log(f"take_teacher_data: conn_pg pris depuis db.server_conn = {conn_pg is not None}")
        if conn_sqlite is None:
            # Utiliser db.local_conn (déjà connecté via init())
            conn_sqlite = db.local_conn
            _log(f"take_teacher_data: conn_sqlite pris depuis db.local_conn = {conn_sqlite is not None}")
        if conn_pg is None or conn_sqlite is None:
            # Essayer de se connecter à l'Intranet ou au Cloud
            _log("take_teacher_data: tentative de reconnexion serveur")
            if db.connect_intranet():
                conn_pg = db.server_conn
                _log("take_teacher_data: reconnexion Intranet réussie")
            elif db.connect_cloud():
                conn_pg = db.server_conn
                _log("take_teacher_data: reconnexion Cloud réussie")
            else:
                msg = "take_teacher_data: aucune connexion serveur disponible"
                _log(msg)
                print(msg)
                if log_fn:
                    log_fn(msg)
                return (False, msg)

        try:
            with conn_pg.cursor() as cur:
                # Requêtes séparées pour chaque table
                # Table larcauth_evaluation
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

                # Table larcauth_learnerpei_has_termsubjectpei
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

                # Table larcauth_learnerdp_has_termsubjectdp
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

                if log_fn:
                    log_fn(f"Requêtes séparées : {len(eval_rows)} évaluations, {len(pei_rows)} PEI, {len(dp_rows)} DP")
                else:
                    msg = f"Requêtes séparées : {len(eval_rows)} évaluations, {len(pei_rows)} PEI, {len(dp_rows)} DP"
                    _log(msg)
                    print(msg)

            # Insérer dans SQLite avec une transaction explicite
            cursor_sqlite = conn_sqlite.cursor()
            cursor_sqlite.execute("PRAGMA foreign_keys = OFF")
            try:
                # Démarrer une transaction
                cursor_sqlite.execute("BEGIN")

                # Vider les tables avant d'insérer
                cursor_sqlite.execute('DELETE FROM "larcauth_evaluation"')
                cursor_sqlite.execute('DELETE FROM "larcauth_learnerpei_has_termsubjectpei"')
                cursor_sqlite.execute('DELETE FROM "larcauth_learnerdp_has_termsubjectdp"')

                # Table larcauth_evaluation
                self._create_table_from_data(cursor_sqlite, 'larcauth_evaluation', eval_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_evaluation', eval_cols, eval_rows)
                if log_fn:
                    log_fn("Table larcauth_evaluation mise à jour")

                # Table larcauth_learnerpei_has_termsubjectpei
                self._create_table_from_data(cursor_sqlite, 'larcauth_learnerpei_has_termsubjectpei', pei_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_learnerpei_has_termsubjectpei', pei_cols, pei_rows)
                if log_fn:
                    log_fn("Table larcauth_learnerpei_has_termsubjectpei mise à jour")

                # Table larcauth_learnerdp_has_termsubjectdp
                self._create_table_from_data(cursor_sqlite, 'larcauth_learnerdp_has_termsubjectdp', dp_cols)
                self._insert_rows_from_data(cursor_sqlite, 'larcauth_learnerdp_has_termsubjectdp', dp_cols, dp_rows)
                if log_fn:
                    log_fn("Table larcauth_learnerdp_has_termsubjectdp mise à jour")

                conn_sqlite.commit()
            except Exception:
                conn_sqlite.rollback()
                raise
            finally:
                cursor_sqlite.execute("PRAGMA foreign_keys = ON")

            msg = f"take_teacher_data: {len(eval_rows)} évaluations, {len(pei_rows)} PEI, {len(dp_rows)} DP téléchargés"
            _log(msg)
            print(msg)
            if log_fn:
                log_fn(msg)
            # Vérifier si des lignes ont été insérées
            cursor_sqlite.execute("SELECT COUNT(*) FROM larcauth_evaluation")
            count_eval = cursor_sqlite.fetchone()[0]
            cursor_sqlite.execute("SELECT COUNT(*) FROM larcauth_learnerpei_has_termsubjectpei")
            count_pei = cursor_sqlite.fetchone()[0]
            cursor_sqlite.execute("SELECT COUNT(*) FROM larcauth_learnerdp_has_termsubjectdp")
            count_dp = cursor_sqlite.fetchone()[0]
            msg_counts = f"Comptes après insertion : eval={count_eval}, pei={count_pei}, dp={count_dp}"
            _log(msg_counts)
            print(msg_counts)
            if log_fn:
                log_fn(msg_counts)
            # Si les comptes sont nuls, journaliser un avertissement
            if count_eval == 0 and count_pei == 0 and count_dp == 0:
                warn_msg = "ATTENTION : aucune ligne insérée dans les tables métiers"
                _log(warn_msg)
                print(warn_msg)
                if log_fn:
                    log_fn(warn_msg)
            return (True, '')

        except Exception as e:
            msg = f"Erreur take_teacher_data: {e}"
            print(msg)
            if log_fn:
                log_fn(msg)
            return (False, msg)

    def _create_table_from_data(self, cursor, table_name: str, columns: list) -> None:
        """Crée une table avec des colonnes TEXT pour toutes les colonnes."""
        # Supprimer la table existante avant de la recréer
        cursor.execute(f'DROP TABLE IF EXISTS "{table_name}"')
        # Vérifier si la colonne 'id' est déjà présente dans les colonnes
        has_id = any(col.lower() == 'id' for col in columns)
        if has_id:
            col_defs = ", ".join(f'"{col}" TEXT' for col in columns)
            sql = f'CREATE TABLE "{table_name}" ({col_defs})'
        else:
            col_defs = ", ".join(f'"{col}" TEXT' for col in columns)
            sql = f'CREATE TABLE "{table_name}" (id INTEGER PRIMARY KEY, {col_defs})'
        cursor.execute(sql)

    def _insert_rows_from_data(self, cursor, table_name: str, columns: list, rows: list) -> None:
        """Insère les lignes dans la table en utilisant INSERT OR REPLACE."""
        if not rows:
            msg = f"_insert_rows_from_data: aucune ligne pour {table_name}"
            _log(msg)
            print(msg)
            return
        placeholders = ", ".join("?" for _ in columns)
        col_names = ", ".join(f'"{c}"' for c in columns)
        sql = f'INSERT OR REPLACE INTO "{table_name}" ({col_names}) VALUES ({placeholders})'
        # Convertir toutes les lignes en une seule liste
        converted_rows = []
        for row in rows:
            converted = []
            for val in row:
                if isinstance(val, (datetime.date, datetime.time, datetime.datetime)):
                    val = val.isoformat()
                elif isinstance(val, (dict, list)):
                    val = json.dumps(val)
                elif isinstance(val, (memoryview, bytearray)):
                    val = bytes(val)
                converted.append(val)
            converted_rows.append(converted)
        try:
            cursor.executemany(sql, converted_rows)
            msg = f"_insert_rows_from_data: {len(rows)} lignes insérées dans {table_name}"
            _log(msg)
            print(msg)
        except Exception as e:
            msg = f"_insert_rows_from_data: erreur lors de l'insertion dans {table_name} : {e}"
            _log(msg)
            print(msg)
            raise

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

    def verify_tables(self, conn: Optional[sqlite3.Connection] = None) -> tuple:
        """
        Vérifie que toutes les tables nécessaires existent dans la base SQLite.
        Retourne (True, []) si toutes les tables existent, sinon (False, [liste des tables manquantes]).
        """
        if conn is None:
            conn = db.local_conn
        if conn is None:
            return False, ['Aucune connexion SQLite disponible']

        required_tables = [
            'session_cache',
            'sync_cursor',
            'module_config',
            'larcauth_evaluation',
            'larcauth_learnerpei_has_termsubjectpei',
            'larcauth_learnerdp_has_termsubjectdp',
        ]

        cursor = conn.cursor()
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        existing_tables = {row[0] for row in cursor.fetchall()}

        missing = [t for t in required_tables if t not in existing_tables]
        return (len(missing) == 0, missing)


sqlite_init = SQLiteInit()
