# ArtNet Stage 1.1 — nodo Art-Net virtuale + visualizzatore 3D per macOS

App nativa **macOS 13+** (Swift 5.9, SwiftUI MVVM, SceneKit, BSD sockets) che si comporta come una centralina Art-Net
collegata al Mac e mostra in tempo reale, in 3D, ciò che QLab, QLC+, Lightkey & co. inviano.

> **Nota onesta:** il codice è stato scritto senza poterlo compilare in Xcode (ambiente senza macOS).
> Se Xcode segnala errori o warning bloccanti al primo build, incollali nella chat e li correggo.

## Architettura

```
ArtNetStage/
├── ArtNetStageApp.swift        @main, finestra e iniezione degli environment object
├── AppViewModel.swift          coordinatore MVVM: server ↔ patch ↔ scena 3D ↔ palco/oggetti/scene salvate
├── ContentView.swift           UI: pannello a sezioni (Rete/Patch/Fixture/Palco/DMX) + stage 3D, toolbar viste e toolbar file
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
│   ├── FixtureRenderer.swift   coni additivi, SCNLight spot, pan/tilt con smorzamento, RGBW, color wheel, strobe, pixel
│   ├── StageObjectRenderer.swift parallelepipedi e manichini (materiale blinn, castsShadow)
│   ├── SceneHelpers.swift      linee, contorno di selezione, materiali
│   └── StageSceneView.swift    NSViewRepresentable + mouse/trackpad (orbita, pan, zoom, click per selezionare)
└── Views/
    ├── NetworkPanelView.swift  interfacce, IP, Net/SubNet, alias IP
    ├── PatchView.swift         patch, cavi daisy-chain, conflitti, mappa universi, posizione 3D
    ├── FixtureBuilderView.swift editor profili, color wheel, pixel, import/export JSON
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

## Versione

La versione è **1.1** (build 2): `CFBundleShortVersionString` in `Info.plist`, `AppInfo.version` nel codice (footer della sidebar e voce «Informazioni su ArtNet Stage»).
Il pacchetto non contiene un `project.pbxproj`: il progetto Xcode lo crei tu seguendo i passi sotto. Se usi Xcode imposta **Target ▸ General ▸ Version = 1.1** e **Build = 2**
(equivale a `MARKETING_VERSION = 1.1`) e usa `Info.plist` come file Info del target, così il tipo `.artnetstage` risulta registrato.
Con `build_app.sh` non serve fare nulla: copia `Info.plist` nel bundle e vi imposta `CFBundleShortVersionString = 1.1` e `CFBundleVersion = 2`
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
**Build Settings ▸ Info.plist File** → `Info.plist` (quello incluso nel pacchetto, già con versione 1.1, tipo `.artnetstage` e `NSLocalNetworkUsageDescription`).
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
* **Strobe/Shutter:** valori 0–9 = aperto; 10–255 = da 1 a 16 Hz.
* **Color wheel:** scatto netto, nessuna interpolazione; fuori da ogni range definito il colore è bianco.
* **RGBW:** il bianco viene sommato a R, G, B (limitato a 1). Se una fixture ha sia RGB sia ruota colori, i due colori si moltiplicano.
* **Fixture Builder:** le modifiche a un profilo si riflettono subito sulle luci già patchate con lo stesso profilo. Libreria e patch sono salvate in
  `~/Library/Application Support/ArtNetStage/` (`library.json`, `patch.json`). I profili si possono esportare/importare in JSON.
* **ArtPollReply:** pacchetto da 239 byte (Art-Net 4), Port-Address a 15 bit, fino a 4 porte per risposta (più risposte con `BindIndex` crescente se la patch usa più di 4 universi).
