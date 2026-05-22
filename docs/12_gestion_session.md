# Gestion de la session utilisateur

**Fichier :** `common/session.py`

## Rôle

Définir les structures de données pour la session utilisateur.

## Classes

- `UserRole` : énumération des rôles (PROF, COORD, SECR, ADMIN).
- `ConnMode` : énumération des modes de connexion (Intranet, Cloud, Hors connexion, Nouvelle instance).
- `AuthResult` : dataclass contenant les résultats d'authentification.
- `Session` : dataclass contenant l'état de la session courante.

## Instance globale

```python
session: Session = Session(
    instance_dir=os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    )
)
```

## Utilisation

- `session` est importé dans `views/login.py` et `common/sqlite_init.py`.
- Après authentification, `_apply_session` met à jour les attributs de `session`.
