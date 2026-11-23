# ArtNet Stage — nodo Art-Net virtuale + visualizzatore 3D per macOS

App nativa **macOS 13+** (Swift 5.9, SwiftUI MVVM, SceneKit, BSD sockets) che si comporta come una centralina Art-Net
collegata al Mac e mostra in tempo reale, in 3D, ciò che QLab, QLC+, Lightkey & co. inviano.

> **Nota onesta:** il codice è stato scritto senza poterlo compilare in Xcode (ambiente senza macOS).
> Se Xcode segnala errori o warning bloccanti al primo build, incollali nella chat e li correggo.

## Architettura

```
ArtNetStage/
├── ArtNetStageApp.swift        @main, finestra e iniezione degli environment object
├── AppViewModel.swift          coordinatore MVVM: server ↔ patch ↔ scena 3D, test locale
├── ContentView.swift           UI: pannello a sezioni (Rete/Patch/Fixture/DMX) + stage 3D
├── ArtNetStage.entitlements    App Sandbox DISABILITATO
├── Models/
│   ├── FixtureModels.swift     FixtureProfile, ChannelRole, ColorWheelSlot, PixelConfig, PatchedFixture
│   ├── FixturePresets.swift    3 preset: PAR RGBW 8ch · Moving Head Beam 12ch · Barra LED 10 pixel
│   └── PatchManager.swift      libreria JSON, patch/daisy-chain, auto-patch, conflitti, persistenza
├── Network/
│   ├── ArtNetServer.swift      socket UDP 6454 (SO_REUSEADDR + SO_REUSEPORT), ArtPoll/ArtPollReply, ArtDmx, statistiche
│   ├── ArtNetPackets.swift     parsing ArtDmx/ArtPoll, costruzione ArtPollReply (239 byte)
│   ├── DMXStore.swift          buffer DMX thread-safe per Port-Address a 15 bit
│   └── NetworkInterfaces.swift getifaddrs + SystemConfiguration, alias IP via osascript/ifconfig
├── Stage/
│   ├── StageScene.swift        scena black-box, griglia, truss, camera orbitale, loop a 60 fps
│   ├── FixtureRenderer.swift   coni additivi, pan/tilt con smorzamento, RGBW, color wheel, strobe, pixel
│   └── StageSceneView.swift    NSViewRepresentable + gestione mouse/trackpad
└── Views/
    ├── NetworkPanelView.swift  interfacce, IP, Net/SubNet, alias IP
    ├── PatchView.swift         patch, cavi daisy-chain, conflitti, mappa universi, posizione 3D
    ├── FixtureBuilderView.swift editor profili, color wheel, pixel, import/export JSON
    └── DMXMonitorView.swift    sniffer: Hz, universi attivi, griglia live 1–512
```

## Senza Xcode (consigliato se hai poco spazio)

Basta il pacchetto **Command Line Tools** di Apple (compilatore Swift + SDK di macOS, già con SwiftUI e SceneKit): occupa
una frazione di Xcode, che pesa decine di GB.

1. Apri il Terminale e lancia `xcode-select --install`, poi conferma nella finestra che appare (mostra la dimensione del download).
   Se i Command Line Tools sono già presenti il comando lo segnala.
2. Decomprimi `ArtNetStage.zip`, poi nel Terminale: `cd` nella cartella decompressa (quella con `build_app.sh`).
3. Lancia `bash build_app.sh`. Compila e crea `ArtNetStage.app` (firma ad-hoc, senza sandbox), poi la avvia.
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

### 3. Permesso rete locale (macOS 15 Sequoia e successivi)
**Target ▸ Info** → aggiungi la chiave `Privacy - Local Network Usage Description`
(`NSLocalNetworkUsageDescription`) con un testo tipo *«Serve per ricevere pacchetti Art-Net»*.
Alla prima esecuzione consenti l'accesso alla rete locale.

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
