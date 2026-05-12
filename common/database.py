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
            return False
        try:
            if self._intranet:
                self._intranet.close()
            self._intranet = psycopg2.connect(**self._pg_params('IntranetDatabase'))
            self._intranet.autocommit = True
            self._mode = DBMode.INTRANET
            return True
        except Exception:
            self._mode = DBMode.NONE
            return False

    def connect_cloud(self) -> bool:
        if not _PG_OK:
            return False
        try:
            if self._cloud:
                self._cloud.close()
            self._cloud = psycopg2.connect(**self._pg_params('SupabaseDatabase'))
            self._cloud.autocommit = True
            self._mode = DBMode.CLOUD
            return True
        except Exception:
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

    def __del__(self) -> None:
        self.disconnect_all()


db = Database()
