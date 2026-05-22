# Introduction

Ce dossier contient la documentation algorithmique du programme eLarcProf.

## Objectif

Expliquer le flux complet de l'application, depuis le lancement jusqu'à l'ouverture de la fenêtre principale, en détaillant chaque étape.

## Ordre de lecture

Les fichiers sont numérotés dans l'ordre logique d'exécution :

1. `01_introduction.md` – ce fichier
2. `02_point_entree_main.md` – point d'entrée `main()` (modes normal et CLI)
3. `03_fenetre_connexion.md` – fenêtre de connexion
4. `04_detection_reseau.md` – détection du réseau
5. `05_connexion_intranet.md` – connexion à l'intranet
6. `06_connexion_cloud.md` – connexion au cloud (Supabase)
7. `07_authentification_intranet.md` – authentification par mot de passe
8. `08_authentification_cloud_oauth2.md` – authentification OAuth2 (Google)
9. `09_authentification_pin.md` – authentification hors ligne par PIN
10. `10_creation_instance_locale.md` – création de l'instance locale SQLite
11. `11_export_sqlite.md` – export des tables vers SQLite
12. `12_gestion_session.md` – gestion de la session utilisateur
13. `13_ouverture_fenetre_principale.md` – ouverture de la fenêtre principale (Phase 2)
14. `14_changement_password_pin.md` – dialogues de changement de mot de passe et de PIN
15. `15_logger.md` – logger applicatif (`elarc.log`)

## Conventions

- Les noms de fonctions sont écrits en `code`.
- Les classes sont en `Classe`.
- Les fichiers sont référencés par leur chemin relatif.
