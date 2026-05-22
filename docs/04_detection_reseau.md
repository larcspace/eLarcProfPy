# Détection du réseau

**Fichier :** `common/network.py`

## Rôle

Détecter si l'intranet et/ou le cloud sont accessibles.

## Algorithme

1. `detect_network()` :
   - Tente de résoudre le nom d'hôte de l'intranet.
   - Tente une connexion TCP au port PostgreSQL de l'intranet.
   - Tente une connexion TCP au port PostgreSQL du cloud (Supabase).
   - Retourne un tuple `(intranet_disponible, cloud_disponible)`.

2. `network_mode_color(mode)` : retourne une couleur selon le mode réseau.

## Dépendances

- `socket`
- `common.database._find_cfg` (pour lire les hôtes)
