import os
import sys
from datetime import datetime

# Indicateur pour activer/désactiver l'écriture dans le fichier log
LOG_TO_FILE = True

# Chemin du fichier log
_LOG_PATH = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'elarc.log'
))


def log(msg: str) -> None:
    """Écrit un message dans le fichier log si LOG_TO_FILE est True."""
    if not LOG_TO_FILE:
        return
    try:
        with open(_LOG_PATH, 'a', encoding='utf-8') as f:
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            f.write(f"[{timestamp}] {msg}\n")
    except Exception:
        pass  # Ignorer les erreurs d'écriture


def set_log_to_file(value: bool) -> None:
    """Modifie l'indicateur LOG_TO_FILE."""
    global LOG_TO_FILE
    LOG_TO_FILE = value


def get_log_path() -> str:
    """Retourne le chemin du fichier log."""
    return _LOG_PATH
