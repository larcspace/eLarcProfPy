# Algorithme de création d'une instance professeur à partir de l'intranet

## 1. Connexion à l'intranet

- L'utilisateur clique sur le bouton "Intranet" dans l'onglet de connexion.
- La méthode `_on_intranet()` de `LoginWindow` est appelée.
- Elle appelle `_auto_connect(NetworkMode.INTRANET)`.
- `_auto_connect` appelle `db.connect_intranet()`.
- `Database.connect_intranet()` lit la section `IntranetDatabase` du fichier `config.ini` via `_pg_params('IntranetDatabase')`.
- Elle tente une connexion PostgreSQL avec `psycopg2.connect(**params)`.
- Si la connexion réussit, `db.mode` passe à `DBMode.INTRANET` et `db.server_conn` pointe vers la connexion intranet.

## 2. Authentification par mot de passe

- Après connexion à l'intranet, `_auto_connect` appelle `AuthManager.auth_intranet(email, password)`.
- Cette méthode :
  - Vérifie que `db.server_conn` est disponible et que `db.mode` est `INTRANET`.
  - Calcule le hash SHA-256 du mot de passe saisi.
  - Exécute une requête SQL sur la table `larcauth_aecuser` (sans schéma) pour récupérer `id`, `email`, `last_name`, `first_name`, `password`.
  - Si l'utilisateur n'existe pas, retourne une erreur.
  - Compare le hash stocké avec le hash calculé.
  - Si les mots de passe ne correspondent pas, retourne une erreur.
  - Récupère les rôles (`is_adm`, `is_coordonator`, `is_secretary`) depuis `larcauth_teachadm`.
  - Déduit le rôle via `_deduce_role()`.
  - Récupère le trimestre actif via `_load_active_term()`.
  - Retourne un `AuthResult` complet.

## 3. Vérification de l'existence de l'enseignant

- `AuthManager.auth_intranet()` ne vérifie pas explicitement l'existence de l'enseignant, car la requête SQL échoue si l'utilisateur n'existe pas.
- Cependant, `LoginWindow._on_auth_done` peut appeler `AuthManager.check_teacher_exists(email)` pour obtenir des informations supplémentaires (année scolaire, trimestre). Cette méthode est la même que pour le cloud.

## 4. Création de l'instance locale

- `LoginWindow._on_auth_done` reçoit le `AuthResult`.
- Elle appelle `_show_confirmation_dialog` pour afficher les informations de l'utilisateur et demander confirmation.
- Si l'utilisateur confirme, `_execute_steps` est appelée.
- `_execute_steps` :
  - Appelle `SQLiteInit.init()` pour initialiser la base SQLite locale.
  - Appelle `SQLiteInit.save_session()` pour enregistrer la session dans la table `session_cache`.
  - Appelle `SQLiteInit.init_module_config()` pour configurer le module avec l'année scolaire, le trimestre, le nom du professeur, etc.
  - Appelle `SQLiteInit.take_teacher_data()` pour copier les données de l'enseignant depuis l'intranet vers la base locale.
  - Enfin, `_apply_session` met à jour l'objet `session` global avec les informations de l'utilisateur.

## 5. Finalisation

- La fenêtre de connexion se ferme et la fenêtre principale s'ouvre via `_open_main_window`.
- L'utilisateur est maintenant connecté avec une instance locale prête à l'emploi.

## Diagramme simplifié

```
[Utilisateur clique Intranet]
    ↓
db.connect_intranet() → connexion PostgreSQL intranet
    ↓
AuthManager.auth_intranet(email, password)
    ↓
    - Hash SHA-256 du mot de passe
    - Requête SELECT sur larcauth_aecuser
    - Vérification du hash stocké
    - Récupération des rôles dans larcauth_teachadm
    - Récupération du trimestre actif
    ↓
Retourne AuthResult complet
    ↓
LoginWindow._on_auth_done → confirmation → _execute_steps
    ↓
SQLiteInit.init() → création base locale
SQLiteInit.save_session() → enregistrement session
SQLiteInit.init_module_config() → configuration module
SQLiteInit.take_teacher_data() → copie données intranet → local
    ↓
_apply_session → mise à jour session globale
    ↓
Ouverture fenêtre principale
```

## Notes importantes

- La connexion intranet utilise les tables sans schéma (par défaut `public`).
- Le mot de passe est stocké en hash SHA-256 dans la base.
- La base locale SQLite est créée dans le répertoire parent du module `common`.
- Contrairement au cloud, l'authentification intranet ne nécessite pas OAuth2.
