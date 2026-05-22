# Authentification hors ligne (PIN)

**Fichier :** `common/auth.py` – méthode `AuthManager.auth_pin()`

## Rôle

Authentifier un utilisateur avec un PIN stocké localement (hors connexion).

## Algorithme

1. Vérifier que `db.local_conn` est disponible.
2. Calculer le hash SHA-256 du PIN saisi.
3. Exécuter `SELECT user_id, email, full_name, role, term_id, term_label FROM session_cache WHERE LOWER(email) = ? AND pin_hash = ?`.
4. Si aucun résultat, retourner erreur.
5. Retourner `AuthResult` avec les données de la session locale.

## Dépendances

- `common.database.db`
- `common.session.AuthResult`
- `common.session.UserRole`
- `hashlib`
