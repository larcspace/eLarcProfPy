# Authentification cloud (OAuth2 Google)

**Fichier :** `common/auth.py` – classe `OAuth2Manager`

## Rôle

Authentifier un utilisateur via Google Workspace (OAuth2 PKCE).

## Algorithme

1. Lire `ClientID` et `ClientSecret` depuis la section `OAuth2` du fichier `config.ini`.
2. Générer un code verifier PKCE et un challenge.
3. Construire l'URL d'autorisation Google avec les paramètres requis.
4. Ouvrir le navigateur web.
5. Lancer un serveur HTTP local sur le port 8765 pour recevoir le callback.
6. Attendre jusqu'à 120 secondes que l'utilisateur s'authentifie.
7. Récupérer le code d'autorisation.
8. Échanger le code contre un token ID (JWT) via l'endpoint Google.
9. Décoder le JWT (sans vérifier la signature).
10. Vérifier que le domaine (`hd`) est `arc-en-ciel.org`.
11. Appeler `AuthManager.check_teacher_exists(email)` pour vérifier l'existence de l'enseignant.
12. Si l'utilisateur existe, retourner `AuthResult` complet.

## Dépendances

- `common.database.db`
- `common.auth.AuthManager`
- `common.auth._find_cfg`
- `hashlib`, `secrets`, `base64`, `json`, `urllib`, `http.server`, `threading`, `webbrowser`
