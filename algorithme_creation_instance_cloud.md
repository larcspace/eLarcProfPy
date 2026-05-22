# Algorithme de création d'une instance professeur à partir du cloud (Supabase)

## 1. Connexion au cloud

- L'utilisateur clique sur le bouton "Cloud" dans l'onglet de connexion.
- La méthode `_on_cloud()` de `LoginWindow` est appelée.
- Elle appelle `_auto_connect(NetworkMode.CLOUD)`.
- `_auto_connect` appelle `db.connect_cloud()`.
- `Database.connect_cloud()` lit la section `SupabaseDatabase` du fichier `config.ini` via `_pg_params('SupabaseDatabase')`.
- Elle tente une connexion PostgreSQL avec `psycopg2.connect(**params)`.
- Si la connexion réussit, `db.mode` passe à `DBMode.CLOUD` et `db.server_conn` pointe vers la connexion cloud.

## 2. Authentification OAuth2 (Google Workspace)

- Après connexion au cloud, `_auto_connect` appelle `OAuth2Manager.authenticate()`.
- Cette méthode :
  - Lit `ClientID` et `ClientSecret` depuis la section `OAuth2` du fichier `config.ini`.
  - Génère un code verifier PKCE et un challenge.
  - Construit l'URL d'autorisation Google avec les paramètres : `client_id`, `redirect_uri`, `response_type=code`, `scope=openid email profile`, `code_challenge`, `hd=arc-en-ciel.org`, etc.
  - Ouvre un navigateur web pointant vers cette URL.
  - Lance un serveur HTTP local sur le port 8765 pour recevoir le callback.
  - Attend jusqu'à 120 secondes que l'utilisateur s'authentifie et autorise l'application.
  - Récupère le code d'autorisation depuis le callback.
  - Échange ce code contre un token ID (JWT) via l'endpoint `https://oauth2.googleapis.com/token`.
  - Décode le JWT (sans vérifier la signature, en se fiant à HTTPS).
  - Vérifie que le domaine (`hd`) est `arc-en-ciel.org`.
  - Extrait l'email et le nom complet de l'utilisateur.

## 3. Vérification de l'existence de l'enseignant

- `OAuth2Manager.authenticate()` appelle `AuthManager.check_teacher_exists(email)`.
- Cette méthode :
  - Vérifie que `db.server_conn` est disponible et que `db.mode` est `INTRANET` ou `CLOUD`.
  - Exécute une requête SQL sur la table `public.larcauth_aecuser` pour récupérer `id`, `first_name`, `last_name`, `email`.
  - Si l'utilisateur n'existe pas, retourne `(False, {})`.
  - Sinon, vérifie dans `public.larcauth_teachadm` que l'utilisateur a un profil enseignant.
  - Récupère l'année scolaire active et le trimestre courant depuis `public.larcauth_academicyear` et `public.larcauth_term`.
  - Retourne un dictionnaire contenant `user_id`, `first_name`, `last_name`, `email`, `annee_scolaire`, `trimestre_courant`, `trimestre_label`.

## 4. Création de l'instance locale

- Si `check_teacher_exists` réussit, `OAuth2Manager.authenticate()` retourne un `AuthResult` complet.
- `LoginWindow._on_auth_done` reçoit ce résultat.
- Elle appelle `_show_confirmation_dialog` pour afficher les informations de l'utilisateur et demander confirmation.
- Si l'utilisateur confirme, `_execute_steps` est appelée.
- `_execute_steps` :
  - Appelle `SQLiteInit.init()` pour initialiser la base SQLite locale.
  - Appelle `SQLiteInit.save_session()` pour enregistrer la session dans la table `session_cache`.
  - Appelle `SQLiteInit.init_module_config()` pour configurer le module avec l'année scolaire, le trimestre, le nom du professeur, etc.
  - Appelle `SQLiteInit.take_teacher_data()` pour copier les données de l'enseignant depuis le cloud vers la base locale.
  - Enfin, `_apply_session` met à jour l'objet `session` global avec les informations de l'utilisateur.

## 5. Finalisation

- La fenêtre de connexion se ferme et la fenêtre principale s'ouvre via `_open_main_window`.
- L'utilisateur est maintenant connecté avec une instance locale prête à l'emploi.

## Diagramme simplifié

```
[Utilisateur clique Cloud]
    ↓
db.connect_cloud() → connexion PostgreSQL Supabase
    ↓
OAuth2Manager.authenticate()
    ↓
    - Ouvre navigateur Google OAuth2
    - Reçoit code d'autorisation
    - Échange contre JWT
    - Vérifie domaine arc-en-ciel.org
    ↓
AuthManager.check_teacher_exists(email)
    ↓
    - Vérifie existence dans larcauth_aecuser
    - Vérifie profil enseignant dans larcauth_teachadm
    - Récupère année scolaire et trimestre actifs
    ↓
Retourne AuthResult complet
    ↓
LoginWindow._on_auth_done → confirmation → _execute_steps
    ↓
SQLiteInit.init() → création base locale
SQLiteInit.save_session() → enregistrement session
SQLiteInit.init_module_config() → configuration module
SQLiteInit.take_teacher_data() → copie données cloud → local
    ↓
_apply_session → mise à jour session globale
    ↓
Ouverture fenêtre principale
```

## Notes importantes

- La connexion cloud utilise le schéma `public` pour les tables.
- Le token JWT n'est pas vérifié cryptographiquement, mais la communication HTTPS garantit l'intégrité.
- Le code verifier PKCE assure la sécurité de l'échange OAuth2.
- La base locale SQLite est créée dans le répertoire parent du module `common`.
