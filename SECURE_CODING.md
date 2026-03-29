# Politique Secure Coding (Référentiel 2026)

Ce document est normatif pour ce dépôt.

- `MUST` = obligatoire
- `SHOULD` = fortement recommandé, écart justifié
- `MAY` = optionnel

## Sources de référence (vérifiées le 29 mars 2026)

### Références FR (ANSSI)

1. ANSSI-PA-073, *Règles de programmation pour le développement sécurisé de logiciels en langage C* (v1.2, 21/07/2020)  
   https://messervices.cyber.gouv.fr/documents-guides/anssi-guide-regles_de_programmation_pour_le_developpement_securise_de_logiciels_en_langage_c-v1.2.pdf
2. ANSSI, *Recommandations pour la mise en œuvre d'un site web : maîtriser les standards de sécurité côté navigateur* (v2.0)  
   https://messervices.cyber.gouv.fr/documents-guides/anssi-guide-recommandations_mise_en_oeuvre_site_web_maitriser_standards_securite_cote_navigateur-v2.0.pdf

### Références internationales (état de l’art 2025/2026)

1. OWASP ASVS (version stable 5.0.0, annoncée 30/05/2025)  
   https://owasp.org/www-project-application-security-verification-standard/
2. OWASP Top 10:2025  
   https://owasp.org/Top10/2025/
3. NIST SP 800-218, SSDF v1.1 (final)  
   https://csrc.nist.gov/pubs/sp/800/218/final
4. NIST SP 800-218A (profil SSDF GenAI, final juillet 2024)  
   https://csrc.nist.gov/pubs/sp/800/218/a/final
5. MITRE CWE Top 25 (édition 2025, mise à jour 10/12/2025)  
   https://cwe.mitre.org/top25/archive/2025/2025_key_insights.html

## Exigences obligatoires (MUST)

### 1) Gestion des secrets

- Les secrets (JWT, tokens, mots de passe, clés) ne doivent jamais passer en arguments CLI.
- Les secrets ne doivent jamais être écrits dans des fichiers temporaires, logs, dumps, artefacts de debug.
- Le transport inter-processus des secrets doit passer par `stdin` (ou keyring), pas par argv.
- Les mots de passe utilisateur ne sont jamais persistés.
- Le stockage persistant de token doit utiliser le trousseau OS (Secret Service/libsecret).

### 2) Hygiène mémoire / cycle de vie secret

- Shell: toute variable sensible doit être `unset` dès la fin d’usage.
- Shell: un `trap ... EXIT` doit nettoyer les temporaires et variables sensibles.
- Python: les variables sensibles doivent être vidées (`var = ""`) et nettoyées en `finally` quand applicable.
- Les structures d’erreur ne doivent pas inclure les secrets en clair.

### 3) Réseau et transport

- La vérification TLS doit rester activée dans les flux d’authentification et de soumission.
- Les options de bypass TLS (`--insecure`, équivalent) sont interdites dans les chemins de production.
- Les appels HTTP doivent limiter les surfaces de fuite (messages d’erreur bornés, pas d’entêtes auth loggés).

### 4) Logging / observabilité

- Interdiction de logger token/jwt/password/secret, y compris dans les champs `key=value`.
- Les logs doivent rester orientés diagnostic (métadonnées) sans contenu sensible.
- Les erreurs utilisateurs doivent être explicites sans exposer de matériau d’auth.

### 5) Fichiers et permissions

- Les fichiers de token sur disque doivent rester en moindre privilège (`root:lp`, `640`).
- Les répertoires sensibles doivent rester restreints (`750` ou plus strict selon besoin).
- Le stockage plaintext d’ID token en config est interdit par défaut (break-glass explicite uniquement).
- Les scripts qui lisent des fichiers sensibles (`config.env`, `tokens/*.jwt`) doivent refuser les symlinks.
- Les scripts qui lisent/sourcent des fichiers sensibles doivent vérifier owner/groupe/mode avant usage.
- Les écritures de tokens sur disque doivent être atomiques (fichier temporaire privé puis `mv`).
- Les helpers privilégiés (`sudo`/root) doivent appliquer un binding strict appelant->cible (pas de sync cross-user).
- Les opérations “default token” doivent rester réservées à une exécution root explicite (pas via règle sudo de groupe).

### 6) Défense en profondeur CI

- `tests/security/secure_coding_guard.sh` doit passer avant livraison.
- Toute régression sur règles secrets/TLS doit bloquer la validation.

## Règles SHOULD (fortement recommandées)

- Réduire la durée de vie en mémoire des secrets au strict minimum.
- Préférer des flux éphémères et non interactifs sûrs pour l’automatisation (`stdin` + keyring).
- Ajouter des tests de non-régression sécurité pour chaque nouveau flux auth/session.

## Implémentation appliquée dans ce projet

- Flux login setup: mot de passe en prompt masqué, non stocké.
- Flux token: passage par `stdin` vers les scripts consommateurs de secrets.
- Stockage token: keyring OS + synchronisation contrôlée vers le backend CUPS.
- Politique anti-régression: garde-fou automatisé en test.

## Checklist de revue sécurité (obligatoire en PR)

1. Aucun secret en argument de commande (`ps` / `/proc/*/cmdline`).
2. Aucun secret dans les logs/erreurs/artefacts.
3. Aucun secret dans fichier temporaire.
4. Variables sensibles nettoyées (`unset`/clear) après usage.
5. TLS non contourné.
6. Permissions de stockage conformes.
7. Vérifications anti-symlink/owner/mode présentes sur les chemins sensibles.
8. Garde-fou sécurité + suite de tests exécutés.
