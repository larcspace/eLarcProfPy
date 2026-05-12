import hashlib
from typing import Optional

from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QFormLayout, QLineEdit, QPushButton,
    QLabel, QMessageBox, QDialogButtonBox
)
from PySide6.QtCore import Qt

from common.database import db, DBMode
from common.auth import AuthManager


def _sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode('utf-8')).hexdigest()


class ChangePasswordDialog(QDialog):
    """Boîte de dialogue pour changer le mot de passe Intranet."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle('Changer le mot de passe')
        self.setMinimumWidth(400)
        self.setModal(True)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        # Titre
        title = QLabel('Modification du mot de passe Intranet')
        title.setStyleSheet('font-size: 14px; font-weight: bold; color: #2c3e50;')
        layout.addWidget(title)

        # Formulaire
        form = QFormLayout()
        form.setSpacing(8)

        self._email_edit = QLineEdit()
        self._email_edit.setPlaceholderText('prenom.nom@arc-en-ciel.org')
        self._old_pass_edit = QLineEdit()
        self._old_pass_edit.setEchoMode(QLineEdit.Password)
        self._old_pass_edit.setPlaceholderText('Ancien mot de passe')
        self._new_pass_edit = QLineEdit()
        self._new_pass_edit.setEchoMode(QLineEdit.Password)
        self._new_pass_edit.setPlaceholderText('Nouveau mot de passe')
        self._confirm_pass_edit = QLineEdit()
        self._confirm_pass_edit.setEchoMode(QLineEdit.Password)
        self._confirm_pass_edit.setPlaceholderText('Confirmer le nouveau mot de passe')

        form.addRow('Email :', self._email_edit)
        form.addRow('Ancien mot de passe :', self._old_pass_edit)
        form.addRow('Nouveau mot de passe :', self._new_pass_edit)
        form.addRow('Confirmer :', self._confirm_pass_edit)

        layout.addLayout(form)

        # Boutons
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        self._error_label = QLabel()
        self._error_label.setStyleSheet('color: #c0392b; font-size: 11px;')
        self._error_label.hide()
        layout.addWidget(self._error_label)

    def _on_accept(self) -> None:
        email = self._email_edit.text().strip()
        old_pass = self._old_pass_edit.text()
        new_pass = self._new_pass_edit.text()
        confirm = self._confirm_pass_edit.text()

        if not email or not old_pass or not new_pass or not confirm:
            self._show_error('Tous les champs sont obligatoires.')
            return

        if new_pass != confirm:
            self._show_error('Les nouveaux mots de passe ne correspondent pas.')
            return

        if len(new_pass) < 6:
            self._show_error('Le nouveau mot de passe doit contenir au moins 6 caractères.')
            return

        # Vérifier l'ancien mot de passe via AuthManager (qui accepte Aec-2026)
        ok, _, err = AuthManager.auth_intranet(email, old_pass)
        if not ok:
            self._show_error(f'Ancien mot de passe incorrect : {err}')
            return

        # Mettre à jour le mot de passe dans PostgreSQL
        conn = db.server_conn
        if conn is None or db.mode != DBMode.INTRANET:
            self._show_error('Pas de connexion Intranet.')
            return

        new_hash = _sha256_hex(new_pass)
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE larcauth_aecuser SET password = %s "
                    "WHERE LOWER(email) = %s",
                    (new_hash, email.lower())
                )
            conn.commit()
            QMessageBox.information(self, 'Succès', 'Mot de passe modifié avec succès.')
            self.accept()
        except Exception as e:
            self._show_error(f'Erreur lors de la mise à jour : {e}')

    def _show_error(self, msg: str) -> None:
        self._error_label.setText(msg)
        self._error_label.show()
