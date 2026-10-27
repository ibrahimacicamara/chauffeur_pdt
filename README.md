# chauffeur

Application Flutter avec une page de connexion Firebase en français.

## Politique d'acces Firestore et Storage

Les fichiers `firestore.rules` et `storage.rules` autorisent toute lecture et
toute ecriture (creation, modification et suppression) a tous les utilisateurs
Firebase authentifies, y compris les comptes anonymes. Le compte administrateur
`YGE0x3Im8XUtmxWBtD740mszQ3B2` est explicitement reconnu et dispose des memes
droits complets. Les requetes sans authentification sont refusees.

Cette politique ne cloisonne ni les chauffeurs ni les tablettes : chaque compte
authentifie peut acceder aux profils, courses, finances, conversations, jetons
et fichiers de tous les autres comptes. Les anciennes recommandations de
restriction par collection ci-dessous ne sont pas appliquees par ces regles.
Les controles des callables restent en place, mais peuvent etre contournes
par un acces direct aux donnees avec un compte authentifie.

Deploiement cible :
`firebase deploy --only firestore:rules,storage --project gestion-bmr`.

## Separation de l'application client

La carte des monuments et les ecrans clients ont ete transferes dans un projet
Flutter distinct. Ce projet conserve l'application chauffeur : authentification,
courses, suivi des statuts avec GPS, paiements et pancarte client.
L'accueil ouvre directement la connexion. Le mode tablette client et le bouton
de carte des courses sont retires.
Les anciennes preferences locales de mode tablette ne sont plus utilisees.

Les fonctions Firebase de sessions clients et les regles de la collection
`Clients` restent en place pour le projet client. Ce nettoyage ne supprime
aucune donnee ni fonction deployee.

## Conversation cote chauffeur

Le bouton flottant « Conversation client », en bas a droite des commandes,
ouvre la session active dans
`Clients/{uidDuChauffeur}.currentClient`. Un acces existe aussi sur une course
au statut « Client a bord » ; il n'affiche jamais le client d'une autre course.
Le nom, la langue et les 100 derniers messages de la session sont affiches en
temps reel. Sans session, aucun ancien client ni historique n'est affiche.

Le chauffeur repond en francais (500 caracteres maximum). L'envoi utilise
`sendClientSessionMessage`, avec un identifiant conserve lors d'une nouvelle
tentative pour eviter les doublons. En cas d'echec, le texte reste dans le champ
et une erreur est affichee. La traduction et la lecture de cette reponse doivent
etre gerees par l'application client.

Le bouton « Dicter une reponse » active la reconnaissance vocale francaise
du telephone apres confirmation : l'audio peut etre transmis a Google/Apple.
Le texte dicte complete le brouillon et reste modifiable avant un envoi manuel.
Les permissions et l'absence de langue francaise produisent une erreur visible,
sans bloquer la saisie au clavier. La dictee est annulee au changement de client,
en arriere-plan et a la fermeture. Les messages sont affiches en bulles :
chauffeur a droite et client a gauche, avec des couleurs distinctes.

Toutes les traductions sont calculees sur la tablette. Elle envoie l'original
du client et sa traduction francaise ensemble. Le telephone affiche cette
traduction et peut la lire avec sa voix francaise, sans modele ML Kit ni
calcul de traduction local. Les anciens messages sans traduction restent
explicitement en attente de la tablette. Les messages de l'historique et ceux
du chauffeur ne sont pas lus automatiquement ; « Lire » permet une lecture
manuelle.
La lecture s'arrete en arriere-plan ou au changement de session. Il n'y a pas de
notification de conversation en arriere-plan. Internet est necessaire pour
echanger via Firebase ; les erreurs de connexion sont affichees.

## Association durable des tablettes

Depuis les commandes, « Tablettes associees » permet de generer un code
de 10 caracteres, valable 5 minutes et utilisable une seule fois. Un nouveau
code remplace le precedent. Chaque tablette saisit ce code et son propre nom
dans l'application client. Plusieurs tablettes peuvent etre associees au meme
chauffeur et revoquees separement depuis cette page.

La tablette utilise une identite Firebase Authentication anonyme persistante,
pas le compte ni le mot de passe chauffeur. L'association serveur est stockee
dans `TabletLinks/{uidTablette}`. Elle survit aux changements de client, aux
redemarrages et aux coupures reseau. Effacer les donnees de l'application peut
perdre l'identite et necessiter une nouvelle association.

L'application utilise les callables, qui reverifient l'association lors de
chaque operation. Cependant, la politique d'acces globale ci-dessus permet
aux tablettes authentifiees d'acceder directement a toutes les donnees, y
compris les anciennes sessions. La revocation invalide l'association pour les
callables, mais ne retire pas les droits globaux d'un compte authentifie.
La fin de course vide les informations du client sans revoquer l'association.

Les collections de codes et de limitation des tentatives sont egalement
accessibles aux comptes authentifies selon cette politique.

Tests serveur et regles (Firebase CLI et Java necessaires) :
```powershell
firebase emulators:exec --only firestore --project demo-chauffeur --config firebase.clients.test.json "node --test functions/client_sessions.test.js functions/tablet_pairing.test.js"
```

## Logo Pro du Transport

Le logo fourni est conservé dans `assets/images/pro_du_transport.jpg` et utilisé
sur la page de connexion, la pancarte client et les bons de commande PDF.

## Authentification

- Email et mot de passe pour les comptes existants.
- « Créer un compte » permet de s'inscrire par email, avec confirmation du mot
  de passe (au moins 6 caractères). Le profil chauffeur est ensuite complété
  via le formulaire existant.
- En mode Email, « Mot de passe oublié ? » envoie un lien de réinitialisation.
  Le message de confirmation ne révèle pas si l'adresse possède un compte.
- Téléphone au format international (`+33…`), puis code SMS à 6 chiffres.
- La session Firebase est conservée et une déconnexion est disponible.
- La logique Firebase se trouve dans `lib/services/firebase/fireAuth.dart`.

Dans la console Firebase, activer **Authentication > Sign-in method > Email/Password**
et **Phone**. La configuration générale Firebase ne suffit pas à activer ces méthodes.
Personnaliser si nécessaire l'email de réinitialisation dans
**Authentication > Templates**. Ces parcours utilisent directement Firebase
Authentication et ne nécessitent pas de nouvelle Cloud Function.

La connexion SMS est disponible sur Android, iOS et web, pas sur Windows.
Configurer les empreintes SHA nécessaires pour Android, les notifications APNs et
la vérification d’application pour iOS, ainsi que les domaines autorisés pour le web.
Firebase peut demander une vérification reCAPTCHA. Les SMS réels peuvent nécessiter
une facturation et sont soumis aux quotas et aux règles de régions SMS du projet.
Utiliser les numéros de test de Firebase Authentication pour tester sans envoyer de SMS.

## Profil chauffeur

Depuis les commandes, le bouton « Mon profil » ouvre une page en lecture seule :
nom, téléphone, véhicule, plaque d'immatriculation, disponibilité et catégories
attribuées par l'administrateur.
Ces informations suivent en temps réel le document `Drivers/{uid}`.
La page est adaptée aux petits écrans, avec un avatar à initiales et des badges
de catégories. Les états de chargement, profil absent et erreur sont pris en charge.

Après connexion, l'application lit `Drivers/{uid}` avec l'UID Firebase Authentication.
Si ce document est absent, un formulaire demande le nom complet, le téléphone
international, le véhicule et la plaque d'immatriculation avant l'accès aux
commandes. La plaque est obligatoire, enregistrée sans espaces de début/fin et
en majuscules dans `Drivers/{uid}.licensePlate`. Aucun format national particulier
n'est imposé. Les anciens profils sans ce champ restent lisibles.
L'enregistrement utilise `MyDriver.toJson` : `name`, `phone`, `car`,
`licensePlate`, `available: true` et `categories: ['eco']`.
Les catégories ne sont pas saisies par le chauffeur dans le formulaire.
Une transaction préserve tout document déjà créé, notamment ses catégories et
ses champs administratifs. Une erreur de lecture ou d'écriture est affichée et
permet de réessayer.

Les règles Firestore déployées doivent autoriser la lecture de son propre profil
et la création de `Drivers/{request.auth.uid}` avec les champs du formulaire :
`name`, `phone`, `car`, `licensePlate` (chaînes non vides),
`available: true` et `categories: ['eco']`.
Interdire au client chauffeur de modifier `categories`, `remindersEnabled` ou les
données financières ; leur gestion reste réservée aux administrateurs/serveurs.
Créer un profil ne confère pas automatiquement une habilitation chauffeur.

## Vérification

```sh
flutter test test/authentication_test.dart test/commande_test.dart test/current_com_test.dart
```

## Commandes chauffeur

Les commandes sont présentées en cartes compactes : badge d'attribution,
date et trajet, véhicule/passagers/bagages regroupés, puis prix chauffeur.
Les actions de gestion et de téléchargement sont regroupées pour les commandes
du chauffeur. Les informations longues restent lisibles avec retour à la ligne.
Le rappel de paiement à bord est limité à une seule phrase dans la liste et
dans le suivi de la course, sans commentaire explicatif.

Chaque carte affiche uniquement « Prix chauffeur », soit **80 %** du prix
après déduction de la commission société de **20 %**, avant autres frais.
Le prix total et la commission ne sont pas affichés sur la carte. Le champ `price`
existant est un entier exprimé en euros (comme dans le bon de commande) ;
les parts sont calculées en centimes entiers pour éviter les imprécisions.
Un prix absent ou négatif est signalé sans inventer de rémunération.
Cette ventilation est informative : elle ne modifie ni le prix Firebase,
ni le solde comptable, ni les encaissements ou virements confirmés.

Lorsque `paymentPlan` vaut exactement `reservation_fee`, un avertissement
« paiement à bord » apparaît sur la carte et dans le suivi de la course.
Son texte est « Attention: paiement à bord sur cette course ».
La part chauffeur ne représente pas nécessairement la somme à encaisser et
le plan seul ne prouve pas qu'une somme reste impayée. Aucun encaissement n'est enregistré
automatiquement et aucun reste à payer n'est inventé.

Après connexion, `lib/screens/commande.dart` affiche uniquement les courses de
**Orders** dont le champ `category` correspond à une valeur complète de
`Drivers/{uid}.categories`, sans distinction entre majuscules et minuscules
(`VAN`, `Van` et `van` sont équivalents). Les changements de courses et de catégories attribuées
par l'administrateur sont reflétés en temps réel. Aucune course n'est affichée si
la liste des catégories est vide ; les courses sans catégorie sont exclues.
Ce filtre concerne aussi les courses déjà attribuées dans cette liste, mais ne
modifie pas le suivi individuel ni les calculs financiers des courses réalisées.
Une erreur de lecture du profil masque la liste et propose de réessayer.
Le filtrage d'affichage n'est pas une règle de sécurité : les règles Firestore
doivent également contrôler l'habilitation par catégorie lors de l'attribution.

Le bouton « Choisir cette commande » réserve le document
en ajoutant une entrée d’attribution dans `commandStatus` (`status: OrderStatus.ASSIGNED`,
`id: request.auth.uid`, `location`, `date`) ainsi que `commandStatusUpdatedAt` (horodatage
serveur). `commandStatus` ne doit contenir aucune attribution préalable pour qu’une commande
soit disponible ; une commande déjà attribuée n’est plus sélectionnable par un autre chauffeur.
Une transaction Firestore vérifie cette condition atomiquement avant l’écriture.

Les règles Firestore déployées doivent autoriser la lecture aux chauffeurs et
restreindre l’attribution aux comptes ayant réellement le rôle chauffeur. Pour
cette opération, elles doivent vérifier qu’aucun statut `ASSIGNED` n’existe déjà
dans `commandStatus`, que l’élément ajouté porte l’identifiant `request.auth.uid`
et la position GPS du chauffeur, et que `commandStatusUpdatedAt` vaut `request.time`.
Ne pas autoriser une réattribution d’un document déjà réservé. La transaction cliente ne
remplace pas ces règles de sécurité. Les règles ne sont pas présentes dans ce projet et
doivent être configurées/déployées dans votre environnement Firebase.

## Suivi de la commande

Le bouton « Gérer ma commande » ouvre `lib/screens/current_com.dart` pour une
commande attribuée au chauffeur. Le suivi est actualisé en temps réel :
**Attribuée → En route → Sur place → Client à bord → Terminée**.
Une confirmation précède chaque étape ; il n’est pas possible de sauter une étape,
de revenir en arrière ou de modifier une course terminée.

Chaque confirmation demande une position GPS actuelle (pas de suivi en arrière-plan).
Si la localisation est refusée, désactivée ou indisponible, le statut n’est pas enregistré.
La dépendance `geolocator` nécessite un redémarrage complet après installation.
Sur Windows, autoriser la localisation dans les paramètres de confidentialité ;
sur le web, utiliser HTTPS ou localhost et autoriser la localisation du navigateur.
Les permissions Android, iOS et macOS sont déclarées dans le projet.

Une transaction vérifie l’attribution au chauffeur dans `commandStatus` et le statut
attendu, puis ajoute une nouvelle entrée à `commandStatus` en conservant l’historique
existant. Le format est celui du modèle `CommandStatus` : `date` (ISO UTC), `status`
(`OrderStatus.EN_ROUTE`, etc.), `id` (UID chauffeur), `location` (`latitude` et `longitude`
numériques).
`commandStatusUpdatedAt` reçoit un horodatage serveur ; la date de l’entrée et le GPS
proviennent de l’appareil. Le champ simple `status` n’est pas modifié.
Une commande réservée sans historique démarre visuellement à « Attribuée » :
aucune ancienne position GPS n’est inventée. Un historique invalide est signalé
explicitement et ne peut pas être écrasé par une mise à jour.

Compléter les règles Firestore déployées pour ce parcours : seul le chauffeur
attribué doit pouvoir ajouter exactement une étape autorisée à l’historique,
sans modifier les entrées précédentes ni l’affectation ; limiter les champs
modifiables à `commandStatus` et `commandStatusUpdatedAt` et vérifier l’UID,
la forme de l’entrée GPS et l’horodatage serveur. Ces règles ne sont pas
déployées par l’application et doivent être intégrées aux règles de votre projet.

## Statistiques et finances chauffeur

L'icône « Mes statistiques » de la page des commandes ouvre
`lib/screens/statistique.dart`. La page affiche en temps réel les courses
attribuées au chauffeur connecté (UID issu de `commandStatus`), les courses
terminées, en cours et clôturées sans réalisation. Un historique invalide est
signalé et exclu des compteurs. Les statistiques couvrent toute la période.

Les encaissements et virements sont en **EUR** et doivent être alimentés
par votre back-office ou un backend de confiance. Ils ne sont pas déduits
du statut de paiement d'une commande. L'application chauffeur est en lecture
seule ; le solde restant dû est calculé à partir des courses et de ces paiements.

### Solde restant dû

La page calcule en temps réel le solde sur toute la période :
**80 % du prix des courses terminées attribuées au chauffeur − encaissements
à bord confirmés − virements reçus**. Les autres courses ne génèrent pas de
rémunération. Les calculs utilisent des centimes entiers. Un résultat négatif
est affiché comme montant à reverser à la société, sans être ramené à zéro.
Une erreur de lecture, un historique invalide ou un prix manquant/négatif
sur une course terminée bloque l'affichage du solde au lieu de produire un
total partiel. Selon la convention métier, une course terminée avec
`paymentPlan = reservation_fee` est considérée encaissée à bord pour
`price * 100 - checkoutAmountCents`. `checkoutAmountCents` est le montant
variable payé en ligne, en centimes entiers, entre zéro et le prix total.
S'il manque ou est invalide, le solde et le détail des paiements sont bloqués.
Les courses non terminées ne génèrent aucune déduction à bord.
Les documents `type = onboard` de la collection des paiements sont ignorés
pour éviter une double déduction ; cette collection sert uniquement aux virements.
Exemple : course de 100 EUR, 9 EUR payés en ligne, 91 EUR encaissés à bord :
80 EUR de gains - 91 EUR = -11 EUR à reverser, avant les virements.
Le backend doit conserver des courses et virements complets sur la même période.

Les sections dépliables « Détail du solde » et « Détail de mes courses »
affichent la ventilation gains/encaissements/virements/solde et les courses
du chauffeur (identifiant, date, trajet, statut, prix chauffeur à 80 %).
Chaque course indique si elle entre dans les gains : seules les courses
terminées sont incluses. Les montants détaillés suivent les mises à jour
en temps réel ; aucun paiement n'est rattaché à une course par supposition.

### Ancien solde comptable (non utilisé dans la page)

Document `Drivers/{uid}/finance/summary` :

```text
currency: "EUR"
balanceCents: 125050       // entier signé : 1 250,50 EUR
updatedAt: Timestamp      // date de mise à jour comptable
```

Ce document reste compatible avec le service, mais n'est plus lu par la page
de statistiques et n'est pas ajouté au solde calculé.

### Argent effectivement reçu

Un document par opération dans `Drivers/{uid}/payments/{paymentId}` :

```text
type: "transfer"           // virement effectivement reçu
currency: "EUR"
amountCents: 4500          // entier strictement positif : 45,00 EUR
receivedAt: Timestamp     // date de réception effective
reference: "COM-123"       // chaîne facultative : commande ou référence bancaire
```

Cette collection fournit **uniquement les virements réellement reçus**
au calcul, pas les virements prévus/en attente. Utiliser des
identifiants stables pour éviter les doublons. Le backend doit maintenir le
solde comptable et les opérations de manière cohérente. La page totalise
les encaissements issus des commandes et les virements séparément. Chaque
encaissement détaille le prix total, le montant payé en ligne et le reste à bord.
Les virements sont affichés du plus récent au plus ancien.
Une collection vide indique qu'aucun virement n'est enregistré, pas
qu'aucun paiement n'a eu lieu. Les erreurs de lecture ou de format sont affichées.

Avant utilisation, **déployer des règles Firestore** autorisant chaque chauffeur
authentifié et habilité à lire uniquement `Drivers/{request.auth.uid}/finance/*`
et `Drivers/{request.auth.uid}/payments/*`. Interdire toute écriture financière
depuis les clients chauffeur et toute lecture des finances d'un autre compte.
Réserver les écritures au backend de confiance (Admin SDK avec contrôle IAM).
Ces règles et l'alimentation du back-office ne sont pas déployées par cette app.

## Rappel chauffeur à H-1

Le backend `functions/` planifie un rappel pour chaque course attribuée et non
clôturée de `Orders`. Il lit `departureDate` (Timestamp ou ISO avec `Z`/décalage
horaire explicite ; les dates ISO sans fuseau doivent être migrées), l'attribution
dans `commandStatus` et `departureAddress`. Une fonction planifiée vérifie
les rappels toutes les minutes : l'envoi a lieu au plus tôt à H-1, avec un
décalage possible lié au planificateur et à la livraison push. Une attribution
tardive entre H-1 et le départ déclenche également un rappel.

Le chauffeur active les notifications depuis la page des commandes. Le rappel
FCM ouvre la course (application fermée ou en arrière-plan) ; au premier plan,
un bandeau « Ouvrir » est affiché. Entre H-1 inclus et le départ exclu, le bouton
« Confirmer ma disponibilité » propose le partage ponctuel de la position GPS.
Après consentement, `confirmDriverAvailability` vérifie le chauffeur attribué,
la génération du rappel et une position de moins de deux minutes. Aucun suivi
GPS en arrière-plan n'est ajouté.

Le serveur utilise Geocoding API pour résoudre l'adresse de départ puis Routes
API (`DRIVE`, `TRAFFIC_AWARE`) pour estimer le trajet au moment de la réponse.
Les coordonnées GPS et le départ sont transmis à Google Maps uniquement pour ce
calcul. Le secret `GOOGLE_MAPS_API_KEY` est lié à la callable, jamais au client.
Activer les deux API et leur facturation dans le projet Google Cloud.
Une adresse absente, ambiguë, introuvable, une erreur Google ou une course
réattribuée pendant le calcul ne valide pas la confirmation : un message permet
de corriger la course ou de réessayer.

Le serveur enregistre dans `DriverReminders/{orderId}` :

- `driverId`, `generation`, `dueAt`, `departureDate`, `state`;
- `sentAt` si FCM a accepté au moins un envoi (ce n'est pas une preuve de réception);
- `attempts`, `nextAttemptAt` et les informations de bail nécessaires aux tentatives.
- `followupVersion: 1` pour les nouveaux envois prenant en charge les relances ;
  `alarmSentAt`, `alarmDeliveredTokenIds`, `alarmNextAttemptAt`, `alarmLastError`
  suivent la livraison de la relance et `noResponseAlertId` identifie l'escalade.
- À la confirmation : `confirmedAt`, `position`, `positionCapturedAt`,
  `confirmationDepartureAddress`, `destination`, `durationSeconds`,
  `routeDistanceMeters`, `estimatedArrivalAt` et `provider: google_routes`.
  L'estimation avec trafic n'est pas une garantie d'arrivée.

Si `durationSeconds > 3600` (strictement ; 60 minutes exactement ne suffisent pas),
la transaction crée une alerte `DriverTravelAlerts/{alertId}` et enregistre son
identifiant `adminAlertId` dans le rappel. L'alerte contient `orderId`, `driverId`,
`generation`, la durée, la distance, le départ, l'heure de création et son état
de livraison. Une confirmation répétée ne crée pas une seconde alerte.

`sendDriverTravelAlert` notifie uniquement les appareils du compte administrateur
`YGE0x3Im8XUtmxWBtD740mszQ3B2`. Le compte doit avoir activé les notifications et
enregistré un appareil. Le push ne contient ni position GPS ni adresse client ;
son ouverture affiche les détails de l'alerte dans l'app. Le back-office peut
également lire la collection. En cas d'échec ou d'absence d'appareil, l'alerte
reste enregistrée avec `lastError` ; le planificateur réessaie jusqu'à cinq
tentatives espacées de cinq minutes puis marque `failed`. Les appareils déjà
notifiés ne sont pas renotifiés lors d'un échec partiel. `sent` signifie accepté
par FCM, pas lu par l'administrateur. Une réattribution ou annulation invalide
une alerte encore en attente.

Attention : la politique d'accès globale actuellement choisie permet à tout
compte authentifié, y compris anonyme, de lire et modifier ces documents et les
positions enregistrées. Les vérifications de la callable ne protègent pas contre
les écritures directes autorisées par ces règles. Les restrictions par collection
proposées plus bas sont des recommandations, pas la politique déployée.

Le back-office peut lire ces documents pour distinguer `pending`, `sent`,
`failed`, `unconfirmed` et `cancelled`. Les anciens documents `confirmed` restent
compatibles avec l'application. Les rappels envoyés passent à `unconfirmed`
au départ ; un échec d'envoi est journalisé,
réessayé jusqu'à cinq fois à cinq minutes d'intervalle, puis reste `failed`.
Pour les rappels envoyés après activation de cette version :

- Une minute après le premier envoi accepté par FCM (`sentAt`), sans confirmation
  enregistrée, le serveur demande une sonnerie persistante sur Android.
  Sur iPhone, il envoie une notification sonore standard, y compris au premier plan.
- Cinq minutes après `sentAt`, toujours sans confirmation, il crée une alerte
  `DriverTravelAlerts` de `kind: no_response` (sans durée ni GPS) et notifie
  l'administrateur. L'ouverture de cette alerte affiche « Chauffeur sans réponse ».
- Ouvrir le rappel ne compte pas comme une réponse. Seule la confirmation
  enregistrée après calcul du trajet arrête ce suivi. « Couper le son » dans
  la notification Android ou dans la course ne confirme rien : l'escalade
  des cinq minutes reste active.
- Une confirmation ou une annulation/réattribution arrête la sonnerie de cette
  génération ; les messages d'arrêt retardés ne coupent pas une autre course.
  La sonnerie expire au départ. Une alerte déjà envoyée reste un historique ;
  une confirmation arrivée avant son envoi annule l'alerte en attente.

Ces délais partent de l'acceptation FCM, pas de la réception sur le téléphone.
Le passage du planificateur chaque minute et le réseau peuvent retarder l'action.
Les anciens rappels ne déclenchent pas d'escalade rétroactive.
Les relances en échec sont journalisées et réessayées avant le départ ;
les appareils déjà atteints sont exclus des tentatives suivantes.

Android utilise un récepteur FCM natif et un service au premier plan de type
`mediaPlayback`, avec une notification persistante « Ouvrir » / « Couper le son ».
Il faut **reconstruire et réinstaller l'application**, puis se connecter avec
le compte chauffeur pour lier les alarmes à ce compte ; un hot reload ne suffit pas.
L'autorisation de notification et le canal sonore doivent être activés.
Le système peut refuser le service (restriction d'arrière-plan, priorité FCM
abaissée) ; une notification sonore de secours est alors utilisée et le refus
est journalisé. Le mode silencieux, Ne pas déranger, le volume, les restrictions
constructeur, l'arrêt forcé ou l'absence de réseau empêchent de garantir une
sonnerie. Aucune alarme ne doit être promise dans ces conditions. Le type de
service `mediaPlayback` doit être déclaré et justifié lors de la publication Play.

L'envoi des rappels et alertes est « au moins une fois » :
une interruption serveur après envoi peut entraîner un doublon. Une nouvelle date ou attribution
réinitialise le rappel.

## Notifications de nouvelles courses

À la création d'une course non attribuée dans `Orders`, le backend envoie une
notification push aux chauffeurs dont `Drivers/{uid}.available` vaut `true` et
dont `categories` contient la catégorie complète de la course, sans distinction
entre majuscules et minuscules. Par exemple, `['eco', 'VAN']` accepte une course
`van`, mais `['premium van']` ne l'accepte pas. Le serveur sélectionne les
chauffeurs disponibles puis compare les catégories en minuscules, car les
requêtes Firestore `array-contains` restent sensibles à la casse. Les valeurs
stockées et leurs libellés ne sont pas modifiés. Les courses
déjà attribuées, annulées ou terminées ne déclenchent pas ce push. Les
modifications ultérieures d'une course ne renvoient pas de notification.

Au premier plan, l'application affiche un bandeau « Voir » ; ouvrir la
notification affiche la liste des courses compatibles. Le message ne contient
pas d'adresse client. La collection serveur
`DriverCourseNotifications/{orderId}` conserve les destinataires et l'état de
chaque envoi afin d'éviter les doublons lors des retries Firestore. Comme pour
les rappels H-1, l'envoi FCM reste au moins une fois en cas d'interruption entre
l'acceptation par FCM et l'enregistrement de l'état.

Les deux types de notifications utilisent les jetons FCM de
`DriverPushTokens`. L'enregistrement d'un jeton nécessite un profil chauffeur ;
les rappels H-1 concernent les courses attribuées, sans filtre de catégorie,
de disponibilité générale ni d'ancien champ `remindersEnabled`.
Le bouton d'activation nécessite le déploiement de `registerDriverPushToken`
et `unregisterDriverPushToken` en `europe-west1`. Si le service manque ou si la
session a expiré, le bandeau indique la cause et l'action à effectuer.
Sur Android et iOS, l'autorisation est demandée automatiquement à l'ouverture
de l'espace chauffeur, après la saisie du profil. Si elle est déjà accordée,
l'appareil est enregistré sans nouvelle demande. Si le système bloque la
demande après un refus, les notifications doivent être autorisées dans les
réglages de l'appareil ; le bouton permet ensuite de réessayer.
Sur Android avant la version 13, aucune fenêtre d'autorisation n'est nécessaire.

### Bon de commande PDF

La pancarte client affiche également le logo Pro du Transport dans le coin inférieur droit,
dans une zone réservée pour ne pas recouvrir le nom.

Le bon comporte le logo Pro du Transport en en-tête et n'inclut pas le tableau d'historique
du suivi. Le tarif conserve le symbole euro grâce aux polices Noto Sans
embarquées (licence OFL dans `assets/fonts/OFL.txt`), sans téléchargement de
police à la génération, au partage ou à l'impression.

### Onglets des courses

Depuis la gestion d'une course attribuée, en route ou sur place, le chauffeur
peut confirmer « Remettre en attente ». Une transaction vérifie son attribution
et l'étape courante, conserve l'historique et ajoute une étape d'attente sans
chauffeur. Cette action est interdite dès que le client est à bord.
Les règles Firestore de production doivent autoriser cette transition uniquement
au chauffeur attribué et avant la prise en charge. Le backend des rappels doit
être redéployé après cette évolution pour ignorer les anciennes attributions
antérieures à une remise en attente.

L'écran Commandes sépare les courses disponibles des courses attribuées.
Les onglets filtrent le même flux autorisé pour le chauffeur sans élargir les
accès Firestore. L'onglet des courses attribuées affiche uniquement les commandes
attribuées au chauffeur connecté. Les courses des autres chauffeurs sont masquées
dans les deux onglets.
Une attribution réussie déplace immédiatement la carte vers cet onglet.
Chaque onglet possède son message vide et conserve l'actualisation manuelle.
Les cartes des courses disponibles masquent l'état et regroupent le prix
chauffeur (sans libellé, avec le symbole €), le véhicule renseigné ou à défaut
la catégorie, les passagers et les bagages sur une seule ligne,
défilante horizontalement sur les petits écrans.

### Suggestions de véhicules

Le formulaire de création du profil lit les noms dans `Cars` (champ `name`).
Les suggestions sont filtrées sans tenir compte de la casse et un appui remplit
le champ Véhicule. La saisie libre reste autorisée. Les chauffeurs authentifiés
doivent avoir la permission Firestore de lire cette collection ; aucune écriture
dans `Cars` n'est effectuée. Un échec de lecture est affiché avec une action
pour réessayer, sans bloquer la saisie manuelle.

### Catalogue des monuments historiques

`assets/data/monuments_ile_de_france.json` contient les notices Mérimée des huit
départements franciliens (75, 77, 78, 91, 92, 93, 94, 95), issues du jeu officiel
du ministère de la Culture sous Licence Ouverte 2.0. Le périmètre officiel inclut
les immeubles qui ont été ou sont protégés, pas tous les lieux touristiques.
Chaque notice conserve sa référence, son nom, sa description, son historique,
ses coordonnées WGS84, son adresse et sa provenance. Un champ absent reste `null`.
Le catalogue est déclaré comme asset Flutter et embarqué dans l'application :
aucune notice ni métadonnée photo n'est stockée dans Firebase. Les données
textuelles embarquées sont accessibles hors ligne ; les images restent en ligne.
Les modifications du catalogue sont incluses lors d'une nouvelle compilation
de l'application, sans synchronisation automatique avec un serveur.

Les photos sont des liens Wikimedia Commons, et non des images téléchargées.
La recherche utilise la référence Mérimée pour limiter les homonymes et conserve
au maximum trois images JPEG/PNG/WebP sous licence libre vérifiée. Chaque photo
indique son auteur, sa licence et sa page source : respecter les obligations
d'attribution et de partage à l'identique le cas échéant. Les métadonnées
`auteur_html` et `credit_html` sont du HTML externe, à assainir avant affichage.
Le champ `photos_statut` distingue une recherche encore à faire, une erreur,
un résultat complet et une disponibilité inférieure à trois images.
Trois photos libres ne sont pas garanties pour chaque édifice.

Pour régénérer les notices puis rechercher les photos (opération longue,
sauvegardée toutes les 25 notices) :

```powershell
node tools\export_monuments.mjs
```

Les recherches sont espacées de cinq secondes. En cas de limitation HTTP,
le script respecte le délai `Retry-After` du fournisseur s'il est présent,
avec une attente minimale progressive de 30 secondes.

Pour reprendre les recherches non effectuées ou en erreur sans retélécharger
les notices et sans refaire les recherches terminées :

```powershell
node tools\export_monuments.mjs --resume
```

Pour exporter uniquement les notices : `node tools\export_monuments.mjs --catalog-only`.
Ces commandes ne nécessitent ni dépendance supplémentaire ni clé API.

### Carte du trajet

Le bouton « Afficher la carte » ouvre une page dont la carte occupe toute la
surface disponible sous la barre de navigation. Les boutons flottants permettent
de recentrer sur la dernière position GPS, de cadrer tout l'itinéraire et de
choisir une vue Standard (OpenStreetMap), Claire ou Sombre (CARTO).
Le changement de fond conserve le cadrage, les marqueurs et le tracé.
Les monuments disposant de coordonnées dans le catalogue embarqué apparaissent
avec une icône de bâtiment. Un appui ouvre leurs informations locales ; les
notices sans position ne sont pas placées arbitrairement sur la carte.
La fiche affiche les photos disponibles dans un carrousel horizontal avec
compteur, auteur, licence et URL de la page source. Les images sont chargées
depuis Internet uniquement à l'ouverture de la fiche ; leur absence ou une
erreur réseau est signalée sans empêcher la lecture des informations locales.
Les étapes restent accessibles dans un panneau via « Étapes du trajet ».
Ces fonds nécessitent Internet et sont soumis aux conditions d'utilisation de
leurs fournisseurs ; aucune clé Geocoding Google n'est utilisée pour les tuiles.

### Configuration et déploiement obligatoires

Le code local ne déploie pas automatiquement les services et ne modifie pas les
règles de votre Firebase existant. Avant utilisation en production :

1. Utiliser un projet Firebase avec facturation Blaze pour Functions, Scheduler
   et Secret Manager. Les fonctions sont en `europe-west1`, avec Node.js 22.
2. Pour les rappels H-1, chaque chauffeur attribué doit posséder un profil
   et un appareil enregistré. Les notifications de nouvelles courses utilisent
   `available` et `categories` du profil. Pour le calcul du trajet, activer
   Geocoding API et Routes API et enregistrer le secret sans le committer :
   `firebase functions:secrets:set GOOGLE_MAPS_API_KEY --project gestion-bmr`.
   Déploiement ciblé du parcours H-1 :
   `firebase deploy --only functions:chauffeur-reminders:confirmDriverAvailability,functions:chauffeur-reminders:sendDriverTravelAlert,functions:chauffeur-reminders:stopDriverReminderAlarm,functions:chauffeur-reminders:syncDriverReminder,functions:chauffeur-reminders:sendDriverReminders --project gestion-bmr`.
3. **Fusionner** les règles ci-dessous dans vos règles existantes (ne pas remplacer
   les règles des commandes/finances). Ne conserver aucune règle large autorisant
   l'accès à tous les documents, car les autorisations Firestore sont additives.

```text
match /DriverReminders/{orderId} {
  allow get: if request.auth != null
    && (!exists(/databases/$(database)/documents/DriverReminders/$(orderId))
        || resource.data.driverId == request.auth.uid);
  allow list: if request.auth != null
    && resource.data.driverId == request.auth.uid;
  allow write: if false;
}
match /DriverPushTokens/{tokenId} {
  allow read, write: if false;
}
match /DriverTravelAlerts/{alertId} {
  allow read: if request.auth != null
    && request.auth.uid == 'YGE0x3Im8XUtmxWBtD740mszQ3B2';
  allow write: if false;
}
match /DriverCourseNotifications/{orderId} {
  allow read, write: if false;
}
match /DriverCourseNotifications/{orderId}/deliveries/{driverId} {
  allow read, write: if false;
}
```

4. Fusionner les deux index de `functions/firestore.indexes.json` avec les index
   existants du projet **avant** `firebase deploy --only firestore:indexes`.
   Déployer ensuite `firebase deploy --only functions:chauffeur-reminders`.
   Lancer les commandes avec le projet Firebase voulu (`--project ...`).
5. Pour les commandes déjà créées avant ce déploiement, utiliser une identité
   Admin SDK de confiance et exécuter `node functions/backfill_reminders.js`
   (lecture seule), puis `node functions/backfill_reminders.js --write` après
   vérification. Le script initialise les rappels absents, sans écraser les existants.
6. Android : autoriser les notifications (Android 13+) et garder la configuration
   Firebase Android. iOS : activer la capability Push Notifications dans Xcode,
   configurer la clé APNs dans Firebase Cloud Messaging et signer pour un appareil
   réel. Cette configuration ne peut pas être réalisée depuis Windows.
7. Faire un **redémarrage complet/rebuild** de l'application après ajout des plugins.
   Le push de ce parcours est pris en charge sur Android/iOS seulement ; sur les
   autres plateformes, aucun push n'est envoyé.

Les jetons sont enregistrés par callable dans `DriverPushTokens`, transférés au
compte actuel lors de l'enregistrement et retirés avant la déconnexion depuis
l'app. Les messages ne contiennent ni adresse client ni coordonnées GPS. Prévoir
une politique de rétention pour les positions et les anciens jetons.

### Vérification du rappel

```text
flutter test test/driver_reminder_test.dart test/driver_travel_alert_page_test.dart test/driver_notification_session_test.dart test/current_com_test.dart
cd functions
npm ci
npm test
npm run check
```

Les tests de transactions serveur peuvent être exécutés sans services réels :

```text
firebase emulators:exec --only firestore --project demo-chauffeur --config functions/firebase.test.json "node --test functions/google_routes.test.js functions/availability_integration.test.js functions/course_notifications.test.js functions/reminder_logic.test.js functions/reminder_integration.test.js functions/reminder_followups.test.js functions/followups_integration.test.js"
```

Ces tests utilisent Firestore local ; FCM est simulé. Ils vérifient l'envoi
des rappels H-1, la réattribution, l'expiration, ainsi que les destinataires
et l'idempotence des notifications de nouvelles courses.
Ils vérifient aussi les seuils exacts 60/300 secondes, l'absence de relance après
confirmation, l'alerte sans réponse, l'arrêt ciblé et les reprises partielles FCM.

La validation réelle nécessite un appareil, les fonctions/règles/index déployés,
APNs si iOS. Créer une course de test attribuée démarrant dans moins d'une heure ;
vérifier le push au premier plan, en arrière-plan et après fermeture normale de l'app.
Attendre les relances sans confirmer, couper le son et vérifier que l'escalade
reste active ; refaire un essai avec confirmation avant une minute et avant cinq
minutes pour vérifier leur suppression. Tester ensuite le changement de compte,
la réattribution et le départ, sans laisser d'alarme active.
Les notifications ne sont pas garanties si l'utilisateur force l'arrêt de
l'app, coupe le réseau ou désactive les notifications. Aucun envoi réel ou
accès à un fournisseur de géocodage n'est exécuté par les tests unitaires.
#   c h a u f f e u r _ p d t  
 