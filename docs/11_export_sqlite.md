# Export des tables vers SQLite

**Fichier :** `export_to_sqlite.py`

## Rôle

Exporter les tables PostgreSQL vers une base SQLite (utilisé pour la synchronisation).

## Algorithme

1. `get_pg_engine()` : créer un moteur SQLAlchemy pour PostgreSQL.
2. `get_sqlite_engine()` : créer un moteur SQLAlchemy pour SQLite.
3. `export_table(pg_engine, sqlite_engine, table_name)` :
   - Lire les données de la table PostgreSQL.
   - Écrire les données dans la table SQLite correspondante.
4. `main()` : itérer sur une liste de tables et appeler `export_table` pour chacune.

## Dépendances

- `sqlalchemy`
- `psycopg2`
- `common.database.db`
