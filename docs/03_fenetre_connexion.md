# Fenêtre de connexion : `LoginWindow`

**Fichier :** `views/login.py`

## Rôle

Afficher l'interface de connexion avec les onglets Intranet, Cloud, PIN et Nouvelle instance.

## Algorithme

1. `__init__` : initialise l'interface utilisateur via `_setup_ui()`.
2. `_setup_ui` : crée les onglets et les widgets.
3. `showEvent` : déclenche la détection réseau via `_start_net_detection()`.
4. `_start_net_detection` : lance un thread pour `_check_network()`.
5. `_check_network` : appelle `detect_network()` depuis `common/network.py`.
6. `_on_net_detected` : met à jour les indicateurs réseau et tente la connexion automatique via `_auto_connect()`.
7. `_auto_connect` : selon le mode réseau, appelle `db.connect_intranet()` ou `db.connect_cloud()`.
8. `_on_auto_connect_result` : si la connexion réussit, lance l'authentification appropriée.

## Dépendances

- `common.network.detect_network`
- `common.database.db`
- `common.auth.AuthManager`
- `common.auth.OAuth2Manager`
- `common.sqlite_init.SQLiteInit`
- `common.session.session`
