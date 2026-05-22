# eLarcProfPy — Contexte projet

_Dernière mise à jour : 22 mai 2026_

## Décision technique
Version **Python/PySide6** retenue pour le desktop. Elle remplace la version Delphi (eLarcProf)
qui a été abandonnée à cause d'erreurs de compilation FireDAC récurrentes.
**Pas PyQt5, pas PyQt6, pas Flet** — PySide6 uniquement.
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
├── main.py                 # QApplication + LoginWindow + modes CLI
├── common/
│   ├── network.py          # detect_network() → INTRANET/INTERNET/OFFLINE
│   ├── session.py          # UserRole, ConnMode, AuthResult, Session, session (global)
│   ├── database.py         # Database class, db (global singleton)
│   ├── auth.py             # AuthManager + OAuth2Manager (PKCE Google)
│   ├── sqlite_init.py      # SQLiteInit, DDL, save_session, curseurs sync
│   └── logger.py           # log() vers elarc.log + bascule LOG_TO_FILE
├── views/
│   ├── login.py            # LoginWindow — 4 onglets auth + workers QThread
│   └── password.py         # ChangePinDialog + ChangePasswordDialog
├── export_to_sqlite.py     # Export PostgreSQL → SQLite (utilitaire)
└── docs/                   # Documentation algorithmique numérotée
```

### Modes CLI de `main.py`
- `python main.py` — lance normalement la fenêtre de connexion.
- `python main.py --mode4 [email]` — crée une instance prof depuis l'Intranet en ligne de commande (auth, init SQLite, `init_module_config`, `take_teacher_data`, save session).
- `python main.py --test-create-db` — initialise une base SQLite temporaire et vérifie les tables via `sqlite_init.verify_tables()`.

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

Changement de credentials via `views/password.py` :
- `ChangePinDialog` — bouton dans l'onglet Hors connexion (PIN 4-8 chiffres, hash SHA-256).
- `ChangePasswordDialog` — bouton dans l'onglet Intranet.

Après auth réussie : popup "Phase 2 à implémenter" (placeholder tableau de bord).

## Changements récents (13 mai 2026)

### 1. Boutons "Changer le mot de passe" et "Changer le code PIN"
- Ajout d'un bouton "Changer le mot de passe" dans l'onglet Intranet.
- Ajout d'un bouton "Changer le code PIN" dans l'onglet Hors connexion.
- Ajustement de la taille des boutons pour correspondre aux boutons de connexion.

### 2. Suppression du bouton "Changer le mot de passe" de la barre d'état
- Le bouton était dans la barre d'état en bas ; il a été supprimé car remplacé par le bouton dans l'onglet Intranet.

### 3. Indicateur d'état en bas
- Remplacement des deux indicateurs "Présence intranet ●" et "Présence cloud ●" par un seul indicateur large centré en bas.
- L'indicateur affiche l'un des 4 états :
  - 0 : "Module eLarcProf non instanciée" (feu noir)
  - 1 : "Module eLarcProf de Nom et prénom du prof Non Connecté" (feu noir)
  - 2 : "Module eLarcProf de Nom et prénom du prof Connecté à l'Intranet" (feu vert)
  - 3 : "Module eLarcProf de Nom et prénom du prof connecté au Cloud" (feu vert)
- Les deux indicateurs "Présence intranet ●" et "Présence cloud ●" ont été remis en haut à côté du titre.

### 4. Correction de l'authentification Intranet
- Remplacement de `UserRole.TEACHER` par `UserRole.PROF` (car `TEACHER` n'existe pas).
- Suppression de la colonne `enabled` dans les requêtes (car elle n'existe pas).
- Utilisation des colonnes correctes : `is_adm`, `is_coordonator`, `is_secretary`.
- Vérification du hash du mot de passe stocké (colonne `password`) au lieu de comparer avec `'Aec-2026'`.

### 5. Base de données unique `elarc.db`
- Suppression de `SQLiteDB.db` (plus utilisé).
- `elarc.db` est créée directement avec les tables métiers (`larcauth_evaluation`, `larcauth_learnerpei_has_termsubjectpei`, `larcauth_learnerdp_has_termsubjectdp`) et les tables locales (`session_cache`, `sync_cursor`, `module_config`).
- `export_to_sqlite.py` exporte maintenant vers `elarc.db` (au lieu de `SQLiteDB.db`).
- `sqlite_init.init()` crée `elarc.db` vide puis exécute `_DDL` pour créer les tables.

### 6. Téléchargement des données du professeur
- `take_teacher_data` accepte maintenant `infos` (dict) au lieu de `user_id` et `term_id`.
- Les tables métiers sont vidées avant d'être remplies.
- La connexion serveur est vérifiée avant le téléchargement.
- `_on_auth_done` appelle `sqlite_init.init()` avant `init_module_config()`.

### 7. Création d'instance
- `elarc.db` est copié dans le dossier de destination lors de la création d'une nouvelle instance.

### 8. Validation du PIN
- La validation du PIN vérifie maintenant `len(new_pin) > 8` (max 8 chiffres).

## Phase 2 — PROCHAINE ÉTAPE
Avant de coder le tableau de bord, il faut :
1. Recevoir le dump complet de la base intranet (~5 Mo) pour analyser les tables.
2. Identifier les tables utiles collège/lycée (sous-ensemble du schéma Larc).
3. Définir le scope par prof (quelles lignes descendent sur le device).
4. Construire le module de sync PostgreSQL → SQLite.

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

> Les capacités maximales du gabarit (nb de classes, d'élèves, de matières, d'évals, etc.) ne concernent **pas** l'IHM ni le code applicatif : les slots existent déjà côté base, et l'utilisateur perçoit ces limites naturellement à travers l'interface (slots vides = désactivés). Ne pas coder de constantes de dimensionnement.

### Conséquence sur la sync
Le daemon de sync n'a jamais à vérifier si une ligne existe côté device —
elle existe toujours. La sync ne fait que des **UPDATE**. Aucun conflit possible.

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
- Dernier commit : `f7fdf90` — Phase 1, 13 mai 2026 (boutons password/PIN, indicateur état bas, correction auth Intranet, base unique elarc.db).
