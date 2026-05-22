# Connexion au cloud (Supabase)

**Fichier :** `common/database.py` – méthode `connect_cloud()`

## Rôle

Établir une connexion PostgreSQL vers Supabase.

## Algorithme

1. Vérifier que `psycopg2` est installé.
2. Fermer la connexion cloud précédente si elle existe.
3. Lire les paramètres depuis la section `SupabaseDatabase` du fichier `config.ini` via `_pg_params('SupabaseDatabase')`.
4. Tenter `psycopg2.connect(**params)`.
5. Activer `autocommit = True`.
6. Mettre à jour `db.mode = DBMode.CLOUD`.
7. En cas d'échec, `db.mode = DBMode.NONE`.

## Dépendances

- `psycopg2`
- `configparser`
- `common.database._find_cfg`
- `common.logger.log`
