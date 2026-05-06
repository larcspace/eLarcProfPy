import os
import hashlib
import secrets
import base64
import configparser
import threading
import webbrowser
import json
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Tuple

from .session import AuthResult, UserRole
from .database import db, DBMode


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


def _sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode('utf-8')).hexdigest()


def _deduce_role(is_teacher: bool, is_coord: bool, is_secr: bool, is_admin: bool) -> UserRole:
    if is_admin: return UserRole.ADMIN
    if is_coord: return UserRole.COORD
    if is_secr:  return UserRole.SECR
    return UserRole.PROF


def _load_active_term(cur) -> Tuple[int, str]:
    try:
        cur.execute(
            "SELECT id, label FROM larcib_term "
            "WHERE is_active = TRUE ORDER BY id DESC LIMIT 1"
        )
        row = cur.fetchone()
        if row:
            return row[0], row[1]
    except Exception:
        pass
    return 0, ''


class AuthManager:

    @classmethod
    def auth_intranet(cls, email: str, password: str) -> Tuple[bool, AuthResult, str]:
        conn = db.server_conn
        if conn is None or db.mode != DBMode.INTRANET:
            return False, AuthResult(), "Non connecté à l'intranet"

        pass_hash = _sha256_hex(password)
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, email, nom, prenom, passdelph, enabled "
                    "FROM larcauth_aecuser WHERE LOWER(email) = %s",
                    (email.strip().lower(),)
                )
                row = cur.fetchone()

            if row is None:
                return False, AuthResult(), 'Utilisateur introuvable'
            if not row[5]:
                return False, AuthResult(), 'Compte désactivé'
            if row[4] != pass_hash:
                return False, AuthResult(), 'Mot de passe incorrect'

            user_id   = row[0]
            full_name = f"{row[3]} {row[2]}".strip()

            with conn.cursor() as cur:
                cur.execute(
                    "SELECT is_teacher, is_coord, is_secr, is_admin "
                    "FROM larcauth_teachadm WHERE user_id = %s AND enabled = TRUE",
                    (user_id,)
                )
                tadm = cur.fetchone()

            if tadm is None:
                return False, AuthResult(), 'Aucun profil enseignant/admin trouvé'

            role = _deduce_role(*tadm)

            with conn.cursor() as cur:
                term_id, term_label = _load_active_term(cur)

            return True, AuthResult(
                user_id=user_id,
                email=email.strip().lower(),
                full_name=full_name,
                role=role,
                term_id=term_id,
                term_label=term_label,
            ), ''

        except Exception as e:
            return False, AuthResult(), str(e)

    @classmethod
    def auth_pin(cls, email: str, pin: str) -> Tuple[bool, AuthResult, str]:
        local = db.local_conn
        if local is None:
            return False, AuthResult(), 'Base locale non disponible'

        pin_hash = _sha256_hex(pin)
        try:
            row = local.execute(
                "SELECT user_id, email, full_name, role, term_id, term_label "
                "FROM session_cache WHERE LOWER(email) = ? AND pin_hash = ?",
                (email.strip().lower(), pin_hash)
            ).fetchone()
            if row is None:
                return False, AuthResult(), 'Email ou PIN incorrect'
            return True, AuthResult(
                user_id=int(row['user_id']),
                email=row['email'],
                full_name=row['full_name'],
                role=UserRole(row['role']),
                term_id=int(row['term_id'] or 0),
                term_label=row['term_label'] or '',
            ), ''
        except Exception as e:
            return False, AuthResult(), str(e)


# ---------------------------------------------------------------------------
# OAuth2 PKCE — Google Workspace @arc-en-ciel.org
# ---------------------------------------------------------------------------

class _CallbackHandler(BaseHTTPRequestHandler):
    code:  str             = ''
    event: threading.Event = threading.Event()

    def do_GET(self) -> None:
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in qs:
            _CallbackHandler.code = qs['code'][0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(
            '<html><body style="font-family:sans-serif;text-align:center;padding:40px">'
            '<h2>✔ Authentification réussie</h2>'
            '<p>Vous pouvez fermer cet onglet et revenir à eLarcProf.</p>'
            '</body></html>'.encode('utf-8')
        )
        _CallbackHandler.event.set()

    def log_message(self, *args) -> None:
        pass


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


class OAuth2Manager:
    PORT         = 8765
    REDIRECT     = f'http://localhost:{PORT}/callback'
    GOOGLE_AUTH  = 'https://accounts.google.com/o/oauth2/v2/auth'
    GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token'

    @classmethod
    def authenticate(cls) -> Tuple[bool, AuthResult, str]:
        cfg = configparser.ConfigParser()
        cfg.read(_find_cfg())
        client_id     = cfg.get('OAuth2', 'ClientID',     fallback='')
        client_secret = cfg.get('OAuth2', 'ClientSecret', fallback='')
        if not client_id:
            return False, AuthResult(), 'ClientID OAuth2 manquant dans config.ini'

        verifier  = _b64url(secrets.token_bytes(32))
        challenge = _b64url(hashlib.sha256(verifier.encode('ascii')).digest())
        state     = _b64url(secrets.token_bytes(16))

        params = {
            'client_id':             client_id,
            'redirect_uri':          cls.REDIRECT,
            'response_type':         'code',
            'scope':                 'openid email profile',
            'code_challenge':        challenge,
            'code_challenge_method': 'S256',
            'state':                 state,
            'hd':                    'arc-en-ciel.org',
            'access_type':           'offline',
            'prompt':                'select_account',
        }
        auth_url = cls.GOOGLE_AUTH + '?' + urllib.parse.urlencode(params)

        _CallbackHandler.code = ''
        _CallbackHandler.event.clear()

        srv = HTTPServer(('localhost', cls.PORT), _CallbackHandler)
        threading.Thread(target=srv.handle_request, daemon=True).start()
        webbrowser.open(auth_url)

        if not _CallbackHandler.event.wait(timeout=120):
            srv.server_close()
            return False, AuthResult(), 'Délai de 2 min dépassé'

        srv.server_close()
        code = _CallbackHandler.code
        if not code:
            return False, AuthResult(), 'Code OAuth2 non reçu'

        # Exchange code → tokens
        token_body = urllib.parse.urlencode({
            'code':          code,
            'client_id':     client_id,
            'client_secret': client_secret,
            'redirect_uri':  cls.REDIRECT,
            'grant_type':    'authorization_code',
            'code_verifier': verifier,
        }).encode()
        try:
            req = urllib.request.Request(
                cls.GOOGLE_TOKEN, data=token_body, method='POST',
                headers={'Content-Type': 'application/x-www-form-urlencoded'}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                tokens = json.loads(resp.read())
        except Exception as e:
            return False, AuthResult(), f'Échange de token échoué : {e}'

        id_token = tokens.get('id_token', '')
        if not id_token:
            return False, AuthResult(), 'Token ID absent de la réponse'

        # Decode JWT payload (trust Google HTTPS, no sig needed)
        parts = id_token.split('.')
        if len(parts) < 2:
            return False, AuthResult(), 'Token ID malformé'
        pad     = '=' * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + pad))

        email = payload.get('email', '')
        hd    = payload.get('hd', '')
        if hd != 'arc-en-ciel.org':
            return False, AuthResult(), f'Domaine non autorisé : {hd or "(aucun)"}'

        # Lookup user in DB
        conn = db.server_conn
        if conn is None:
            # Partial result — no DB yet
            return True, AuthResult(email=email, full_name=payload.get('name', '')), ''

        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, nom, prenom FROM larcauth_aecuser "
                    "WHERE LOWER(email) = %s AND enabled = TRUE",
                    (email.lower(),)
                )
                row = cur.fetchone()
            if row is None:
                return False, AuthResult(), f'Utilisateur {email} non trouvé'

            user_id   = row[0]
            full_name = f"{row[2]} {row[1]}".strip()

            with conn.cursor() as cur:
                cur.execute(
                    "SELECT is_teacher, is_coord, is_secr, is_admin "
                    "FROM larcauth_teachadm WHERE user_id = %s AND enabled = TRUE",
                    (user_id,)
                )
                tadm = cur.fetchone()
            if tadm is None:
                return False, AuthResult(), 'Aucun profil enseignant/admin trouvé'

            role = _deduce_role(*tadm)
            with conn.cursor() as cur:
                term_id, term_label = _load_active_term(cur)

            return True, AuthResult(
                user_id=user_id, email=email, full_name=full_name,
                role=role, term_id=term_id, term_label=term_label,
            ), ''
        except Exception as e:
            return False, AuthResult(), str(e)
