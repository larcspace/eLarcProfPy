# Ouverture de la fenêtre principale

**Fichier :** `views/login.py` – méthode `_open_main_window()`

## Rôle

Fermer la fenêtre de connexion et ouvrir la fenêtre principale de l'application.

## Algorithme

1. Créer une instance de `MainWindow` (non encore implémentée dans les fichiers fournis).
2. Afficher la fenêtre principale.
3. Fermer la fenêtre de connexion.

## État actuel

`MainWindow` n'est pas encore implémentée (Phase 2). À la fin de l'auth, `LoginWindow` affiche simplement un popup "Phase 2 à implémenter" en attendant le tableau de bord par rôle.

## Dépendances

- `views.main_window.MainWindow` (à créer en Phase 2)
- `PySide6.QtWidgets.QMainWindow`
