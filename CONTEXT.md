# eLarcProfPy — Contexte projet

_Dernière mise à jour : 22 mai 2026 (décisions sync + notations + détection sans connexion)_

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
| Niveau | Périmètre | Échelle | Détail |
|---|---|---|---|
| Collège (PEI) | par critère | 0–8 | **4 critères** affichés (a, b, c, d) — colonne `note_on_7` pour la synthèse |
| Collège (PEI) | synthèse trimestre/matière | 0–7 | 1 note finale par matière par trimestre (`note_on_7`) |
| Lycée (DP) | note directe | 0–20 | `moy_on_20`, `cc_on_20`, `bacblanc`, `bacblanc2` — en plus du système critères |

### Évaluations par trimestre
- **12 formatives** + **12 sommatives** par matière par trimestre exposées à l'IHM — règle métier (≈ 1/semaine sur 12 semaines).
- Les 12 slots sont toujours rendus dans l'IHM ; les lignes sans critère coché sont grisées/inactives.

### Décalage base ⟷ IHM v1 (à connaître absolument)
Le schéma serveur a une capacité supérieure à ce que l'IHM v1 expose. Ces "extras" sont **réservés en base** pour des usages futurs, sans modification de schéma :

| Sujet | Base | IHM v1 | Réserve pour |
|---|---|---|---|
| Critères par évaluation | 6 colonnes (`crit_a..crit_e`, `crit_F`) | 4 (a, b, c, d) | Évolutions du logiciel (v2+), pas de migration DDL |
| Slots formatives / sommatives | 15 (`f01..f15`, `s01..s15`) | 12 (`f01..f12`, `s01..s12`) | Calculs statistiques récurrents (moyennes, etc.) |
| Aspects par critère | 7 (`aspect_a1..a7`, …) | 0 | Version 2 — "éléments de contenu" des critères |

**Convention de nommage des colonnes notes** (côté `larcauth_learnerpei_has_termsubjectpei` et `larcauth_learnerdp_has_termsubjectdp`) :

```
formatives :  f01_note_a, f01_note_b, f01_note_c, f01_note_d   (a..d uniquement en v1)
              f02_note_a … f12_note_d
sommatives :  s01_note_a … s12_note_d
synthèse    :  note_on_7 (PEI)  ou  moy_on_20 (DP)
observation :  fXX_observation, sXX_observation, cp_observation, term_observation
jugement    :  jgt_a..jgt_d
```

### Particularités à connaître
- **Bug schéma serveur** : la colonne `S09_note_f` est en majuscule (vs `s09_note_f` attendu). Non corrigée car l'attribut n'est pas encore utilisé. À ignorer pour l'IHM v1 (n'expose pas `_f`).
- **`crit_F`** : également en majuscule isolée. Même statut — non exposé en v1, donc sans impact.

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

## Architecture de synchronisation device ↔ serveur

### Pattern shadow-table (tables `_ref`)
Chaque table métier du device a une **jumelle `_ref`** au schéma identique :

| Table de travail | Table de référence |
|---|---|
| `larcauth_evaluation` | `larcauth_evaluation_ref` |
| `larcauth_learnerpei_has_termsubjectpei` | `larcauth_learnerpei_has_termsubjectpei_ref` |
| `larcauth_learnerdp_has_termsubjectdp` | `larcauth_learnerdp_has_termsubjectdp_ref` |

- **Table de travail** = état local courant, modifié par les saisies du prof.
- **Table `_ref`** = snapshot du dernier état serveur connu (acté à la dernière synchro réussie).
- Au seed (`take_teacher_data`), les deux tables sont peuplées avec les mêmes données serveur.

### Diff au niveau cellule
Les lignes existent toujours des deux côtés (gabarit pré-alloué) → aucun INSERT/DELETE à détecter. Le diff est **cellule par cellule** : jointure par `id`, comparaison colonne par colonne.

### Matrice de décision (par cellule, à la synchro)
| local vs ref | serveur vs ref | Action |
|---|---|---|
| = | = | rien à faire |
| = | ≠ | **pull** : `local = serveur`, `ref = serveur` |
| ≠ | = | **push** : `serveur = local`, `ref = local` |
| ≠ | ≠ | **conflit** → IHM de résolution |

### Scope de la synchro
- **Trimestre courant uniquement** : `WHERE term_id = module_config.trimestre_courant`.
- **Trimestres passés figés** : aucune modification ni synchro acceptée — règle business stricte. Les cellules des trimestres antérieurs sont read-only dans l'IHM (grisées) et ignorées par le diff.

### Déclencheurs de la synchro
La synchro **n'est jamais automatique au démarrage**. Elle se déclenche uniquement :
1. À la **création de l'instance** (mode 4) — seed initial : `local = ref = serveur`.
2. Sur **clic explicite "Connecter"** dans l'onglet Intranet ou Cloud (puis flux de synchro).
3. Sur **clic "Synchroniser"** depuis le tableau de bord (Phase 2).
4. À la **sortie avec enregistrement** (Phase 2).

Au démarrage, on **teste seulement la présence** réseau (intranet / internet) pour mettre à jour les indicateurs visuels — on ne se connecte pas.

### Conflits (cas 4 de la matrice)
- Rares en pratique (saisie simultanée prof / coord sur la même cellule).
- Possibles **uniquement sur le trimestre en cours**.
- Présentés via une IHM dédiée (Phase 2) qui liste les cellules en conflit et permet au prof de trancher cellule par cellule.

### État de synchro par table — table `sync_state`
```sql
CREATE TABLE sync_state (
    table_name  TEXT PRIMARY KEY,   -- nom de la table métier (sans suffixe _ref)
    last_sync   TEXT,               -- ISO 8601 ; NULL = jamais synchro
    last_source TEXT                -- 'intranet' ou 'cloud' (diagnostic)
);
```
Un timestamp par table, mis à jour à la fin de chaque synchro réussie pour cette table.

### Le daemon serveur n'est pas concerné
Toute cette logique vit côté device. Le daemon Python qui synchronise intranet ↔ cloud continue son boulot sans modification — il ne sait rien des tables `_ref` ni du diff cellule local.

---

## Règles métier importantes
- **Ne jamais DELETE** — désactivation logique via `enabled = FALSE`
- **Avant tout UPDATE serveur** : `SET LOCAL app.sync_source = 'intranet'` + `SET LOCAL app.modified_by = <user_id>`
- **Trimestres passés en lecture seule** — la synchro ne touche que `term_id = trimestre_courant`
- **Démarrage = test de présence réseau seulement**, pas de connexion auto
- Le daemon Python de sync intranet ↔ cloud tourne séparément — **ne jamais le modifier**
- Schéma PostgreSQL de référence : `C:\Projets\eLarcProf\Data\LarcNewCloud.sql`
- Tables clés auth : `larcauth_aecuser`, `larcauth_teachadm`, `larcib_term`
- Tables sync serveur : `sync_log`, `sync_table_config`
- Tables sync device : tables métier × 2 (avec `_ref`) + `sync_state`

## Synchronisation Double Verrou
Chaque table a `sync_revision` (bigint, auto-incrémenté par trigger).
Les modifs sont loggées dans `sync_log`. Un daemon Python synchronise intranet ↔ Supabase.
Ne jamais toucher au daemon. Toujours poser `SET LOCAL app.sync_source` avant un UPDATE.

## État GitHub
- Repo : `github.com/larcspace/eLarcProfPy`
- Branche : `main`
- Dernier commit : `f7fdf90` — Phase 1, 13 mai 2026 (boutons password/PIN, indicateur état bas, correction auth Intranet, base unique elarc.db).
