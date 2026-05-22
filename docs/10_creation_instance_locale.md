# Création de l'instance locale SQLite

**Fichier :** `common/sqlite_init.py` – classe `SQLiteInit`

## Rôle

Initialiser la base SQLite locale et copier les données de l'enseignant depuis le serveur.

## Algorithme

1. `init(db_path)` :
   - Créer la base SQLite si elle n'existe pas.
   - Créer les tables nécessaires (session_cache, module_config, etc.).
2. `save_session(result, pin)` :
   - Insérer ou mettre à jour la session dans `session_cache`.
3. `init_module_config(annee_scolaire, trimestre_courant, nom_professeur, ...)` :
   - Configurer les paramètres du module dans la base locale.
4. `take_teacher_data(infos, log_fn, conn_sqlite, conn_pg)` :
   - Copier les tables de l'enseignant depuis le serveur PostgreSQL vers la base SQLite locale.
   - Utiliser `_create_table_from_data` et `_insert_rows_from_data`.

## Dépendances

- `sqlite3`
- `common.database.db`
- `common.session.session`
- `common.logger.log`
