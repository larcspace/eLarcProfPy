# eLarcProfPy — Contexte projet

## Décision technique
Version **Python/PySide6** retenue pour le desktop. Elle remplace la version Delphi (eLarcProf)
qui a été abandonnée à cause d'erreurs de compilation FireDAC récurrentes.
**Pas PyQt6, pas Flet** — PySide6 uniquement.
Mobile/tablette = phase ultérieure (FastAPI + Flutter ou PWA).

## Environnement
- Python 3.x + PySide6 (Qt6)
- Venv : `.venv/` dans le répertoire du projet
- Dépendances : `pip install -r requirements.txt`
- Lancement : `python main.py`
- OS cible : Windows desktop

## Bases de données
| Source | Technologie | Usage |
|---|---|---|
| Intranet | PostgreSQL `192.168.2.90:5432/LMarcIntranet` | Données en ligne réseau local |
| Cloud | Supabase PostgreSQL (PgBouncer port 6543) | Données en ligne internet |
| Device | SQLite `elarc.db` | Projection locale scopée prof |

Config dans `config.ini` (jamais commité — voir `.gitignore`).
Même structure que `C:\Projets\eLarcProf\config.ini` sur la machine de dev.

## Architecture fichiers
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
1. **Intranet** — email + mot de passe → `larcauth_aecuser` (hash SHA-256 champ `password`)
2. **Cloud** — OAuth2 PKCE Google `@arc-en-ciel.org` → loopback HTTP port 8765
3. **PIN** — email + PIN → SQLite `session_cache` (hash SHA-256)
4. **Nouvelle instance** — copie le projet dans un nouveau dossier + `lancer.bat`

Après auth réussie : popup "Phase 2 à implémenter" (placeholder tableau de bord).

## Changements récents (12 mai 2026)

### Base de données
- Colonne `password` utilisée au lieu de `passdelph` dans `larcauth_aecuser`
- Mot de passe standard `Aec-2026` accepté pour tous les utilisateurs (dans `auth_intranet`)
- Vérification de l'email via `check_teacher_exists` (jointure avec `teachadm` sans colonne `enabled`)
- Requête PostgreSQL unique avec `UNION ALL` pour les trois tables (évaluations, PEI, DP)
- Transaction explicite dans SQLite pour les insertions
- Vidage des tables avant insertion (`DELETE FROM`)
- Utilisation de `executemany` pour les insertions

### Interface
- Indicateurs "Présence intranet ●" et "Présence cloud ●" en haut à droite
- Feu de connexion après le texte dans la barre de statut
- Bouton "Changer le mot de passe" visible après connexion Intranet
- Boîte de dialogue de confirmation avant téléchargement
- Timer de vérification réseau toutes les 30 secondes (uniquement fenêtre visible)
- Connexion SQLite dédiée pour le téléchargement (`check_same_thread=False`)

### Authentification
- `auth_intranet` accepte le mot de passe standard `Aec-2026`
- `check_teacher_exists` ne vérifie plus la colonne `enabled` (inexistante)
- `ChangePasswordDialog` utilise `AuthManager.auth_intranet` pour vérifier l'ancien mot de passe
- Création d'instance : demande du mot de passe (Intranet) ou OAuth2 (Cloud)

### Corrections
- Jointure `t.aecuser_ptr_id` au lieu de `t.user_id` dans `check_teacher_exists`
- Colonnes `last_name` et `first_name` au lieu de `nom` et `prenom`
- Chemin normalisé avec `os.path.normpath` pour éviter les mélanges `/` et `\`
- Ignorer le dossier `.venv` lors de la copie d'instance

## Phase 2 — PROCHAINE ÉTAPE
Avant de coder le tableau de bord, il faut :
1. Recevoir le dump complet de la base intranet (~5 Mo) pour analyser les tables
2. Identifier les tables utiles collège/lycée (sous-ensemble du schéma Larc)
3. Définir le scope par prof (quelles lignes descendent sur le device)
4. Construire le module de sync PostgreSQL → SQLite

Ensuite le tableau de bord par rôle :
- PROF : liste de ses classes → saisie de notes
- COORD : vue globale + validation
- SECR : gestion administrative
- ADMIN : configuration système

---

## ARCHITECTURE BASE DE DONNÉES DEVICE — DÉCISIONS STRATÉGIQUES

### Philosophie "Gabarit" (fondamentale — ne pas oublier)
La base PostgreSQL intranet fonctionne sur ce principe depuis **10 ans**.
**On ne crée rien, on ne détruit rien.** Tous les éléments existent dans la base
sous forme de slots pré-alloués. L'activation se fait exclusivement par des **booléens**.

```sql
-- Jamais :  INSERT  ou  DELETE
-- Toujours : UPDATE ... SET enabled = TRUE/FALSE
--            UPDATE ... SET valeur = x, enabled = TRUE
```

Le SQLite device est une **projection filtrée** de ce gabarit PostgreSQL.
Même philosophie, même structure, moins de tables, scopé au prof.

### Conséquence sur la sync
Le daemon de sync n'a jamais à vérifier si une ligne existe côté device —
elle existe toujours. La sync ne fait que des **UPDATE**. Aucun conflit possible.

### Dimensions du gabarit (Arc-en-Ciel)
Ces maximums sont figés dans la base PostgreSQL. Les changer = reconstruire la base.

| Dimension | Max | Notes |
|---|---|---|
| Classes par niveau | 2 | ex: 3ème A et 3ème B |
| Élèves par classe | 40 | |
| Matières par classe / trimestre | 20 | dont 5 options (matières spéciales) |
| Critères par matière | 7 | définis à la configuration uniquement |
| Évals formatives / matière / trimestre | 12 | |
| Évals sommatives / matière / trimestre | 12 | |
| Classes par prof (device) | 10 | décidé ensemble |

### Système de notation
| Niveau | Échelle | Détail |
|---|---|---|
| Collège | 0–8 par critère | jusqu'à 7 critères par évaluation |
| Lycée | 0–20 | note directe (en plus du système critères) |

### Architecture SQLite device (2 niveaux)
```
Niveau 1 — Structure (gabarit pur, pré-alloué)
  classes, élèves-slots, matières-slots, éval-slots
  → toujours présent, activé/désactivé par boolean

Niveau 2 — Notes (générées à l'activation d'une éval)
  quand eval.enabled passe à TRUE
  → génération automatique des lignes notes pour chaque élève actif
  → ensuite uniquement des UPDATE, jamais INSERT/DELETE
```

### Queries statiques
Les requêtes SQL ne changent jamais. Seules les données changent.
C'est le principe fondamental : **schéma fixe → queries fixes → seules les valeurs varient**.

---

## Règles métier importantes
- **Ne jamais DELETE** — désactivation logique via `enabled = FALSE`
- **Avant tout UPDATE** : `SET LOCAL app.sync_source = 'intranet'` + `SET LOCAL app.modified_by = <user_id>`
- Le daemon Python de sync intranet ↔ cloud tourne séparément — **ne jamais le modifier**
- Schéma PostgreSQL de référence : `C:\Projets\eLarcProf\Data\LarcNewCloud.sql`
- Tables clés auth : `larcauth_aecuser`, `larcauth_teachadm`, `larcib_term`
- Tables sync : `sync_log`, `sync_table_config`

## Synchronisation Double Verrou
Chaque table a `sync_revision` (bigint, auto-incrémenté par trigger).
Les modifs sont loggées dans `sync_log`. Un daemon Python synchronise intranet ↔ Supabase.
Ne jamais toucher au daemon. Toujours poser `SET LOCAL app.sync_source` avant un UPDATE.

## État GitHub
- Repo : `github.com/larcspace/eLarcProfPy`
- Branche : `main`
- Dernier commit : Phase 1 complète + CONTEXT.md
