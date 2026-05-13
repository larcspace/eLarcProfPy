import os
import socket
import configparser
import urllib.request
from enum import Enum


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


class NetworkMode(Enum):
    INTRANET = 'intranet'
    INTERNET = 'internet'
    OFFLINE  = 'offline'


def network_mode_color(mode: NetworkMode) -> str:
    return {
        NetworkMode.INTRANET: '#27ae60',
        NetworkMode.INTERNET: '#2980b9',
        NetworkMode.OFFLINE:  '#e67e22',
    }.get(mode, '#7f8c8d')


def detect_network() -> tuple[bool, bool]:
    """Retourne (intranet_ok, internet_ok)."""
    cfg = configparser.ConfigParser()
    cfg.read(_find_cfg())
    host = cfg.get('IntranetDatabase', 'Host', fallback='192.168.2.90')
    port = cfg.getint('IntranetDatabase', 'Port', fallback=5432)

    intranet_ok = False
    internet_ok = False

    try:
        with socket.create_connection((host, port), timeout=1.5):
            intranet_ok = True
    except OSError:
        pass

    try:
        urllib.request.urlopen('https://www.google.com', timeout=3)
        internet_ok = True
    except Exception:
        pass

    return (intranet_ok, internet_ok)
