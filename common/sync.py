"""
Synchronisation device ↔ serveur via le pattern shadow-table (`_ref`).

Voir CONTEXT.md (section "Architecture de synchronisation") pour la philosophie.

Pattern :
- Chaque table métier a une jumelle `<table>_ref` au schéma identique.
- `<table>`     : état local courant (modifié par le prof).
- `<table>_ref` : snapshot du dernier état serveur connu (à la dernière synchro réussie).

Diff au niveau cellule, lignes joinées par `id`.
Matrice de décision par cellule (local vs ref / serveur vs ref) :
    =/= : no-op
    =/≠ : pull  (local = serveur, ref = serveur)
    ≠/= : push  (serveur = local, ref = local)
    ≠/≠ : conflit → IHM de résolution

Scope : `WHERE term_id = module_config.trimestre_courant` uniquement.
Les trimestres passés sont figés et ignorés par le diff.

Squelette — implémentation à compléter (pas avant validation du schéma serveur réel).
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable, Optional

from .database import db
from .logger import log as _log
from .sqlite_init import BUSINESS_TABLES


class CellAction(Enum):
    """Action déduite de la matrice de décision pour une cellule."""
    NOOP = 'noop'
    PULL = 'pull'
    PUSH = 'push'
    CONFLICT = 'conflict'


@dataclass
class CellDiff:
    """Une cellule en divergence entre local/ref/serveur."""
    table: str
    row_id: int
    column: str
    local_value: object
    ref_value: object
    server_value: object
    action: CellAction


@dataclass
class SyncReport:
    """Résultat d'une passe de synchro."""
    pulled: int = 0
    pushed: int = 0
    conflicts: list = field(default_factory=list)   # list[CellDiff]
    errors: list = field(default_factory=list)       # list[str]


class SyncManager:
    """
    Orchestrateur de la synchro device ↔ serveur.

    Toutes les méthodes opèrent sur le `trimestre_courant` lu dans
    `module_config`. Les trimestres passés sont hors scope.
    """

    def __init__(self) -> None:
        self._current_term: Optional[int] = None

    # ------------------------------------------------------------------
    # Point d'entrée principal
    # ------------------------------------------------------------------
    def pull_push(self) -> SyncReport:
        """
        Synchronise les 3 tables métiers pour le trimestre courant.
        Lit `trimestre_courant` dans `module_config`, applique la matrice
        de décision cellule par cellule, met à jour `sync_state` à la fin.

        Les conflits non-résolus sont retournés dans `SyncReport.conflicts`
        pour traitement IHM ultérieur via `apply_resolution()`.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Briques unitaires
    # ------------------------------------------------------------------
    def compute_cell_diff(self, table: str) -> Iterable[CellDiff]:
        """
        Calcule la liste des cellules en divergence pour une table donnée.
        Joint local + `<table>_ref` + serveur sur `id`, filtre par
        `term_id = trimestre_courant`, ne retourne que les cellules
        dont l'action n'est pas NOOP.
        """
        raise NotImplementedError

    def apply_pull(self, diff: CellDiff) -> None:
        """Applique un pull : `local = serveur`, `ref = serveur`."""
        raise NotImplementedError

    def apply_push(self, diff: CellDiff) -> None:
        """Applique un push : `serveur = local`, `ref = local`."""
        raise NotImplementedError

    def apply_resolution(self, diff: CellDiff, keep: str) -> None:
        """
        Applique la résolution choisie par le prof sur un conflit.
        `keep` ∈ {'local', 'server'}. Met à jour la cellule des 3 côtés
        (local, ref, serveur) avec la valeur retenue.
        """
        raise NotImplementedError

    def touch_sync_state(self, table: str) -> None:
        """Met à jour `sync_state.last_sync` pour la table à `now()`."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Garde-fous
    # ------------------------------------------------------------------
    def _ensure_current_term(self) -> int:
        """Lit `trimestre_courant` depuis `module_config`. Erreur si absent."""
        raise NotImplementedError

    def _ensure_server_connected(self) -> None:
        """Vérifie qu'une connexion serveur est active (intranet ou cloud)."""
        raise NotImplementedError


# Singleton global, à l'image de `db` et `sqlite_init`.
sync = SyncManager()
