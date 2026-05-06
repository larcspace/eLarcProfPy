# eLarcProfPy — Contexte projet

## Décision technique
Version **Python/PySide6** retenue pour le desktop. Elle remplace la version Delphi (eLarcProf)
qui a été abandonnée à cause d'erreurs de compilation FireDAC récurrentes.

## Environnement
- Python 3.x + PySide6 (Qt6) — **pas PyQt6, pas Flet**
- Venv : `.venv/` dans le répertoire du projet
- Dépendances : `pip install -r requirements.txt`
- Lancement : `python main.py`
- OS cible : Windows desktop (mobile = phase ultérieure)

## Bases de données
| Source | Technologie | Usage |
|---|---|---|
| Intranet | PostgreSQL `192.168.2.90:5432/LMarcIntranet` | Données en ligne réseau local |
| Cloud | Supabase PostgreSQL (PgBouncer port 6543) | Données en ligne internet |
| Local | SQLite `elarc.db` | Cache offline + PIN auth |

Config dans `config.ini` (jamais commité — voir `.gitignore`).
Même structure que `C:\Projets\eLarcProf\config.ini` sur la machine de dev.

## Architecture
```
eLarcProfPy/
├── main.py                 # QApplication + LoginWindow
├── common/
│   ├── network.py          # detect_network() → INTRANET/INTERNET/OFFLINE
│   ├── session.py          # UserRole, ConnMode, AuthResult, Session, session (global)
│   ├── database.py         # Database class, db (global singleton)
│   ├── auth.py             # AuthManager + OAuth2Manager (PKCE Google)
│   └── sqlite_init.py      # SQLiteInit, DDL, save_session, curseurs sync
└── views/
    └── login.py            # LoginWindow — 4 onglets auth + workers QThread
```

## Rôles utilisateurs
| Rôle | Accès |
|---|---|
| PROF | Ses classes, ses notes, son emploi du temps |
| COORD | Tout + coordination pédagogique |
| SECR | Administratif, inscriptions |
| ADMIN | Tout sans restriction |

## Phase 1 — TERMINÉE
Écran de connexion `views/login.py` avec 4 modes :
1. **Intranet** — email + mot de passe → `larcauth_aecuser` (hash SHA-256 champ `passdelph`)
2. **Cloud** — OAuth2 PKCE Google `@arc-en-ciel.org` → loopback HTTP port 8765
3. **PIN** — email + PIN → SQLite `session_cache` (hash SHA-256)
4. **Nouvelle instance** — copie le projet dans un nouveau dossier + `lancer.bat`

Après auth réussie : popup "Phase 2 à implémenter" (placeholder tableau de bord).

## Phase 2 — À FAIRE
Tableau de bord principal selon le rôle :
- PROF : liste de ses classes → saisie de notes
- COORD : vue globale + validation
- SECR : gestion administrative
- ADMIN : configuration système

## Règles métier importantes
- **Ne jamais DELETE** — désactivation logique via `enabled = FALSE`
- **Avant tout UPDATE** : `SET LOCAL app.sync_source = 'intranet'` + `SET LOCAL app.modified_by = <user_id>`
- Le daemon Python de sync intranet ↔ cloud tourne séparément — ne pas le modifier
- Schéma PostgreSQL complet : `C:\Projets\eLarcProf\Data\LarcNewCloud.sql`
- Tables clés : `larcauth_aecuser`, `larcauth_teachadm`, `larcib_term`, `sync_log`, `sync_table_config`

## Synchronisation Double Verrou
Chaque table a `sync_revision` (bigint, auto-incrémenté par trigger).
Les modifs sont loggées dans `sync_log`. Un daemon Python synchronise intranet ↔ Supabase.
Ne jamais toucher au daemon. Toujours poser `SET LOCAL app.sync_source` avant un UPDATE.

## État GitHub
- Repo : `github.com/larcspace/eLarcProfPy`
- Branche : `main`
- Dernier commit : Phase 1 complète + merge .gitignore
