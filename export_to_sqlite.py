import psycopg2
import sqlite3
import os
import datetime
import json

# Configuration PostgreSQL
PG_HOST = "localhost"
PG_PORT = 5432
PG_DB = "LarcIntranet"
PG_USER = "postgres"
PG_PASSWORD = "postgres"

# Chemin du fichier SQLite de sortie
SQLITE_PATH = "elarc.db"

def get_pg_connection():
    return psycopg2.connect(
        host=PG_HOST,
        port=PG_PORT,
        dbname=PG_DB,
        user=PG_USER,
        password=PG_PASSWORD
    )

def get_sqlite_connection():
    return sqlite3.connect(SQLITE_PATH)

def export_table(pg_conn, sqlite_conn, table_name):
    """Exporte une table PostgreSQL vers SQLite."""
    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Récupérer les colonnes et leurs types
    pg_cursor.execute(f"""
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = '{table_name}'
        ORDER BY ordinal_position
    """)
    columns = pg_cursor.fetchall()

    if not columns:
        print(f"Table {table_name} introuvable, ignorée.")
        return

    # Construire le CREATE TABLE SQLite
    col_defs = []
    for col_name, col_type in columns:
        # Conversion des types PostgreSQL vers SQLite
        if col_type in ('integer', 'smallint', 'bigint', 'serial', 'bigserial'):
            sqlite_type = 'INTEGER'
        elif col_type in ('real', 'double precision', 'numeric', 'float'):
            sqlite_type = 'REAL'
        elif col_type in ('boolean',):
            sqlite_type = 'INTEGER'
        elif col_type in ('bytea',):
            sqlite_type = 'BLOB'
        elif col_type in ('json', 'jsonb'):
            sqlite_type = 'TEXT'
        else:
            sqlite_type = 'TEXT'
        col_defs.append(f'"{col_name}" {sqlite_type}')

    create_sql = f'CREATE TABLE IF NOT EXISTS "{table_name}" ({", ".join(col_defs)})'
    sqlite_cursor.execute(create_sql)

    # Récupérer les données
    pg_cursor.execute(f'SELECT * FROM public."{table_name}"')
    rows = pg_cursor.fetchall()

    if not rows:
        print(f"Table {table_name} : 0 lignes")
        return

    # Insérer les données
    placeholders = ", ".join("?" for _ in columns)
    col_names = ", ".join(f'"{c[0]}"' for c in columns)
    insert_sql = f'INSERT INTO "{table_name}" ({col_names}) VALUES ({placeholders})'

    for row in rows:                                                                           
        # Convertir les types spéciaux (bytea, time, json, etc.)                               
        converted_row = []                                                                     
        for val in row:                                                                        
            if isinstance(val, memoryview):                                                    
                val = bytes(val)                                                               
            elif isinstance(val, bytearray):                                                   
                val = bytes(val)                                                               
            elif isinstance(val, datetime.time):                                               
                val = val.isoformat()  # Convertir time en texte                               
            elif isinstance(val, datetime.date):                                               
                val = val.isoformat()  # Convertir date en texte                               
            elif isinstance(val, datetime.datetime):                                           
                val = val.isoformat()  # Convertir datetime en texte                           
            elif isinstance(val, (dict, list)):                                                
                import json                                                                    
                val = json.dumps(val)  # Convertir jsonb en texte JSON                         
            elif val is None:                                                                  
                pass                                                                           
            converted_row.append(val)                                                          
        sqlite_cursor.execute(insert_sql, converted_row)                                                           

    sqlite_conn.commit()
    print(f"Table {table_name} : {len(rows)} lignes exportées")

def main():
    # Supprimer l'ancien fichier s'il existe
    if os.path.exists(SQLITE_PATH):
        os.remove(SQLITE_PATH)

    pg_conn = get_pg_connection()
    sqlite_conn = get_sqlite_connection()

    # Lister toutes les tables publiques
    pg_cursor = pg_conn.cursor()
    pg_cursor.execute("""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name
    """)
    tables = [row[0] for row in pg_cursor.fetchall()]

    print(f"Tables trouvées : {len(tables)}")

    for table in tables:
        export_table(pg_conn, sqlite_conn, table)

    pg_conn.close()
    sqlite_conn.close()
    print(f"Export terminé. Fichier créé : {SQLITE_PATH}")

if __name__ == "__main__":
    main()
