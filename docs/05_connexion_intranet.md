# Connexion à l'intranet

**Fichier :** `common/database.py` – méthode `connect_intranet()`

## Rôle

Établir une connexion PostgreSQL vers la base intranet.

## Algorithme

1. Vérifier que `psycopg2` est installé.
2. Fermer la connexion intranet précédente si elle existe.
3. Lire les paramètres de connexion depuis la section `IntranetDatabase` du fichier `config.ini` via `_pg_params('IntranetDatabase')`.
4. Tenter `psycopg2.connect(**params)`.
5. Activer `autocommit = True`.
6. Mettre à jour `db.mode = DBMode.INTRANET`.
7. En cas d'échec, `db.mode = DBMode.NONE`.

## Dépendances

- `psycopg2`
- `configparser`
- `common.database._find_cfg`
- `common.logger.log`
