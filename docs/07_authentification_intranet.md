# Authentification intranet (mot de passe)

**Fichier :** `common/auth.py` – méthode `AuthManager.auth_intranet()`

## Rôle

Authentifier un utilisateur avec email et mot de passe sur la base intranet.

## Algorithme

1. Vérifier que `db.server_conn` est disponible et que `db.mode == DBMode.INTRANET`.
2. Calculer le hash SHA-256 du mot de passe saisi.
3. Exécuter `SELECT id, email, last_name, first_name, password FROM larcauth_aecuser WHERE LOWER(email) = %s`.
4. Si aucun résultat, retourner erreur.
5. Comparer le hash stocké avec le hash calculé.
6. Si différent, retourner erreur.
7. Récupérer les rôles depuis `larcauth_teachadm`.
8. Déduire le rôle via `_deduce_role()`.
9. Récupérer le trimestre actif via `_load_active_term()`.
10. Retourner `AuthResult` complet.

## Dépendances

- `common.database.db`
- `common.session.AuthResult`
- `common.session.UserRole`
- `hashlib`
