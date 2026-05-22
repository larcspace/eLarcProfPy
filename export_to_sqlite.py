import os
import sys
import json
import pandas as pd
from sqlalchemy import create_engine, text
from common.database import db

# Chemin du fichier SQLite de sortie
SQLITE_PATH = "elarc.db"

def get_pg_engine():
    """Retourne un moteur SQLAlchemy pour PostgreSQL."""
    # Utiliser la connexion déjà établie par db
    if db.server_conn is not None:
        # On utilise l'URL de connexion depuis la configuration
        url = db.get_sqlalchemy_url('IntranetDatabase')
        return create_engine(url)
    # Sinon, essayer de se connecter à l'Intranet
    if db.connect_intranet():
        url = db.get_sqlalchemy_url('IntranetDatabase')
        return create_engine(url)
    # Sinon, essayer le Cloud
    if db.connect_cloud():
        url = db.get_sqlalchemy_url('SupabaseDatabase')
        return create_engine(url)
    raise Exception("Aucune connexion PostgreSQL disponible")

def get_sqlite_engine():
    """Retourne un moteur SQLAlchemy pour SQLite."""
    return create_engine(f"sqlite:///{SQLITE_PATH}")

def export_table(pg_engine, sqlite_engine, table_name):
    """Exporte une table PostgreSQL vers SQLite en utilisant Pandas."""
    try:
        # Lire la table PostgreSQL dans un DataFrame
        query = f'SELECT * FROM public."{table_name}"'
        print(f"DEBUG: Exécution de la requête pour {table_name}")
        df = pd.read_sql_query(query, pg_engine)

        print(f"DEBUG: {table_name} - DataFrame shape: {df.shape}")
        print(f"DEBUG: {table_name} - Colonnes: {list(df.columns)}")
        if not df.empty:
            print(f"DEBUG: {table_name} - Première ligne: {df.iloc[0].to_dict()}")

        if df.empty:
            print(f"Table {table_name} : 0 lignes")
            return

        # Convertir les colonnes de type datetime en chaînes ISO
        for col in df.select_dtypes(include=['datetime64', 'datetime64[ns]']).columns:
            df[col] = df[col].dt.strftime('%Y-%m-%d %H:%M:%S')

        # Convertir les colonnes de type date en chaînes ISO
        for col in df.select_dtypes(include=['datetime64[ns]']).columns:
            df[col] = df[col].dt.strftime('%Y-%m-%d')

        # Convertir les colonnes de type time en chaînes ISO
        for col in df.select_dtypes(include=['timedelta64[ns]']).columns:
            df[col] = df[col].apply(lambda x: str(x) if pd.notna(x) else None)

        # Convertir les colonnes de type json/jsonb en chaînes JSON
        for col in df.select_dtypes(include=['object']).columns:
            # Vérifier si la colonne contient des dicts/lists
            if df[col].apply(lambda x: isinstance(x, (dict, list))).any():
                df[col] = df[col].apply(lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x)

        # Écrire dans SQLite (remplace la table si elle existe)
        print(f"DEBUG: Écriture de {table_name} dans SQLite...")
        df.to_sql(
            name=table_name,
            con=sqlite_engine,
            if_exists='replace',
            index=False,
            method='multi'  # Insertion en bloc
        )

        print(f"Table {table_name} : {len(df)} lignes exportées")

    except Exception as e:
        print(f"Erreur lors de l'export de {table_name} : {e}")
        raise

def main():
    # Supprimer l'ancien fichier s'il existe
    if os.path.exists(SQLITE_PATH):
        os.remove(SQLITE_PATH)

    pg_engine = get_pg_engine()
    sqlite_engine = get_sqlite_engine()

    # Lister toutes les tables publiques via SQLAlchemy
    with pg_engine.connect() as conn:
        result = conn.execute(text("""
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
            ORDER BY table_name
        """))
        tables = [row[0] for row in result]

    print(f"Tables trouvées : {len(tables)}")

    for table in tables:
        export_table(pg_engine, sqlite_engine, table)

    pg_engine.dispose()
    sqlite_engine.dispose()
    print(f"Export terminé. Fichier créé : {SQLITE_PATH}")

if __name__ == "__main__":
    main()
