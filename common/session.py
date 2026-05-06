from __future__ import annotations
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class UserRole(Enum):
    PROF  = 'PROF'
    COORD = 'COORD'
    SECR  = 'SECR'
    ADMIN = 'ADMIN'


class ConnMode(Enum):
    INTRANET     = 'Intranet'
    CLOUD        = 'Cloud'
    OFFLINE      = 'Hors connexion'
    NEW_INSTANCE = 'Nouvelle instance'


@dataclass
class AuthResult:
    user_id    : int      = 0
    email      : str      = ''
    full_name  : str      = ''
    role       : UserRole = field(default_factory=lambda: UserRole.PROF)
    term_id    : int      = 0
    term_label : str      = ''


@dataclass
class Session:
    user_id           : int                = 0
    email             : str                = ''
    full_name         : str                = ''
    role              : UserRole           = field(default_factory=lambda: UserRole.PROF)
    active_term_id    : int                = 0
    active_term_label : str                = ''
    conn_mode         : Optional[ConnMode] = None
    is_authenticated  : bool               = False
    instance_dir      : str                = ''


session: Session = Session(
    instance_dir=os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    )
)
