# Liaison gestion administrateur / application chauffeur

Contrat transmis le 7 novembre 2026 depuis l'application `gestion_PDT`.
Ce document transmet les informations ; il ne modifie pas le code chauffeur.
Les changements administrateur sont implementes et verifies : 48 tests
comptabilite/prix/validation reussis, analyse sans erreur bloquante, rechargement
Flutter reussi sans erreur d'execution. Les tests de donnees utilisent des
doublures SDK : aucune course ni aucun paiement de production n'a ete modifie.

## Prix et validation des courses

Projet Firebase partage : `gestion-bmr`, Firestore Standard, base `(default)`.
Collection : `Orders/{orderId}`, identifiant du document faisant foi.

- `price` : prix client, en euros.
- `driverPrice` : remuneration chauffeur, en euros.
- `driverPriceCustom` : booleen distinguant un montant personnalise.
  Pour les anciennes courses sans ce booleen, un `driverPrice` renseigne
  est considere personnalise.
- `validatedForDriverAt` : Timestamp serveur, absent = non valide.
- `paidOnlineCents` : montant paye en ligne, en centimes.
- `paymentMethod` : mode client. L'administrateur reconnait comme paiement
  a bord, apres normalisation minuscules/accents/separateurs :
  `a bord`, `paiement a bord`, `onboard`, `on board`, `cash on delivery`.
- Pourcentage global : `Settings/pricing.driverPercentage`, defaut 20,
  compris entre 0 et 100. Calcul automatique :
  `(price * driverPercentage).round() / 100`.
- La validation fige `driverPrice`. Un prix personnalise ne doit jamais etre
  remplace par le pourcentage global.
- La confirmation administrateur permet de modifier le prix chauffeur,
  individuellement ou pour chaque course d'une selection. Le changement et la
  validation sont enregistres dans la meme transaction ; annuler ne modifie rien.
- Une modification de course cote administrateur efface sa validation.
- Attribution et partage WhatsApp/PDF administrateur exigent une validation.
  La validation n'envoie pas automatiquement la course.

L'application administrateur identifie le chauffeur par l'entree de
`commandStatus` ayant l'`id` non vide et la `date` la plus recente.
Le statut courant est celui de l'entree de date la plus recente.
Pour la comptabilite, seule une course dont le statut courant est
`OrderStatus.COMPLETED` est remuneree. Verifier la representation des statuts
dans les modeles existants avant toute integration cote chauffeur.

## Regles de solde confirmees par l'utilisateur

Le chauffeur garde le montant client encaissé a bord.
Le reste a payer est considere automatiquement encaissé des la fin de la course.
Pas de saisie/confirmation supplementaire d'encaissement a bord.
Historique complet, sans solde initial ni date de depart.

Tous les calculs de solde doivent etre realises en centimes :

```text
remuneration = somme de round(driverPrice * 100) des courses terminees
encaissement_a_bord_course = max(0, round(price * 100) - paidOnlineCents)
encaissements = somme des encaissements des courses terminees payables a bord
solde = remuneration - encaissements - virements_admin - especes_admin
```

`paidOnlineCents` absent vaut zero.
Un solde positif est du au chauffeur. Un solde negatif est a reverser
par le chauffeur a l'administrateur. Ne pas limiter le solde a zero.
Une course annulee, interrompue, non presente ou encore en cours ne doit pas
alimenter le solde. Utiliser les prix chauffeur stockes, jamais recalcules
avec le pourcentage courant. Une remuneration inconnue ne doit pas etre
inventee : signaler le probleme et afficher un solde provisoire.

## Nouveau journal des paiements administrateur

Chemin : `Drivers/{driverId}/Payments/{paymentId}`.

| Champ | Type | Signification |
| --- | --- | --- |
| `amountCents` | entier strictement positif | Montant deja verse au chauffeur |
| `date` | Timestamp | Date du paiement, pas une date future |
| `method` | chaine | `transfer` pour virement, `cash` pour especes |
| `note` | chaine | Note/reference facultative, peut etre vide |
| `administratorId` | chaine | UID de l'administrateur ayant saisi le paiement |
| `createdAt` | Timestamp serveur | Horodatage de l'enregistrement |

Les virements et especes sont saisis par l'administrateur : aucun transfert
bancaire n'est declenche par l'application. Le paiement est ajoute dans une
transaction avec un identifiant stable, pour eviter les doubles ecritures
lors d'une nouvelle tentative. `Drivers/{driverId}.hasAccountingHistory`
est marque `true` pour proteger l'historique contre la suppression du profil.
Le journal est trie par date cote client ; aucun index composite n'est requis.
Aucun champ `balance`/`solde` n'est stocke : le solde est derive des deux sources.

## Integration attendue cote chauffeur

- Lire les cours et paiements du chauffeur connecte uniquement.
- Appliquer obligatoirement le filtrage des courses et notifications decrit
  ci-dessous avant toute presentation au chauffeur.
- Afficher remuneration, encaissements a bord, virements, especes et solde signe.
- Montrer l'historique et les donnees manquantes ; ne pas transformer une erreur
  de chargement en solde nul ou en liste vide.
- Le journal des paiements administrateur est en lecture seule dans l'interface
  chauffeur ; ne pas ajouter de paiement depuis cette application.
- Ne pas deployer de regles, migrer des documents ni changer les fonctions
  backend sans accord de l'utilisateur.

## Instruction obligatoire : courses validees et notifications

L'application chauffeur doit afficher uniquement les courses dont
`validatedForDriverAt` est un Timestamp valide et non nul. Un champ absent,
null ou de type invalide signifie que la course n'est pas publiable.
Ne pas deduire la validation de l'attribution, du statut ou du prix chauffeur.
Conserver en plus les restrictions existantes de destinataire, de categorie
et de statut : une validation ne rend pas la course visible a tous.

Appliquer cette condition a toutes les surfaces : listes de courses disponibles
ou attribuees, recherche, carte, details, liens directs et donnees en cache.
Avant d'ouvrir ou d'accepter une course, relire son document sur le serveur et
verifier sa validation ainsi que son eligibilite pour le chauffeur connecte.
Si sa validation est retiree, la masquer et bloquer les actions liees ; un ancien
cache ou lien ne doit pas permettre de contourner cette condition. Si la lecture
echoue, signaler que la verification est impossible, sans autoriser l'action.

Pour les notifications concernant une course :

- Ne pas envoyer de notification push, locale ou dans l'application pour une
  course non validee. Verifier le document courant avant l'envoi et conserver
  les conditions existantes de destinataire et de statut.
- La creation d'une course sans validation ne doit pas declencher d'alerte.
  La transition non validee -> validee doit pouvoir declencher l'alerte prevue
  pour une course eligible, meme si le document existait deja avant validation.
- Eviter les doublons sur les mises a jour et les nouvelles tentatives :
  identifier l'evenement par course, destinataire, type d'alerte et version
  de validation (`validatedForDriverAt`).
- Avant d'afficher une notification locale ou dans l'application, puis a
  l'ouverture de toute notification ou lien, verifier la validation courante.
  Une notification obsolete ne doit plus ouvrir une course devenue non validee.
- Une notification push deja livree ne peut pas etre rappelee de facon fiable.
  Le controle a l'ouverture reste obligatoire.
- Ces conditions concernent les notifications de courses uniquement :
  conserver les alertes de compte, de paiement et les autres notifications.

Le filtrage Flutter ne peut pas empecher a lui seul un push envoye par le
backend. Identifier les producteurs de notifications (fonctions, traitements
programmes et services existants) et y appliquer le meme controle avant envoi.
Toute modification/deploiement backend reste soumis a l'accord utilisateur ;
tant qu'il n'est pas realise, ne pas annoncer que les push sont effectivement
bloques. Cette instruction definit le comportement a implementer, sans modifier
ni deployer le code chauffeur ou le backend depuis ce document.

Verification attendue : aucune course/alerte pour un champ absent, null ou
invalide ; affichage et alerte eligible apres validation ; pas de doublon sur
une mise a jour sans nouvelle validation ; retrait apres invalidation ;
ancien lien et notification bloques a l'ouverture ; erreurs serveur explicites ;
notifications non liees aux courses preservees.

La politique Firebase partagee actuelle est large pour les comptes
authentifies. Les controles d'interface ne sont pas une protection serveur.
Ce contrat n'ajoute aucune garantie d'autorisation aux regles deja deployees.

## Sources administrateur

Racine : `C:\Users\T14_11\Documents\Projects\pro du transport\flutter\gestion_PDT`.

- `lib/models/driver_account.dart` : calculs comptables, journal type.
- `lib/services/firebase/driver_accounts.dart` : lecture et saisie transactionnelle.
- `lib/screens/drivers/driver_account_page.dart` : statistiques, solde et paiements.
- `lib/services/hive/hive_database.dart` : modele de course et attribution.
- `lib/services/firebase/firebase.dart` : validation et prix fige.
