import os
import shutil
from typing import Optional

from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QFormLayout,
    QTabWidget, QLabel, QLineEdit, QPushButton, QStatusBar,
    QMessageBox, QFileDialog,
)
from PySide6.QtCore import Qt, QThread, Signal

from common.session import AuthResult, ConnMode, UserRole, session
from common.network import NetworkMode, detect_network, network_mode_color
from common.database import db, DBMode
from common.auth import AuthManager, OAuth2Manager
from common.sqlite_init import sqlite_init


# ---------------------------------------------------------------------------
# Generic background worker
# ---------------------------------------------------------------------------
class _Worker(QThread):
    done = Signal(object)   # emits whatever the function returns

    def __init__(self, fn, *args, parent=None):
        super().__init__(parent)
        self._fn   = fn
        self._args = args

    def run(self):
        try:
            self.done.emit(self._fn(*self._args))
        except Exception as exc:
            self.done.emit((False, None, str(exc)))


# ---------------------------------------------------------------------------
# Login window
# ---------------------------------------------------------------------------
class LoginWindow(QMainWindow):

    _STYLE = """
        QMainWindow  { background: #f5f6fa; }
        QWidget#root { background: #f5f6fa; }
        QTabWidget::pane {
            border: 1px solid #dcdde1; background: white; border-radius: 4px;
        }
        QTabBar::tab          { padding: 8px 20px; font-size: 11px; }
        QTabBar::tab:selected {
            background: white; border-bottom: 2px solid #3498db;
            color: #2c3e50; font-weight: bold;
        }
        QTabBar::tab:!selected { background: #ecf0f1; color: #7f8c8d; }
        QLineEdit {
            padding: 7px 10px; border: 1px solid #bdc3c7;
            border-radius: 4px; font-size: 12px; background: white;
        }
        QLineEdit:focus { border-color: #3498db; }
        QPushButton {
            padding: 9px 20px; border: none; border-radius: 4px;
            font-size: 12px; font-weight: bold; color: white;
        }
        QPushButton#btnIntra  { background: #2980b9; }
        QPushButton#btnIntra:hover  { background: #3498db; }
        QPushButton#btnIntra:disabled  { background: #bdc3c7; }
        QPushButton#btnGoogle { background: #c0392b; }
        QPushButton#btnGoogle:hover { background: #e74c3c; }
        QPushButton#btnGoogle:disabled { background: #bdc3c7; }
        QPushButton#btnPIN    { background: #8e44ad; }
        QPushButton#btnPIN:hover    { background: #9b59b6; }
        QPushButton#btnPIN:disabled { background: #bdc3c7; }
        QPushButton#btnCreate { background: #27ae60; }
        QPushButton#btnCreate:hover { background: #2ecc71; }
        QPushButton#btnCreate:disabled { background: #bdc3c7; }
        QPushButton#btnBrowse {
            background: #7f8c8d; padding: 9px 10px; min-width: 32px;
        }
        QPushButton#btnBrowse:hover { background: #95a5a6; }
        QLabel#errLabel { color: #c0392b; font-size: 11px; }
        QLabel#hdrTitle { color: #2c3e50; font-size: 22px; font-weight: bold; }
        QLabel#hdrSub   { color: #7f8c8d; font-size: 11px; }
        QLabel#infoLbl  { color: #555; font-size: 11px; }
    """

    def __init__(self):
        super().__init__()
        self._worker:     Optional[_Worker] = None
        self._net_worker: Optional[_Worker] = None
        self._net_mode:   Optional[NetworkMode] = None
        self._setup_ui()
        self._start_net_detection()

    # ------------------------------------------------------------------
    # UI
    # ------------------------------------------------------------------
    def _setup_ui(self) -> None:
        self.setWindowTitle('eLarcProf — Connexion')
        self.setMinimumSize(460, 560)
        self.resize(460, 600)
        self.setStyleSheet(self._STYLE)

        root = QWidget()
        root.setObjectName('root')
        self.setCentralWidget(root)
        vbox = QVBoxLayout(root)
        vbox.setContentsMargins(24, 20, 24, 12)
        vbox.setSpacing(12)

        # Header
        title = QLabel('eLarcProf')
        title.setObjectName('hdrTitle')
        sub = QLabel('École Arc-en-Ciel  ·  IB School Management')
        sub.setObjectName('hdrSub')
        vbox.addWidget(title)
        vbox.addWidget(sub)

        # Tabs
        self._tabs = QTabWidget()
        vbox.addWidget(self._tabs, 1)
        self._build_intranet_tab()
        self._build_cloud_tab()
        self._build_pin_tab()
        self._build_new_tab()

        # Error label
        self._err_lbl = QLabel()
        self._err_lbl.setObjectName('errLabel')
        self._err_lbl.setWordWrap(True)
        self._err_lbl.hide()
        vbox.addWidget(self._err_lbl)

        # Status bar
        sb = QStatusBar()
        self.setStatusBar(sb)
        self._dot_lbl = QLabel('●')
        self._dot_lbl.setStyleSheet('color: #95a5a6; font-size: 14px;')
        self._net_txt = QLabel('Détection du réseau…')
        self._ses_txt = QLabel('')
        sb.addWidget(self._dot_lbl)
        sb.addWidget(self._net_txt)
        sb.addPermanentWidget(self._ses_txt)

    def _tab_widget(self) -> tuple:
        """Returns (QWidget tab, QFormLayout, outer QVBoxLayout)"""
        tab  = QWidget()
        vbox = QVBoxLayout(tab)
        vbox.setContentsMargins(20, 20, 20, 20)
        vbox.setSpacing(10)
        form = QFormLayout()
        form.setSpacing(10)
        form.setLabelAlignment(Qt.AlignRight)
        return tab, form, vbox

    def _build_intranet_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        self._edt_i_email = QLineEdit()
        self._edt_i_email.setPlaceholderText('prenom.nom@arc-en-ciel.org')
        self._edt_i_pass  = QLineEdit()
        self._edt_i_pass.setEchoMode(QLineEdit.Password)
        self._edt_i_pass.setPlaceholderText('Mot de passe')
        form.addRow('Email :', self._edt_i_email)
        form.addRow('Mot de passe :', self._edt_i_pass)
        vbox.addLayout(form)

        self._btn_intra = QPushButton('Connexion Intranet')
        self._btn_intra.setObjectName('btnIntra')
        self._btn_intra.clicked.connect(self._on_intranet)
        self._edt_i_pass.returnPressed.connect(self._btn_intra.click)
        vbox.addWidget(self._btn_intra, alignment=Qt.AlignRight)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Intranet')

    def _build_cloud_tab(self) -> None:
        tab, _, vbox = self._tab_widget()

        info = QLabel(
            'Connectez-vous avec votre compte Google @arc-en-ciel.org\n'
            'via le protocole OAuth2 sécurisé (PKCE).\n\n'
            'Votre navigateur s\'ouvrira automatiquement.'
        )
        info.setObjectName('infoLbl')
        info.setAlignment(Qt.AlignCenter)
        info.setWordWrap(True)
        vbox.addStretch()
        vbox.addWidget(info)
        vbox.addSpacing(16)

        self._btn_google = QPushButton('  Connexion avec Google')
        self._btn_google.setObjectName('btnGoogle')
        self._btn_google.clicked.connect(self._on_cloud)
        vbox.addWidget(self._btn_google, alignment=Qt.AlignCenter)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Cloud')

    def _build_pin_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        self._edt_p_email = QLineEdit()
        self._edt_p_email.setPlaceholderText('prenom.nom@arc-en-ciel.org')
        self._edt_p_pin   = QLineEdit()
        self._edt_p_pin.setEchoMode(QLineEdit.Password)
        self._edt_p_pin.setPlaceholderText('Code PIN (4-8 chiffres)')
        self._edt_p_pin.setMaxLength(8)
        form.addRow('Email :', self._edt_p_email)
        form.addRow('PIN :', self._edt_p_pin)
        vbox.addLayout(form)

        note = QLabel('Mode hors connexion — base locale SQLite uniquement.')
        note.setStyleSheet('color: #7f8c8d; font-size: 10px;')
        vbox.addWidget(note)

        self._btn_pin = QPushButton('Connexion PIN')
        self._btn_pin.setObjectName('btnPIN')
        self._btn_pin.clicked.connect(self._on_pin)
        self._edt_p_pin.returnPressed.connect(self._btn_pin.click)
        vbox.addWidget(self._btn_pin, alignment=Qt.AlignRight)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Hors connexion')

    def _build_new_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        info = QLabel(
            'Crée une nouvelle instance personnelle pour un enseignant.\n'
            'Un dossier dédié avec sa propre configuration sera généré.'
        )
        info.setObjectName('infoLbl')
        info.setWordWrap(True)
        vbox.addWidget(info)
        vbox.addSpacing(8)

        self._edt_n_email = QLineEdit()
        self._edt_n_email.setPlaceholderText('enseignant@arc-en-ciel.org')

        self._edt_n_dest = QLineEdit()
        self._edt_n_dest.setPlaceholderText('Dossier parent de destination…')
        self._edt_n_dest.setReadOnly(True)
        btn_browse = QPushButton('…')
        btn_browse.setObjectName('btnBrowse')
        btn_browse.setFixedWidth(36)
        btn_browse.clicked.connect(self._browse_dest)

        dest_row = QHBoxLayout()
        dest_row.addWidget(self._edt_n_dest)
        dest_row.addWidget(btn_browse)

        form.addRow('Email :', self._edt_n_email)
        form.addRow('Destination :', dest_row)
        vbox.addLayout(form)

        self._btn_create = QPushButton("Créer l'instance")
        self._btn_create.setObjectName('btnCreate')
        self._btn_create.clicked.connect(self._on_create)
        vbox.addWidget(self._btn_create, alignment=Qt.AlignRight)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Nouvelle instance')

    # ------------------------------------------------------------------
    # Network detection
    # ------------------------------------------------------------------
    def _start_net_detection(self) -> None:
        self._net_worker = _Worker(lambda: (True, detect_network(), ''))
        self._net_worker.done.connect(self._on_net_detected)
        self._net_worker.start()

    def _on_net_detected(self, result) -> None:
        ok, mode, _ = result
        if not ok or mode is None:
            return
        self._net_mode = mode
        color = network_mode_color(mode)
        self._dot_lbl.setStyleSheet(f'color: {color}; font-size: 14px;')
        labels = {
            NetworkMode.INTRANET: 'Intranet disponible',
            NetworkMode.INTERNET: 'Internet uniquement',
            NetworkMode.OFFLINE:  'Hors connexion',
        }
        self._net_txt.setText(labels.get(mode, ''))
        self._auto_connect(mode)

    def _auto_connect(self, mode: NetworkMode) -> None:
        if mode == NetworkMode.INTRANET:
            self._set_busy(True)
            self._worker = _Worker(db.connect_intranet)
            self._worker.done.connect(lambda ok: self._set_busy(False))
            self._worker.start()
        elif mode == NetworkMode.INTERNET:
            self._set_busy(True)
            self._worker = _Worker(db.connect_cloud)
            self._worker.done.connect(lambda ok: self._set_busy(False))
            self._worker.start()
        else:
            sqlite_init.init()

    # ------------------------------------------------------------------
    # Auth handlers
    # ------------------------------------------------------------------
    def _on_intranet(self) -> None:
        email = self._edt_i_email.text().strip()
        pwd   = self._edt_i_pass.text()
        if not email or not pwd:
            self._show_error('Veuillez saisir votre email et mot de passe.')
            return
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(AuthManager.auth_intranet, email, pwd)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.INTRANET)
        )
        self._worker.start()

    def _on_cloud(self) -> None:
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(OAuth2Manager.authenticate)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.CLOUD)
        )
        self._worker.start()

    def _on_pin(self) -> None:
        email = self._edt_p_email.text().strip()
        pin   = self._edt_p_pin.text()
        if not email or not pin:
            self._show_error('Veuillez saisir votre email et votre PIN.')
            return
        if not sqlite_init.init():
            self._show_error('Impossible d\'ouvrir la base locale.')
            return
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(AuthManager.auth_pin, email, pin)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.OFFLINE)
        )
        self._worker.start()

    def _on_auth_done(self, result, mode: ConnMode) -> None:
        self._set_busy(False)
        ok, res, err = result
        if not ok:
            self._show_error(err or 'Authentification échouée.')
            return
        self._apply_session(res, mode)

    def _apply_session(self, res: AuthResult, mode: ConnMode) -> None:
        session.user_id           = res.user_id
        session.email             = res.email
        session.full_name         = res.full_name
        session.role              = res.role
        session.active_term_id    = res.term_id
        session.active_term_label = res.term_label
        session.conn_mode         = mode
        session.is_authenticated  = True

        # Persist session + offer to set PIN if online auth
        sqlite_init.init()
        if mode in (ConnMode.INTRANET, ConnMode.CLOUD):
            pin, ok = self._ask_pin_setup(res.full_name)
            sqlite_init.save_session(res, pin if ok else '')
        else:
            sqlite_init.save_session(res)

        self._update_status_bar(res, mode)
        self._open_main_window(res)

    def _ask_pin_setup(self, name: str):
        from PySide6.QtWidgets import QInputDialog
        return QInputDialog.getText(
            self, 'PIN hors connexion',
            f'Définissez un PIN pour {name} (laisser vide pour ignorer) :',
            QLineEdit.Password
        )

    # ------------------------------------------------------------------
    # New instance
    # ------------------------------------------------------------------
    def _browse_dest(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, 'Choisir le dossier parent')
        if folder:
            self._edt_n_dest.setText(folder)

    def _on_create(self) -> None:
        email  = self._edt_n_email.text().strip()
        parent = self._edt_n_dest.text().strip()
        if not email or not parent:
            self._show_error('Email et dossier de destination requis.')
            return
        slug = email.split('@')[0].replace('.', '_')
        dest = os.path.join(parent, f'eLarcProf_{slug}')
        try:
            os.makedirs(dest, exist_ok=True)
            # Copy entire project
            src = os.path.normpath(
                os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
            )
            for item in os.listdir(src):
                if item in ('elarc.db', '__pycache__', '.git'):
                    continue
                s = os.path.join(src, item)
                d = os.path.join(dest, item)
                if os.path.isdir(s):
                    shutil.copytree(s, d, dirs_exist_ok=True)
                else:
                    shutil.copy2(s, d)
            # Write instance-specific config stub
            cfg_dest = os.path.join(dest, 'instance.ini')
            with open(cfg_dest, 'w', encoding='utf-8') as f:
                f.write(f'[Instance]\nEmail={email}\nCreated=auto\n')
            # Launcher batch
            bat = os.path.join(dest, 'lancer.bat')
            with open(bat, 'w', encoding='utf-8') as f:
                f.write(f'@echo off\ncd /d "%~dp0"\npython main.py\npause\n')
            QMessageBox.information(
                self, 'Instance créée',
                f'Instance créée dans :\n{dest}\n\nLancez lancer.bat pour démarrer.'
            )
        except Exception as e:
            self._show_error(f'Erreur de création : {e}')

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _set_busy(self, busy: bool) -> None:
        for btn in (self._btn_intra, self._btn_google, self._btn_pin, self._btn_create):
            btn.setEnabled(not busy)
        self._net_txt.setText('Connexion en cours…' if busy else self._net_txt.text())

    def _show_error(self, msg: str) -> None:
        self._err_lbl.setText(msg)
        self._err_lbl.show()

    def _hide_error(self) -> None:
        self._err_lbl.hide()

    def _update_status_bar(self, res: AuthResult, mode: ConnMode) -> None:
        term = f' · {res.term_label}' if res.term_label else ''
        self._ses_txt.setText(
            f'{res.full_name}  |  {res.role.value}{term}  |  {mode.value}'
        )

    def _open_main_window(self, res: AuthResult) -> None:
        from PySide6.QtWidgets import QDialog, QDialogButtonBox
        dlg = QDialog(self)
        dlg.setWindowTitle('eLarcProf')
        dlg.resize(360, 180)
        v = QVBoxLayout(dlg)
        v.addWidget(QLabel(
            f'<b>Bienvenue, {res.full_name}</b><br>'
            f'Rôle : {res.role.value}<br>'
            f'Trimestre : {res.term_label or "—"}<br><br>'
            f'<i>(Phase 2 — tableau de bord à implémenter)</i>'
        ))
        bb = QDialogButtonBox(QDialogButtonBox.Ok)
        bb.accepted.connect(dlg.accept)
        v.addWidget(bb)
        dlg.exec()
