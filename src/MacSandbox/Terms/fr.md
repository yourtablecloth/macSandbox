# Conditions d'utilisation — macSandbox for Windows

**Version 1.0** · En vigueur le 2026-06-13

## À lire avant d'utiliser ce logiciel

**Lisez l'intégralité des présentes Conditions avant de créer une Base Image ou
d'exécuter le Logiciel, et décidez sur cette base si vous souhaitez l'utiliser.**
L'utilisation du Logiciel est volontaire et relève entièrement de votre décision.

Vous êtes seul responsable du respect des conditions de licence de tout système
d'exploitation invité que vous exécutez. Une violation de licence est une affaire
entre vous et le fournisseur du système d'exploitation et peut — selon la nature et
l'ampleur de la violation — vous exposer à des coûts financiers et à une
responsabilité civile et, en cas de contrefaçon intentionnelle ou à l'échelle
commerciale, potentiellement à une responsabilité pénale. L'Auteur n'assume, ne
partage ni n'atténue aucun de ces risques en votre nom. **Si vous n'êtes pas prêt à
assumer la responsabilité de votre propre licence, n'utilisez pas le Logiciel.**

---

## En un coup d'œil

> Ce résumé est fourni pour attirer votre attention sur des clauses essentielles.
> **Il ne fait pas partie de l'accord contraignant et ne remplace pas les
> Conditions complètes ci-dessous. En cas de contradiction entre ce résumé et le
> texte intégral, les Conditions complètes prévalent.**

- **Le Logiciel n'inclut pas Windows.** Aucun système d'exploitation, clé de
  produit ni activation n'est fourni ; vous devez fournir votre propre support
  d'installation de Windows. *(Section 3)*
- **La licence Windows relève de votre responsabilité, y compris votre scénario.**
  Vous devez détenir une licence valide pour chaque instance de Windows que vous
  exécutez, et la licence *appropriée* dépend de votre usage : l'accès depuis un
  Mac, le VDA, Windows 365 / Cloud PC ainsi qu'un usage commercial, en entreprise ou
  sur des réseaux partagés ont chacun leurs propres exigences. L'état d'activation —
  activé, non activé ou avec filigrane — ne **remplace pas** une licence.
  *(Section 4)*
- **Utilisez-le à des fins licites.** Le développement, les tests, la recherche en
  sécurité et l'évaluation sont les usages prévus. Le projet ne soutient ni ne
  tolère **pas** le contournement de l'activation ou de la licence d'un système
  d'exploitation. *(Sections 5–6)*
- **Logiciel expérimental, fourni « EN L'ÉTAT », avec responsabilité limitée.** Le
  Logiciel est expérimental et supprime l'état du bac à sable à la fin d'une
  session : attendez-vous à une perte de données et conservez vos propres
  sauvegardes. Il n'y a aucune garantie ; la responsabilité de l'Auteur est
  limitée ; et vous acceptez de prendre en charge les réclamations découlant de
  votre propre usage ou de votre licence Windows. *(Sections 9–11)*
- **La licence du code est distincte.** Le Logiciel est concédé sous licence
  AGPL-3.0-or-later ou sous licence commerciale. Les présentes Conditions régissent
  votre *usage* et ne **vous privent pas** des libertés accordées par cette licence.
  *(Section 1)*
- **Projet indépendant.** Non affilié à Microsoft ni approuvé par celle-ci.
  *(Section 8)*

---

## Section 1 (À propos des présentes Conditions)

Les présentes Conditions d'utilisation (les « **Conditions** ») régissent votre
utilisation de l'application **macSandbox for Windows** ainsi que des outils et de
la documentation associés (le « **Logiciel** »), mis à disposition par Nam Jung
Hyun (rkttu) (l'« **Auteur** »).

Les présentes Conditions sont **distinctes de la licence du Logiciel et s'y
ajoutent** :

- Le **code source** du Logiciel est concédé sous licence **GNU AGPL-3.0-or-later**
  (édition open source) ou sous **licence commerciale**, comme décrit dans
  `LICENSE`, `COMMERCIAL-LICENSE.md` et `LICENSING.md`.
- Les présentes Conditions régissent **votre comportement lors de l'utilisation du
  Logiciel** et la **répartition des responsabilités** entre vous et l'Auteur, en
  particulier en ce qui concerne la licence des systèmes d'exploitation de tiers.

Si une disposition des présentes Conditions entre en conflit avec les droits qui
vous sont accordés au titre de l'AGPL-3.0-or-later pour l'édition open source, **la
licence prévaut et la disposition en conflit ne s'applique pas à l'édition open
source.** Rien dans les présentes Conditions n'entend restreindre les libertés
accordées par cette licence.

En installant le Logiciel, en créant une Base Image avec celui-ci, en l'exécutant
ou en l'utilisant de toute autre manière, **vous reconnaissez avoir lu, compris et
accepté les présentes Conditions.** Si vous n'êtes pas d'accord, n'utilisez pas le
Logiciel.

## Section 2 (Définitions)

- « **Logiciel** » — l'application macSandbox for Windows, ses outils de
  compilation, ses scripts et sa documentation, à l'exclusion des composants tiers
  fournis avec ou liés à celle-ci.
- « **SE invité** » — tout système d'exploitation que vous choisissez d'exécuter au
  sein du Logiciel, y compris Microsoft Windows.
- « **Base Image** » — une image de disque virtuel Windows que vous créez à l'aide
  du Logiciel à partir d'un support d'installation de Windows que **vous**
  fournissez.
- « **Vous** » — la personne physique ou morale qui utilise le Logiciel.

## Section 3 (Aucun système d'exploitation n'est inclus)

**Le Logiciel n'inclut, ne distribue ni ne fournit aucun système d'exploitation,
clé de produit, activation, licence ou droit d'utilisation.** En particulier :

- Le Logiciel **ne contient aucune copie de Microsoft Windows**, ni clé de produit
  Windows, ni mécanisme d'activation.
- Pour créer une Base Image, **vous devez fournir votre propre support
  d'installation de Windows (par exemple, une ISO Windows 11 ARM64 obtenue auprès
  des canaux officiels de Microsoft).**
- Le Logiciel n'active pas Windows, n'aide pas à activer Windows et ne contourne,
  n'émule ni n'altère aucun mécanisme d'activation ou de licence de Windows.

## Section 4 (Votre responsabilité concernant la licence du SE invité)

**Vous êtes seul responsable de détenir une licence valide pour chaque instance de
SE invité que vous exécutez et de respecter toutes les conditions de licence
applicables de ce SE invité.** En particulier :

- Vous devez détenir une licence Microsoft valide et adaptée à chaque instance de
  Windows que vous créez, exécutez ou conservez à l'aide du Logiciel.
- **L'état d'activation ne remplace pas une licence.** Le fait qu'une instance de
  Windows soit activée, non activée ou affiche un filigrane d'évaluation n'établit
  pas à lui seul que vous disposez d'une licence en bonne et due forme. Les
  conditions de Microsoft lient l'autorisation à la détention d'une licence valide,
  et non à l'état d'activation.
- Avant chaque création d'une Base Image, le Logiciel affiche une liste de contrôle
  de licence. **Votre confirmation de cette liste constitue une déclaration selon
  laquelle vous avez satisfait à chaque point.** L'Auteur ne vérifie pas, et ne peut
  pas vérifier, votre situation de licence.

Votre obligation s'étend aux **droits propres à chaque scénario.** Le type de
licence requis pour une instance de Windows dépend de *la manière dont, du lieu où
et de la personne par laquelle* elle est utilisée, et il vous incombe de confirmer
que votre droit couvre effectivement votre scénario précis, y compris, sans s'y
limiter :

- **Accès depuis un appareil non Windows.** Le Logiciel s'exécute sous macOS, de
  sorte que vous accédez à une instance de Windows depuis un appareil non Windows.
  Ce scénario requiert généralement, selon votre programme de licences, des droits
  de virtualisation par utilisateur (par exemple Windows Enterprise E3/E5 ou
  Microsoft 365 E3/E5) ou un abonnement **Windows Virtual Desktop Access (VDA)**.
- **Windows 365 / Cloud PC et abonnements similaires.** Un abonnement tel que
  Windows 365 concède une licence pour un Cloud PC hébergé par Microsoft. **Ne
  présumez pas qu'il concède une licence pour une Base Image que vous créez et
  exécutez localement** avec le Logiciel ; une machine virtuelle exécutée localement
  est régie par les droits de virtualisation de votre licence Windows ou Microsoft
  365 sous-jacente, et non par un abonnement Cloud PC hébergé.
- **Usage commercial, organisationnel et sur réseaux partagés.** Un usage hors d'un
  contexte personnel — par exemple sur un réseau public, d'entreprise,
  professionnel, éducatif ou autre réseau partagé, ou pour donner accès à d'autres
  personnes — peut être régi par les conditions de licences en volume et peut
  requérir des droits différents ou supplémentaires (par exemple VDA, plans
  Microsoft 365 éligibles ou CAL Services Bureau à distance). Les licences Windows
  grand public ou OEM ne suffisent généralement pas pour un tel usage.

**Vous êtes seul responsable de toute violation de licence découlant de ces
scénarios ou d'autres, que vous ayez ou non eu connaissance des exigences
applicables.** Les exemples ci-dessus sont illustratifs et non exhaustifs, et les
conditions de licence de Microsoft peuvent évoluer ; vous devez consulter les
Conditions du produit (Product Terms) et les indications de licence en vigueur de
Microsoft, ou un spécialiste des licences, pour votre propre situation.

L'Auteur ne déclare pas qu'un usage particulier d'un SE invité est autorisé par le
fournisseur de ce système d'exploitation. **Déterminer et maintenir votre propre
conformité relève de votre responsabilité.**

## Section 5 (Usages autorisés)

Le Logiciel est un outil de virtualisation à usage général destiné à des fins
licites, y compris, sans s'y limiter : le développement et les tests de logiciels ;
la recherche en sécurité et l'analyse de logiciels malveillants dans un
environnement isolé ; l'évaluation de systèmes d'exploitation et d'applications ;
les tests d'accessibilité et de compatibilité ; les flux de travail d'intégration
continue (CI) et d'automatisation ; et l'expérimentation personnelle.

## Section 6 (Usage acceptable et absence d'approbation)

L'Auteur **n'**autorise, n'approuve ni ne tolère l'utilisation du Logiciel pour
porter atteinte aux droits de tiers. Sans limiter les libertés accordées par la
licence applicable du Logiciel, vous comprenez que le projet ne fournit pas de prise
en charge — et vous n'affirmerez pas que l'Auteur ou le projet l'approuve — pour :

- contourner, désactiver, émuler ou altérer l'activation, la licence ou les mesures
  techniques de protection de tout SE invité ou autre logiciel ;
- regrouper, intégrer ou distribuer — avec le Logiciel ou en tant que complément à
  celui-ci — tout outil dont l'objet est de contourner l'activation ou la licence
  d'un système d'exploitation (par exemple des générateurs de clés ou des serveurs
  d'activation non autorisés) ; ou
- utiliser le Logiciel pour faciliter la reproduction ou la distribution non
  autorisée du logiciel d'un tiers.

Les demandes d'ajout de telles fonctionnalités seront refusées. La présente Section
exprime la position de l'Auteur et l'étendue de la prise en charge du projet ; pour
l'édition open source, elle n'agit pas comme une restriction contractuelle des
libertés de la licence.

## Section 7 (Composants tiers)

Le Logiciel exécute et lie des composants tiers (par exemple QEMU, le micrologiciel
EDK2 et FreeRDP/WinPR), chacun fourni sous sa propre licence. Ces licences sont
décrites dans `LICENSING.md`, `THIRD-PARTY-NOTICES.md` et `WRITTEN-OFFER.txt`, et
votre utilisation de ces composants est régie par leurs conditions respectives.

## Section 8 (Absence d'affiliation ; marques)

macSandbox for Windows est un **projet indépendant** et **n'est ni affilié à
Microsoft Corporation, ni parrainé ou approuvé par celle-ci.** Microsoft, Windows
et les marques associées sont des marques du groupe de sociétés Microsoft. Toutes
les autres marques appartiennent à leurs titulaires respectifs. Les références à
ces marques sont nominatives et à des fins d'identification uniquement.

## Section 9 (Logiciel expérimental ; exclusion de garanties)

Le Logiciel est fourni à titre **expérimental et de préversion** à des fins de
développement, de test et d'évaluation. Il peut être incomplet ou instable, peut
être modifié ou interrompu à tout moment et peut se comporter de manière
imprévisible. **De par sa conception, le Logiciel supprime l'état du bac à sable à
la fin d'une session ; vous devez donc vous attendre à une perte de données. Ne
conservez dans le Logiciel rien dont vous ne pourriez pas supporter la perte, et
sauvegardez vos données de manière indépendante.** Vous êtes seul responsable de
toute perte ou altération de données, de configuration ou de travail, ainsi que de
toute autre conséquence découlant de votre utilisation du Logiciel.

**Le Logiciel est fourni « EN L'ÉTAT » et « SELON DISPONIBILITÉ », sans garantie
d'aucune sorte**, qu'elle soit expresse, implicite, légale ou autre, y compris,
sans s'y limiter, toute garantie implicite de qualité marchande, d'adéquation à un
usage particulier, de titre et d'absence de contrefaçon. L'Auteur ne garantit pas
que le Logiciel sera ininterrompu, exempt d'erreurs ou sécurisé. **Vous utilisez le
Logiciel à vos propres risques.**

## Section 10 (Limitation de responsabilité)

Dans toute la mesure permise par le droit applicable, **l'Auteur ne saurait être
tenu responsable des dommages indirects, accessoires, spéciaux, consécutifs ou
punitifs, ni de toute perte de bénéfices, de données ou de clientèle, ni des
réclamations de tiers (y compris celles découlant de votre licence du SE invité ou
de votre utilisation d'un SE invité) découlant du Logiciel ou des présentes
Conditions ou s'y rapportant**, quel que soit le fondement de la responsabilité et
même s'il a été informé de la possibilité de tels dommages.

Dans toute la mesure permise par le droit applicable, la responsabilité cumulée
totale de l'Auteur découlant du Logiciel ou des présentes Conditions, ou s'y
rapportant, n'excédera pas le montant que vous avez payé à l'Auteur, le cas
échéant, pour le Logiciel au cours des douze mois précédant le fait générateur de
la réclamation — ce qui, pour l'édition open source obtenue gratuitement, est nul.
La responsabilité qui ne peut être exclue ou limitée en vertu du droit applicable
n'est pas affectée par la présente Section.

## Section 11 (Indemnisation)

Dans toute la mesure permise par le droit applicable, **vous acceptez d'indemniser
et de dégager l'Auteur de toute responsabilité à l'égard de toute réclamation,
demande, perte ou dépense (y compris les frais d'avocat raisonnables) découlant de
(a) votre utilisation du Logiciel, (b) votre licence du SE invité ou votre
violation des conditions de licence d'un SE invité, ou (c) votre violation des
présentes Conditions ou de toute loi applicable ou de tout droit d'un tiers.**

## Section 12 (Modifications des présentes Conditions)

L'Auteur peut réviser les présentes Conditions. **Chaque révision est publiée avec
un numéro de version incrémenté et une date d'entrée en vigueur.** Lorsqu'une
version substantiellement révisée est publiée, le Logiciel peut exiger que vous
examiniez et acceptiez de nouveau les Conditions en vigueur avant toute utilisation
ultérieure. **Votre utilisation continue du Logiciel après l'entrée en vigueur
d'une révision vaut acceptation des Conditions révisées.** Les versions antérieures
restent identifiées par leur numéro de version à des fins d'archivage.

## Section 13 (Versions linguistiques, droit applicable et litiges)

Les présentes Conditions sont publiées en versions anglaise, coréenne et japonaise,
et sont également disponibles sous forme de traductions de courtoisie dans d'autres
langues, y compris la présente traduction française. Pour les utilisateurs situés en
République de Corée, la version coréenne s'applique ; pour les utilisateurs situés
au Japon, la version japonaise s'applique ; pour tous les autres utilisateurs, la
version anglaise s'applique et est régie par le droit de la République de Corée.

La présente traduction française est fournie uniquement pour votre commodité. Elle
ne constitue pas une version faisant foi autonome : la version anglaise et le droit
de la République de Corée s'appliquent, et **en cas de divergence entre la présente
traduction et la version anglaise, la version anglaise prévaut.** Le Seoul Central
District Court (tribunal du district central de Séoul) aura compétence exclusive en
tant que juridiction de première instance, sauf lorsque le droit impératif de la
protection des consommateurs de votre lieu de résidence vous accorde le droit
d'engager une procédure devant un autre for, ou exige l'application du droit d'un
autre for.

## Section 14 (Divisibilité)

Si une disposition des présentes Conditions est jugée inapplicable, cette
disposition sera limitée ou retranchée dans la mesure minimale nécessaire, et les
dispositions restantes demeureront pleinement en vigueur.

## Section 15 (Contact)

Les rapports de bogues et les demandes de fonctionnalités ne sont acceptés que via
le suivi des problèmes (GitHub Issues) du projet :
<https://github.com/yourtablecloth/macSandbox/issues>. Il n'existe pas de canal de
support par e-mail.

---

© 2026 Nam Jung Hyun (rkttu). macSandbox for Windows est un projet indépendant et
n'est pas affilié à Microsoft.
