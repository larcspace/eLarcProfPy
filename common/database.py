import os
import configparser
import sqlite3
from enum import Enum, auto
from typing import Optional

try:
    import psycopg2
    _PG_OK = True
except ImportError:
    _PG_OK = False


from .logger import log as _log

def _find_cfg() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, '..', 'config.ini'),
        os.path.join(here, '..', '..', 'eLarcProf', 'config.ini'),
    ]
    for p in candidates:
        p = os.path.normpath(p)
        if os.path.isfile(p):
            return p
    # Aucun fichier trouvé, retourner le premier candidat (qui n'existe pas)
    _log("AVERTISSEMENT : config.ini introuvable. Utilisation des valeurs par défaut.")
    print("AVERTISSEMENT : config.ini introuvable. Utilisation des valeurs par défaut.")
    return os.path.normpath(candidates[0])


class DBMode(Enum):
    NONE     = auto()
    INTRANET = auto()
    CLOUD    = auto()
    SQLITE   = auto()


class Database:
    def __init__(self) -> None:
        self._intranet: Optional[object] = None
        self._cloud:    Optional[object] = None
        self._sqlite:   Optional[sqlite3.Connection] = None
        self._mode = DBMode.NONE

    def _pg_params(self, section: str) -> dict:
        cfg = configparser.ConfigParser()
        cfg.read(_find_cfg())
        # Pour la section IntranetDatabase, utiliser NewLarcDB comme base par défaut
        default_db = 'NewLarcDB' if section == 'IntranetDatabase' else 'postgres'
        return {
            'host':             cfg.get(section, 'Host', fallback='127.0.0.1'),
            'port':             cfg.getint(section, 'Port', fallback=5432),
            'dbname':           cfg.get(section, 'DB',   fallback=default_db),
            'user':             cfg.get(section, 'User', fallback='postgres'),
            'password':         cfg.get(section, 'Pass', fallback=''),
            'application_name': 'eLarcProf',
            'connect_timeout':  5,
        }

    def connect_intranet(self) -> bool:
        if not _PG_OK:
            _log("connect_intranet: psycopg2 non installé")
            print("connect_intranet: psycopg2 non installé")
            return False
        try:
            if self._intranet:
                self._intranet.close()
            params = self._pg_params('IntranetDatabase')
            msg = (f"connect_intranet: tentative de connexion à {params['host']}:{params['port']}/{params['dbname']} "
                   f"utilisateur={params['user']}")
            _log(msg)
            print(msg)
            self._intranet = psycopg2.connect(**params)
            self._intranet.autocommit = True
            self._mode = DBMode.INTRANET
            _log("connect_intranet: connexion réussie")
            print("connect_intranet: connexion réussie")
            return True
        except Exception as e:
            msg = f"connect_intranet: échec : {e}"
            _log(msg)
            print(msg)
            self._mode = DBMode.NONE
            return False

    def connect_cloud(self) -> bool:
        if not _PG_OK:
            _log("connect_cloud: psycopg2 non installé")
            print("connect_cloud: psycopg2 non installé")
            return False
        try:
            if self._cloud:
                self._cloud.close()
            params = self._pg_params('SupabaseDatabase')
            msg = (f"connect_cloud: tentative de connexion à {params['host']}:{params['port']}/{params['dbname']} "
                   f"utilisateur={params['user']}")
            _log(msg)
            print(msg)
            self._cloud = psycopg2.connect(**params)
            self._cloud.autocommit = True
            self._mode = DBMode.CLOUD
            _log("connect_cloud: connexion réussie")
            print("connect_cloud: connexion réussie")
            return True
        except Exception as e:
            msg = f"connect_cloud: échec : {e}"
            _log(msg)
            print(msg)
            self._mode = DBMode.NONE
            return False

    def connect_sqlite(self, db_path: str = '') -> bool:
        if not db_path:
            db_path = os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), '..', 'elarc.db'
            ))
        try:
            if self._sqlite:
                self._sqlite.close()
            self._sqlite = sqlite3.connect(db_path, check_same_thread=False)
            self._sqlite.row_factory = sqlite3.Row
            self._sqlite.execute('PRAGMA journal_mode=WAL')
            self._mode = DBMode.SQLITE
            return True
        except Exception:
            self._mode = DBMode.NONE
            return False

    def disconnect_all(self) -> None:
        for attr in ('_intranet', '_cloud'):
            conn = getattr(self, attr, None)
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
                setattr(self, attr, None)
        if self._sqlite:
            try:
                self._sqlite.close()
            except Exception:
                pass
            self._sqlite = None
        self._mode = DBMode.NONE

    def before_update(self, user_id: int) -> None:
        conn = self.server_conn
        if conn is None:
            return
        with conn.cursor() as cur:
            cur.execute("SET LOCAL app.sync_source = 'intranet'")
            cur.execute(f"SET LOCAL app.modified_by = {int(user_id)}")

    @property
    def server_conn(self):
        if self._mode == DBMode.INTRANET:
            return self._intranet
        if self._mode == DBMode.CLOUD:
            return self._cloud
        return None

    @property
    def local_conn(self) -> Optional[sqlite3.Connection]:
        return self._sqlite

    @property
    def mode(self) -> DBMode:
        return self._mode

    @property
    def is_server_connected(self) -> bool:
        return self.server_conn is not None

    def get_sqlalchemy_url(self, section: str = 'IntranetDatabase') -> str:
        """Retourne une URL de connexion SQLAlchemy pour la section donnée."""
        params = self._pg_params(section)
        # Format : postgresql+psycopg2://user:password@host:port/dbname
        return (f"postgresql+psycopg2://{params['user']}:{params['password']}"
                f"@{params['host']}:{params['port']}/{params['dbname']}")

    def __del__(self) -> None:
        self.disconnect_all()


db = Database()
