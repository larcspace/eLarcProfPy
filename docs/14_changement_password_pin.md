# Changement de mot de passe / code PIN

**Fichier :** `views/password.py`

## Rôle

Fournir deux boîtes de dialogue modales pour permettre à l'utilisateur de modifier ses identifiants directement depuis la fenêtre de connexion.

## Classes

- `ChangePinDialog` — modifie le PIN hors connexion (4 à 8 chiffres). Le PIN est haché en SHA-256 et stocké dans `session_cache` côté SQLite local.
- `ChangePasswordDialog` — modifie le mot de passe Intranet de l'utilisateur authentifié. Le nouveau mot de passe est haché en SHA-256 et mis à jour dans la colonne `password` de `larcauth_aecuser` côté PostgreSQL Intranet.

## Algorithme

### ChangePinDialog
1. Saisie du nouveau PIN (champ `QLineEdit` en mode `Password`, longueur max 8).
2. À l'acceptation : validation `4 ≤ len(pin) ≤ 8` et `pin.isdigit()`.
3. Calcul du hash SHA-256 via `_sha256_hex(pin)`.
4. `UPDATE session_cache SET pin_hash = ? WHERE email = ?` sur la connexion locale SQLite.

### ChangePasswordDialog
1. Saisie de l'ancien et du nouveau mot de passe.
2. Vérification que l'ancien correspond au hash stocké pour l'utilisateur courant.
3. Calcul du hash SHA-256 du nouveau mot de passe.
4. `UPDATE larcauth_aecuser SET password = %s WHERE LOWER(email) = %s` sur la connexion serveur PostgreSQL.

## Intégration IHM

- Le bouton **"Changer le code PIN"** se trouve dans l'onglet **Hors connexion** de `LoginWindow`.
- Le bouton **"Changer le mot de passe"** se trouve dans l'onglet **Intranet** de `LoginWindow`.
- Les boutons s'alignent en taille avec les boutons de connexion respectifs.

## Dépendances

- `PySide6.QtWidgets` (`QDialog`, `QVBoxLayout`, `QFormLayout`, `QLineEdit`, `QPushButton`, `QLabel`, `QMessageBox`, `QDialogButtonBox`)
- `PySide6.QtCore.Qt`
- `common.database.db`, `common.database.DBMode`
- `common.auth.AuthManager`
- `hashlib`
