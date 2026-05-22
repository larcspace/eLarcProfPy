# Logger applicatif

**Fichier :** `common/logger.py`

## Rôle

Fournir une fonction de journalisation simple, partagée par tous les modules, avec sortie vers un fichier `elarc.log` à la racine du projet. La journalisation peut être désactivée globalement via un indicateur.

## API

- `log(msg: str) -> None` — écrit `[YYYY-MM-DD HH:MM:SS] <msg>` à la suite de `elarc.log` si `LOG_TO_FILE` est `True`. Les erreurs d'écriture sont silencieusement ignorées (pas de cascade d'exceptions depuis le logger).
- `set_log_to_file(value: bool) -> None` — active/désactive l'écriture du fichier journal au runtime.
- `get_log_path() -> str` — retourne le chemin absolu normalisé du fichier journal.

## Localisation du fichier

```
<racine_projet>/elarc.log
```

Le chemin est calculé relativement à `common/logger.py` (`..`), donc il suit naturellement le projet en cas de copie d'instance.

## Utilisation

`log` est importé par `common.database`, `common.auth`, `common.sqlite_init` pour tracer les étapes de connexion, d'authentification et d'initialisation SQLite. Il est volontairement minimaliste — pas de niveaux de log, pas de rotation : si besoin, ces fonctionnalités seront ajoutées en Phase 2.

## Dépendances

- `os`, `sys`, `datetime`
