# Point d'entrée : `main()`

**Fichier :** `main.py`

## Rôle

Lancer l'application PySide6 (Qt6) avec, selon les arguments CLI, soit la fenêtre de connexion, soit un mode utilitaire en ligne de commande.

## Algorithme (mode normal)

1. Créer une instance de `QApplication`.
2. Définir `applicationName`, `organizationName`, le style `Fusion` et la police `Segoe UI 10`.
3. Créer une instance de `LoginWindow` (fenêtre de connexion).
4. Afficher la fenêtre.
5. Lancer la boucle d'événements Qt via `app.exec()`.

## Modes CLI

- `python main.py` — lancement normal.
- `python main.py --mode4 [email]` — création d'une instance prof depuis l'Intranet en ligne de commande :
  - `db.connect_intranet()`
  - `AuthManager.check_teacher_exists(email)`
  - `sqlite_init.init()`
  - `sqlite_init.init_module_config(...)`
  - `sqlite_init.take_teacher_data(infos)`
  - Vérification des comptes (`larcauth_evaluation`, `larcauth_learnerpei_has_termsubjectpei`, `larcauth_learnerdp_has_termsubjectdp`)
  - `sqlite_init.save_session(res)`
  - Puis lancement de `LoginWindow`.
- `python main.py --test-create-db` — test de création d'une base SQLite temporaire et vérification des tables via `sqlite_init.verify_tables()` ; sort en code 0 si OK.

## Code clé (mode normal)

```python
def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName('eLarcProf')
    app.setOrganizationName('Arc-en-Ciel')
    app.setStyle('Fusion')
    app.setFont(QFont('Segoe UI', 10))
    win = LoginWindow()
    win.show()
    sys.exit(app.exec())
```

## Dépendances

- `views.login.LoginWindow`
- `PySide6.QtWidgets.QApplication`
- `PySide6.QtGui.QFont`
- `common.database.db`, `common.auth.AuthManager`, `common.sqlite_init.sqlite_init`, `common.session` (modes CLI)
- `sys`, `os`, `tempfile`
