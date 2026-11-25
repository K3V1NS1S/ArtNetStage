# ArtNet Stage 2.3 — nodo Art-Net virtuale + visualizzatore 3D per macOS

App nativa **macOS 13+** (Swift 5.9, SwiftUI MVVM, SceneKit, BSD sockets) che si comporta come una centralina Art-Net
collegata al Mac e mostra in tempo reale, in 3D, ciò che QLab, QLC+, Lightkey & co. inviano.

> **Nota onesta:** il codice è stato scritto senza poterlo compilare in Xcode (ambiente senza macOS).
> Se Xcode segnala errori o warning bloccanti al primo build, incollali nella chat e li correggo.

## Architettura

```
ArtNetStage/
├── ArtNetStageApp.swift        @main, finestra e iniezione degli environment object
├── AppViewModel.swift          coordinatore MVVM: server ↔ patch ↔ scena 3D ↔ palco/oggetti/scene salvate
├── ContentView.swift           UI: scena 3D a tutta finestra + pannello in vetro a sezioni (Rete/Catena/Luci/Palco/DMX), pillola viste, luminosità
├── ArtNetStage.entitlements    App Sandbox DISABILITATO
├── Models/
│   ├── FixtureModels.swift     FixtureProfile, ChannelRole, ColorWheelSlot, PixelConfig, PatchedFixture
│   ├── FixturePresets.swift    3 preset: PAR RGBW 8ch · Moving Head Beam 12ch · Barra LED 10 pixel
│   ├── PatchManager.swift      libreria JSON, patch/daisy-chain, auto-patch, conflitti, ancoraggio alle americane
│   ├── StageModels.swift       StageConfig (con colore americane), StageObject, CameraSnapshot
│   ├── SceneModel.swift        palco + oggetti 3D + selezione condivisa (selectedEntityID)
│   └── ProjectFile.swift       formato del file .artnetstage, versione app (AppInfo)
├── Network/
│   ├── ArtNetServer.swift      socket UDP 6454 (SO_REUSEADDR + SO_REUSEPORT), ArtPoll/ArtPollReply, ArtDmx, statistiche
│   ├── ArtNetPackets.swift     parsing ArtDmx/ArtPoll, costruzione ArtPollReply (239 byte)
│   ├── DMXStore.swift          buffer DMX thread-safe per Port-Address a 15 bit
│   └── NetworkInterfaces.swift getifaddrs + SystemConfiguration, alias IP via osascript/ifconfig
├── Stage/
│   ├── StageScene.swift        rig camera pivot→pitch→camera, palco dinamico, hitTest, loop a 60 fps
│   ├── FixtureRenderer.swift   coni additivi, SCNLight spot, pan/tilt, modalità colore (ruota/RGB/RGBW), strobo in Hz, gobo, prisma, pixel
│   ├── StageObjectRenderer.swift parallelepipedi e manichini (materiale blinn, castsShadow)
│   ├── GoboMask.swift          maschere gobo (PNG incorporati): immagine per SCNLight.gobo, macchia a terra, fascio di raggi; importatore JPG/PNG
│   ├── SceneHelpers.swift      linee, contorno di selezione, materiali
│   └── StageSceneView.swift    NSViewRepresentable + mouse/trackpad (orbita, pan, zoom, click per selezionare)
└── Views/
    ├── NetworkPanelView.swift  interfacce, IP, Net/SubNet, alias IP
    ├── PatchView.swift         patch, cavi daisy-chain, conflitti, mappa universi, posizione 3D
    ├── FixtureBuilderView.swift editor profili, mappatura canali, pixel, import/export JSON
    ├── FixtureOpticsEditors.swift modalità colore, strobo (Hz), gobo con NSOpenPanel, prisma radiale
    ├── StagePanelView.swift    dimensioni palco/americane, oggetti 3D, elenco unico degli elementi in scena
    └── DMXMonitorView.swift    sniffer: Hz, universi attivi, griglia live 1–512
```

## Vista 3D, palco e oggetti

* **Camera:** rig personalizzato `pivot (yaw, Y) → pitch (X) → camera (zoom)`, senza `allowsCameraControl`, quindi niente rollio e palco sempre in basso.
  Il nodo pitch è limitato a ±85° (`StageController.pitchLimit`); finché `allowCameraBelowStage = false` la camera non scende sotto il piano del palco.
* **Controlli:** trascina col tasto sinistro = orbita · tasto destro o ⇧/⌥ + trascina = pan sul piano del palco · rotellina, scroll a due dita o pizzico = zoom · click = seleziona · doppio click = vista 3/4.
* **Viste:** Frontale, Laterale, Superiore (pitch 85°), 3/4, animate con `SCNTransaction` (0,9 s).
* **Palco:** larghezza, profondità, altezza della base, altezza delle americane e «Mostra americane» si applicano in tempo reale. La Y delle luci è misurata dal piano del palco:
  le luci a terra seguono la base, quelle su americana restano agganciate quando cambi altezza o profondità.
* **Oggetti 3D:** parallelepipedi e manichini con posizione (X, Y, Z), dimensioni, rotazione e colore. Materiale `.blinn` e `castsShadow = true`: i fasci (una `SCNLight` spot per fixture) li illuminano e proiettano ombra.
  «Ombre dei fasci» nel pannello Palco si può disattivare se la scena rallenta con molte luci.
* **Selezione:** un solo stato, `SceneModel.selectedEntityID`, condiviso da elenchi e vista 3D. Click su una fixture o un oggetto nella scena = selezione, riga evidenziata nell'elenco e pannello giusto aperto;
  selezionando dall'elenco, l'elemento viene evidenziato nella scena con un contorno ciano.
* **Colore delle americane:** `ColorPicker` nel pannello Palco (con scorciatoie Nero / Alluminio). Aggiorna in tempo reale il materiale di tutta la struttura e viene salvato con la scena.

## Scene come file `.artnetstage`

Le scene non sono più preset interni: si salvano e si aprono come file veri sul Mac, con i pannelli nativi di macOS.

| Azione | Menu File | Scorciatoia | Toolbar |
|---|---|---|---|
| Apri scena… | File ▸ Apri scena… | ⌘O | cartella |
| Salva scena | File ▸ Salva scena | ⌘S | freccia in giù |
| Salva con nome… | File ▸ Salva con nome… | ⇧⌘S | freccia in giù con quadrato |

* Il primo ⌘S su una scena nuova apre «Salva con nome». Il titolo della finestra mostra il nome del file e «modificato» se ci sono modifiche non salvate; aprendo un altro file l'app chiede se salvare.
* Il file è JSON leggibile e contiene: dimensioni di palco e americane **e colore**, tutte le fixture patchate (profilo, universo, indirizzo e canali DMX, posizione, montaggio), la libreria fixture,
  tutti gli oggetti 3D (parallelepipedi e manichini con posizione, dimensioni, rotazione, colore), Net/SubNet e nome del nodo Art-Net, inquadratura della camera.
* Aprendo un file, la libreria fixture dell'app viene **unita** a quella del file (stesso id = versione del file); i profili che hai solo nell'app restano.
* Doppio click su un `.artnetstage` nel Finder apre l'app (grazie ai tipi di documento in `Info.plist`).
* Resta un salvataggio automatico dell'ultimo stato di lavoro in `~/Library/Application Support/ArtNetStage/` (`patch.json`, `library.json`, `scene.json`) solo per riaprire l'app dove l'avevi lasciata: non sostituisce il salvataggio su file.

## Novità della 1.2 — ottica delle fixture

Tutto si configura nel pannello **Luci** (Fixture Builder) e vale per le luci già patchate con quel profilo.

**Modalità colore** (sezione «Colore del fascio»): `Ruota Colori`, `RGB` o `RGBW`.
* *RGB / RGBW:* il colore segue direttamente i canali (nessuna transizione). In RGBW il bianco si somma a R, G, B.
* *Ruota Colori:* ogni slot associa un intervallo DMX (0–255) a un colore. L'ordine fisico degli slot sulla ruota è quello dei valori DMX crescenti.
  Passando da uno slot a uno **non adiacente** la ruota ruota davvero (14 slot/s, al massimo 0,7 s per il transito completo) e il fascio mostra brevemente i colori intermedi;
  tra due slot la finestra mostra una miscela dei due. Un valore DMX fuori da ogni intervallo lascia la ruota dov'è.
* I profili della 1.1 si aprono senza perdere nulla: la modalità viene dedotta dai canali (RGB/RGBW se ci sono, altrimenti ruota).

**Strobo in Hz** (sezione «Strobo»): frequenza massima a DMX 255 per ogni profilo, da 0,5 a 60 Hz (default 16; preset 20 Hz). DMX 0–9 = aperto, DMX 10 = 1 Hz, poi crescita lineare fino al massimo.
Il lampeggio è integrato sull'intervallo di ogni frame: a frequenze vicine al refresh dello schermo vedi l'ampiezza reale invece di flash persi; il limite fisico resta la frequenza del monitor.

**Gobo personalizzati** (ruolo canale `Gobo`, sezione «Gobo»):
* Aggiungi quanti intervalli DMX vuoi e, per ciascuno, scegli con il pannello di apertura file (`NSOpenPanel`) un'immagine **JPG o PNG quadrata in bianco e nero**: bianco = passa la luce, nero = la blocca.
  Un'immagine non quadrata viene ritagliata al centro; viene ridotta a 256×256 in scala di grigi (le zone trasparenti contano come nere). Un intervallo senza immagine è «aperto».
* La maschera sagoma il fascio in quattro punti: `SCNLight.gobo` (illumina davvero oggetti e palco), la macchia sul pavimento, il cono visibile (diventa un fascio di raggi che passa solo dove la maschera è chiara) e, con il prisma, ogni sotto-fascio.
* Le immagini sono **incorporate nel profilo come PNG in base64**: finiscono dentro i file `.artnetstage` (fixture e libreria) e nell'autosave, senza dipendere dai file originali.

**Prisma radiale** (ruolo canale `Prisma`, sezione «Prisma radiale»):
* Numero di facce da 2 a 24 (menu con 3, 4, 5, 6, 8, 12, 18, 24 più un contatore), valore DMX da cui il prisma è inserito (default 1), **soglia di rotazione** 0–255 e velocità a DMX 255 in giri/min.
* Prisma inserito: il fascio si duplica in N sotto-fasci a corona attorno all'asse ottico (ognuno con il suo cono e la sua macchia a terra). Fino alla soglia il prisma resta fermo; oltre ruota in modo continuo
  con velocità **proporzionale** a (valore − soglia) / (255 − soglia).
* Per non moltiplicare le luci di scena resta **una sola** `SCNLight` per fixture: con il prisma si allarga per coprire la corona e perde il gobo (che resta su coni e macchie).

**File:** il formato `.artnetstage` passa alla versione 2. La 1.2 apre ancora i file della 1.1; la 1.1 rifiuta quelli della 1.2 con un messaggio chiaro.
Il preset «Moving Head Beam 12ch» ora usa i ruoli `Gobo` e `Prisma` e la modalità ruota; se avevi già una libreria salvata dalla 1.1 i due canali vengono promossi in automatico.
Gobo e prisma non si applicano alle barre LED multi-pixel.

## Novità della 2.3

* **Gumball fluido anche per le luci.** Nel codice non c'era alcun arrotondamento delle coordinate delle fixture: lo spostamento e la rotazione scrivono il valore esatto
  del cursore. Ho alleggerito il percorso del trascinamento: una sola scrittura del modello per evento, confronto per uguaglianza (invece dell'hash dell'intero profilo,
  gobo inclusi) per decidere se ricostruire il modello 3D della luce, nessuna riconfigurazione del nodo Art-Net a ogni passo e nessun confronto della cronologia mentre si trascina.
* **Snap solo con Shift.** Senza tasti il movimento del Gumball è sempre continuo; tenendo premuto **Shift** lo spostamento va a passi di 10 cm e la rotazione a passi di 15°
  (valutato a ogni movimento del mouse, quindi si può premere o rilasciare Shift anche durante il trascinamento). Il pan con ⇧ resta valido fuori dal Gumball; il suggerimento in basso dice «Shift = a passi».
* **Pulsante «Orto».** Nella pillola delle viste: con Orto attivo, Frontale / Laterale / Superiore usano la proiezione ortogonale con `orthographicScale = distanza × tan(FOV/2)`,
  cioè la stessa inquadratura della prospettiva; rotellina e pizzico cambiano la scala. 3/4, Manichino (POV) o Orto spento tornano in prospettiva.
* **Stato del file.** Accanto al nome del file nel footer: «Modificato» (ambra) appena cambia qualcosa (scena, luci, canali DMX, profili, Net/SubNet, impostazioni), «Salvato» (verde) dopo il salvataggio
  o l'apertura di un file senza modifiche successive. Una scena nuova e intatta non mostra nulla.

## Novità della 2.2

* **Pubblico rimosso.** La folla della 2.1 (e la figura fantasma al centro del palco) non c'è più, né nella scena né nella scheda Palco né nei dati salvati.
  I file `.artnetstage` salvati con la 2.1 si aprono normalmente: la chiave `showCrowd` viene ignorata.
* **Barra delle viste.** I pulsanti Frontale, Laterale, Superiore, 3/4 e Manichino hanno larghezza naturale su una sola riga (`fixedSize` + `lineLimit(1)`):
  non si comprimono più quando compare la vista Manichino. Selettore del manichino e slider FOV stanno su una seconda riga sotto la pillola.
* **Manichino con faccia.** La testa ha una visiera scura e un naso arancione sul lato frontale. Con rotazione Y = 0 il manichino guarda **verso il pubblico**
  (lato +Z, dove c'è la scritta «PUBBLICO»); ruotandolo con il Gumball o con il campo Yaw la faccia segue.
* **Vista Manichino (POV) corretta.** La camera sta all'altezza degli occhi, davanti alla faccia, e guarda esattamente dove guarda il manichino
  (di default verso il pubblico), seguendo le sue rotazioni anche in tempo reale. Trascinando nella vista ci si guarda intorno.
* **Annulla / Ripristina.** ⌘Z e ⇧⌘Z (menu Modifica ▸ Annulla / Ripristina) su: posizione, rotazione e dimensioni di fixture e oggetti (campi numerici e
  trascinamento del Gumball: un passo per trascinamento, chiuso al rilascio del mouse), aggiunta / eliminazione / duplicazione di luci, stativi e oggetti,
  profili (canali DMX, ruota colori, gobo, prisma, strobo), palco (misure, colori di americane e piano, luminosità), luminosità di scena e luci, Net/SubNet.
  Le raffiche di modifiche (slider, digitazione) si fondono in un solo passo. Con il cursore in un campo di testo, ⌘Z annulla prima la digitazione.
  Aprire un file azzera la cronologia (fino a 200 passi, non salvati nel file). Non sono annullabili le azioni di sistema (alias IP) e i valori DMX di prova.

## Novità della 2.1

* **Sfondo unico a tutta finestra.** Un solo sfondo continuo, scuro e atmosferico, tinto dal colore della sezione (Rete, Catena, Luci, Palco, DMX).
  La scena 3D ha sfondo trasparente (anche il suolo non disegna colore), quindi dietro al palco si vede lo stesso sfondo della finestra.
  Il pannello di sinistra poggia direttamente sullo sfondo, senza riquadro; lo separa dalla viewport solo una sottile barra verticale traslucida,
  trascinabile (si illumina al passaggio del mouse).
* **Palco centrato nella zona libera.** La vista 3D occupa solo l'area a destra della barra: il centro ottico della camera coincide quindi con il centro
  dello spazio visibile e si aggiorna da solo quando ridimensioni il pannello (Gumball e selezione restano precisi).
* **Blackout UI.** Il pulsante con la luna (in alto a destra) porta lo sfondo di tutta la finestra a nero puro #000000; pannelli, card e controlli in vetro restano com'erano. Lo stato viene ricordato.
* **Scheda «Catena».** «Collegamenti» (2.0) → **Catena**, anche nei titoli interni.
* **Vista Manichino (POV).** Accanto a Frontale / Laterale / Superiore / 3/4 c'è «Manichino»: la camera si porta all'altezza degli occhi del manichino
  selezionato (o del primo) guardando nella sua direzione frontale (−Z ruotato dallo yaw: per default verso il palco). Trascina per guardarti intorno;
  se ci sono più manichini compare un menu per sceglierli; lo slider **Campo visivo** va da 35° (tele) a 110° (grandangolo) e agisce in tempo reale su `SCNCamera.fieldOfView`
  (orizzontale). Se sposti o ruoti il manichino con il Gumball, la vista lo segue. In POV pan e zoom sono disattivati.
* **Folla** (rimossa nella 2.2, vedi sotto).

## Novità della 2.0 — nuova interfaccia

Solo grafica: rendering 3D, motore Art-Net, Gumball, file `.artnetstage` e generazione dell'icona sono invariati.

* **Finestra unificata.** Niente barra del titolo: la scena 3D occupa tutta la finestra e il pannello dei controlli è una lastra di vetro
  satinato traslucido (`NSVisualEffectView`) appoggiata sopra. Apri/Salva/Salva con nome sono nell'intestazione del pannello
  (restano anche nel menu File con ⌘O, ⌘S, ⇧⌘S). La finestra si sposta trascinando l'intestazione.
* **Ridimensionamento.** Trascina la maniglia sottile sul bordo destro del pannello (si illumina al passaggio del mouse); la larghezza viene ricordata.
* **Vetro su tutta la UI.** Badge Art-Net, pillola delle viste, pannello Luminosità e suggerimenti usano lo stesso vetro (angoli continui, bordo bianco al 12%, ombre morbide).
* **Schede.** «Patch» diventa **Catena** (dalla 2.1; nella 2.0 si chiamava «Collegamenti») e «Fixture» diventa **Luci**. La barra a pillole (animata) assegna a ogni scheda un colore:
  Rete ciano/blu, Catena verde smeraldo/acquamarina, Luci magenta/viola, Palco ambra/arancio, DMX indaco.
  Il colore tinge il vetro del pannello, le card, i pulsanti, le selezioni e gli slider.
* **Card e controlli.** Ogni riquadro è una card in vetro (`cornerRadius: 14`, continuo); pulsanti e campi numerici hanno uno stile dedicato con cifre tabulari.
* Il nuovo `Theme.swift` raccoglie colori delle sezioni, vetro, stili e maniglia.

## Novità della 1.5

* **Strobo a intervalli DMX proporzionali alla frequenza.** Nel riquadro «Strobo» del Fixture Builder il canale ha due intervalli (0–255):
  **Strobo spento** (predefinito 0–9: shutter aperto, fascio fisso) e **Strobo attivo** (predefinito 10–255). Nell'intervallo attivo la
  frequenza cresce linearmente col valore DMX, da 1 Hz all'inizio fino alla frequenza massima (Hz) impostata per la fixture alla fine.
  Se un valore cade in entrambi gli intervalli vale «spento»; fuori da «attivo» il fascio resta fisso.
* **File `.artnetstage`.** Intervalli e frequenza massima vengono salvati; i file precedenti si aprono con i valori predefiniti
  (identici al comportamento della 1.4). Il formato resta il 3.

## Novità della 1.4

* **Prisma a 3 intervalli DMX.** Nel Fixture Builder, riquadro «Prisma radiale», il canale Prisma ha tre intervalli configurabili (0–255):
  **Spento** (es. 0–9: fascio singolo), **Attivo fisso** (es. 10–127: N sotto-fasci a corona, senza rotazione) e **Rotazione**
  (es. 128–255: la corona ruota attorno all'asse ottico; la velocità cresce linearmente da «inizio rotazione» a «fine rotazione», in giri/min).
  Se gli intervalli si sovrappongono vale l'ordine Spento → Rotazione → Fisso; i valori fuori da ogni intervallo lasciano il prisma spento.
  I profili 1.2/1.3 (soglia singola) vengono convertiti automaticamente in tre intervalli equivalenti.
* **Piano del palco.** In «Dimensioni del palco» trovi il colore del piano (ColorPicker) e lo slider «Luminosità piano» (0–150%),
  indipendenti dallo slider «Elementi scena». Il pulsante «Standard» ripristina colore e luminosità predefiniti.
* **File `.artnetstage`.** Gli intervalli del prisma e colore/luminosità del piano vengono salvati e caricati; i file 1.3 si aprono con i
  valori convertiti o predefiniti. Il formato resta il 3.

## Novità della 1.3

**Barra LED** (Fixture Builder ▸ tipologia «Barra LED Multi-Pixel»)
* *Tipo di barra:* `Non motorizzata` (fissa) oppure `Motorizzata`: il canale **Tilt** viene aggiunto come primo canale e inclina l'intera barra attorno al proprio asse longitudinale (escursione regolabile).
* *LED:* menu 4 / 8 / 10 / 12 / 16 / 20 / 24 / 32 più un contatore fino a 170; modalità **RGB** (3 canali per LED) o **RGBW** (4), valida per barre fisse e motorizzate.
* *Dimensioni:* lunghezza, altezza e spessore si regolano per ogni luce nella Patch (campi numerici + scala %); il passo dei LED si adatta alla lunghezza.
* *Pixel mapper:* mappa grafica con i LED numerati e i canali in sequenza (nel Builder è la mappa della sola assegnazione; nella Patch, per la luce selezionata, mostra i valori DMX reali).
  Click su un LED = lo accende/spegne con il colore di prova scelto: nel 3D si accende **solo quel segmento**, con il suo cono.

**PAR LED e Wall Wash**
* Forma del corpo `Tondo` (cilindrico) o `Rettangolare`. Modalità colore **RGB / RGBW** per PAR e Wall Wash (niente ruota colori: è dei proiettori a testa mobile).
* Nuovi preset in libreria: «Wall Wash RGBW 7ch», «Barra LED motorizzata 8 pixel RGBW» e «Macchina del Fumo 1ch» (aggiunti una sola volta alla libreria già esistente).
* **Dimensioni 3D** per teste mobili, PAR, Wall Wash, barre e macchina del fumo: larghezza / altezza / profondità e scala uniforme, in Patch ▸ luce selezionata. Salvate per ogni luce.

**Stativi / cavalletti** (pannello Palco ▸ Oggetti 3D ▸ «Stativo / Cavalletto luci»)
* Tre varianti: `Singolo` (1 attacco), `T-Bar 2 posti`, `T-Bar 4 posti`. Altezza asta (estensione), larghezza della barra superiore e ingombro della base a treppiede regolabili.
* Le luci si agganciano ai punti di montaggio dal pannello dello stativo («Attacchi per le luci») o dalla Patch («Aggancia a»). Una luce agganciata segue lo stativo se lo sposti, lo ruoti o ne cambi altezza/larghezza; spostarla a mano la stacca.

**Occlusione dei fasci:** per ogni fascio (e per ogni LED della barra, e per ogni sotto-fascio del prisma) si esegue un raycast `hitTestWithSegment` lungo l'asse contro oggetti, manichini e stativi, più un'intersezione analitica con pedana e suolo.
Il cono viene troncato alla distanza dell'impatto e sulla superficie colpita compare la macchia di luce (orientata secondo la normale). Il fascio non prosegue oltre.

**Macchina del fumo:** tipologia «Macchina del Fumo» con canale ruolo `Fumo` (0 = spenta, 255 = emissione massima). Nel 3D è un solo `SCNParticleSystem` con sprite sfumati (≈ 16 particelle/s al massimo, nessun calcolo volumetrico).
Nella Patch c'è uno slider di prova.

**Gumball 3D:** con un elemento selezionato (oggetti, manichino, stativi, luci) compare al suo centro: frecce **X rosso, Y verde (verticale), Z blu** per spostare e tre archi per ruotare, sempre visibili e cliccabili anche dietro l'oggetto.
* Click su una freccia/arco: l'orbita della camera si blocca e il trascinamento è vincolato a quell'asse; il movimento del cursore viene proiettato sull'asse 3D. I campi numerici della sidebar si aggiornano in tempo reale.
  Al rilascio i controlli della camera tornano normali. Con **⌃** premuto: passi di 5 cm / 5°.
* Archi: **verde** = orientamento base (yaw); **rosso** = inclinazione dell'oggetto / Tilt di una luce; **blu** = rollio dell'oggetto / Pan di una luce. Gli stativi e la macchina del fumo ruotano solo sul verde.

**Luminosità** (pannello in basso a sinistra nella vista 3D, salvata nella scena)
* *Elementi scena* (0–100 %): luce ambiente + materiali senza illuminazione (pedana, bagliore delle americane, scritta). Aiuta a distinguere palco, stativi, parallelepipedi e manichini anche al buio. **Lo sfondo resta sempre nero (`NSColor.black`).**
* *Luci (master)* (0–200 %): moltiplicatore sull'intensità delle `SCNLight` delle fixture e sulla luminosità dei coni e delle macchie; non tocca la luce ambiente.

**File:** il formato `.artnetstage` passa alla versione **3** (dimensioni, forma, barre motorizzate, stativi con aggancio, fumo, inclinazione/rollio degli oggetti, posizioni e rotazioni da Gumball, i due livelli di luminosità).
La 1.3 apre ancora i formati 1 e 2; le versioni precedenti rifiutano i file di formato 3 con un messaggio chiaro.

## Versione

La versione è **2.3** (build 10): `CFBundleShortVersionString` in `Info.plist`, `AppInfo.version` nel codice (footer della sidebar e voce «Informazioni su ArtNet Stage»).
Il pacchetto non contiene un `project.pbxproj`: il progetto Xcode lo crei tu seguendo i passi sotto. Se usi Xcode imposta **Target ▸ General ▸ Version = 1.3** e **Build = 4**
(equivale a `MARKETING_VERSION = 2.3`) e usa `Info.plist` come file Info del target, così il tipo `.artnetstage` risulta registrato.
Con `build_app.sh` non serve fare nulla: copia `Info.plist` nel bundle e vi imposta `CFBundleShortVersionString = 2.3` e `CFBundleVersion = 10`
(le variabili `APP_VERSION` e `APP_BUILD` in cima allo script: cambiale insieme a `AppInfo` quando alzi la versione).

## Icona dell'app

Metti nella cartella principale del repository, accanto a `build_app.sh`, un file **`AppIcon.png`** quadrato (consigliato **1024×1024**, con trasparenza se vuoi).
Durante la compilazione `build_app.sh` lo converte da solo, con gli strumenti di macOS `sips` e `iconutil`, in `AppIcon.icns` (10 dimensioni da 16 a 1024 px, come richiede un `.iconset`),
lo copia in `ArtNetStage.app/Contents/Resources/` e imposta `CFBundleIconFile = AppIcon` nell'`Info.plist` del bundle.
Non serve installare nulla: `sips` e `iconutil` sono inclusi in macOS e nei runner GitHub `macos-latest`, quindi funziona anche con il workflow `github/build.yml`
(basta che `AppIcon.png` sia stato caricato nel repository).

* Se `AppIcon.png` manca, non è quadrato o la conversione fallisce, la build **non si ferma**: lo script scrive un avviso e crea l'app con l'icona generica.
* Per cambiare icona basta sostituire `AppIcon.png` e rilanciare la build. Se il Finder mostra ancora la vecchia, riavvia il Finder (`killall Finder`).
* Con un progetto Xcode l'icona si gestisce invece dall'asset catalog (**AppIcon** in `Assets.xcassets`): lo script non serve in quel caso.

## Senza Xcode (consigliato se hai poco spazio)

Basta il pacchetto **Command Line Tools** di Apple (compilatore Swift + SDK di macOS, già con SwiftUI e SceneKit): occupa
una frazione di Xcode, che pesa decine di GB.

1. Apri il Terminale e lancia `xcode-select --install`, poi conferma nella finestra che appare (mostra la dimensione del download).
   Se i Command Line Tools sono già presenti il comando lo segnala.
2. Decomprimi `ArtNetStage.zip`, poi nel Terminale: `cd` nella cartella decompressa (quella con `build_app.sh`).
3. Lancia `bash build_app.sh`. Compila e crea `ArtNetStage.app` (con l'icona, se c'è `AppIcon.png`; firma ad-hoc, senza sandbox), poi la avvia.
4. Alla prima esecuzione consenti l'accesso alla rete locale. L'app compilata in locale non viene bloccata da Gatekeeper.
5. Per riaprirla in futuro: `open ArtNetStage.app` (o doppio clic). Se modifichi il codice, rilancia `bash build_app.sh`.

Per recuperare spazio in seguito: elimina la cartella `ArtNetStage.app` e, se non ti servono più i Command Line Tools,
`sudo rm -rf /Library/Developer/CommandLineTools`.

La sezione seguente serve solo se usi Xcode: con lo script, sandbox disattivata e descrizione del permesso rete
locale sono già gestite (resta solo da consentire l'accesso alla prima esecuzione).

## Guida rapida all'avvio (con Xcode)

### 1. Creare il progetto in Xcode
1. **File ▸ New ▸ Project ▸ macOS ▸ App**. Nome `ArtNetStage`, Interface **SwiftUI**, Language **Swift**.
2. Elimina i file generati `ArtNetStageApp.swift` e `ContentView.swift`.
3. Trascina nel progetto l'intera cartella `ArtNetStage/` di questo pacchetto (spunta *Copy items if needed* e *Create groups*, target `ArtNetStage` selezionato).
4. **Target ▸ General ▸ Minimum Deployments:** macOS **13.0**.

### 2. Disabilitare l'App Sandbox
1. **Target ▸ Signing & Capabilities**: se compare la capability **App Sandbox**, rimuovila con il cestino (✕).
2. **Build Settings ▸ Code Signing Entitlements** → `ArtNetStage/ArtNetStage.entitlements` (il file ha `com.apple.security.app-sandbox = false`).
3. Lascia *Hardened Runtime* attivo se vuoi, non interferisce.

### 3. Info.plist, versione e permesso rete locale
**Build Settings ▸ Info.plist File** → `Info.plist` (quello incluso nel pacchetto, già con versione 2.3, tipo `.artnetstage` e `NSLocalNetworkUsageDescription`).
In alternativa aggiungi a mano le chiavi nella scheda **Info** del target. Alla prima esecuzione consenti l'accesso alla rete locale.

### 4. Primo avvio
Premi **⌘R**. Al primo avvio l'app carica una patch dimostrativa (4 PAR, 4 teste mobili, 1 barra) e mette il nodo in ascolto
su UDP 6454. Nel pannello **DMX** premi **Accendi tutto** per verificare subito la scena senza software esterno.

### 5. Collegare il software mittente (stesso Mac)
Le voci esatte cambiano tra versioni; in generale:

| Software | Impostazione |
|---|---|
| **QLab** | *Settings ▸ Lighting*: aggiungi un Lighting Network di tipo **Art-Net**, destinazione **127.0.0.1** (unicast) oppure l'IP scelto qui. |
| **QLC+** | *Inputs/Outputs ▸ Universe ▸ Art-Net*: scegli l'interfaccia, in uscita spunta **Unicast** con IP `127.0.0.1` (o broadcast). |
| **Lightkey** | *Preferences ▸ Output ▸ Art-Net*: indirizzo di destinazione `127.0.0.1` o broadcast. |

* **Universi:** nel software mittente usa gli stessi universi della patch (U0 = universo Art-Net 0 con Net 0 / SubNet 0).
  Alcuni programmi numerano da 1: se non vedi nulla, prova a scalare di uno (guarda il pannello **DMX** per vedere quale universo arriva).
* **ArtPoll:** se il programma fa discovery, il Mac comparirà come nodo «ArtNet Stage» con gli universi della patch.
* **Rete fisica / altro computer:** scegli l'interfaccia Ethernet nel pannello **Rete**; con **Aggiungi alias…** puoi dare al Mac un IP tipo `2.0.0.2`
  (netmask `255.0.0.0`) anche senza switch collegato.

### Risoluzione problemi
* **«Porta 6454 occupata»:** un altro programma ha aperto la porta senza `SO_REUSEPORT`. Chiudilo, oppure avvia ArtNet Stage prima di lui.
  Se più processi condividono la porta, il **broadcast** arriva a tutti, mentre l'**unicast** viene consegnato a uno solo (tipicamente l'ultimo che ha fatto bind): usa il broadcast o chiudi i programmi che non servono.
* **L'alias IP non funziona senza cavo:** `ifconfig alias` su un'interfaccia senza link dipende dall'adattatore; il metodo più robusto è usare **lo0 (Loopback)** come interfaccia dell'alias, oppure `127.0.0.1`.
  Gli alias spariscono al riavvio.
* **Nessun dato ma i pacchetti partono:** controlla il firewall di macOS (consenti connessioni in entrata per l'app) e che mittente e nodo usino lo stesso Net/SubNet/Universe.
* **Luci spente anche con dati in arrivo:** come su una fixture reale, il canale **Dimmer** deve essere > 0 (nelle fixture che lo prevedono).

## Note tecniche

* **Assi della scena:** X = sinistra/destra, Y = altezza, Z = profondità (positivo verso il pubblico). Unità = metri.
* **Pan/Tilt:** il valore centrale del range (es. DMX 127/128, o 32768 a 16 bit) porta il fascio sull'asse del montaggio
  (verso l'alto a terra, verso il basso se appesa, verso il pubblico se verticale). Usa *Offset Pan/Tilt* e *Inverti* per adattare la scena al tuo rig.
* **Pan/Tilt Speed:** 0 = massima velocità (~400°/s), 255 = lentissimo (~6°/s); senza canale speed i motori vanno a ~300°/s. In più c'è uno smorzamento esponenziale.
* **Strobe/Shutter:** valori 0–9 = aperto; 10–255 = da 1 Hz alla frequenza massima del profilo (vedi «Novità della 1.2»).
* **Color wheel:** con transito fisico tra gli slot (vedi «Novità della 1.2»); senza slot definiti il colore è bianco.
* **RGB / RGBW:** il bianco (solo in RGBW) viene sommato a R, G, B (limitato a 1). La modalità scelta decide quali canali colore contano: non si moltiplicano più ruota e RGB.
* **Fixture Builder:** le modifiche a un profilo si riflettono subito sulle luci già patchate con lo stesso profilo. Libreria e patch sono salvate in
  `~/Library/Application Support/ArtNetStage/` (`library.json`, `patch.json`). I profili si possono esportare/importare in JSON.
* **ArtPollReply:** pacchetto da 239 byte (Art-Net 4), Port-Address a 15 bit, fino a 4 porte per risposta (più risposte con `BindIndex` crescente se la patch usa più di 4 universi).

### 2.3 (revisione)
- **Orto**: pulsante testuale nella barra viste in alto a destra, con divisore verticale, legato a `isOrthographic`. In Frontale/Laterale/Superiore usa la proiezione ortogonale (`orthographicScale = distanza × tan(FOV/2)`); rotellina e pizzico cambiano direttamente `orthographicScale`; in 3/4 e Manichino torna prospettica.
- **Gumball 1:1**: la luce segue il cursore (anteprima 3D immediata, modello dati a ~30 Hz e al rilascio), nessun arrotondamento.
- **Shift**: snap relativo allo spostamento (10 cm) e alla rotazione (15°); senza Shift movimento continuo.
- **Footer**: etichetta testuale «Modificato» / «Salvato» accanto al nome file, senza pallino.
